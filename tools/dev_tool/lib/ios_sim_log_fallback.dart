/// Persisted-log fallback for iOS Simulator VM-service discovery.
///
/// `simctl spawn <udid> log stream` prints its `Filtering the log data ...`
/// header before it attaches to the simulator's unified log, and on a loaded
/// machine the attach can lag the app's first output by seconds: the engine's
/// `The Dart VM service is listening on ...` announcement is already in the
/// persisted log by the time the stream starts seeing new entries, so the
/// stream never carries it and discovery waits out its whole bound on a live
/// app. The fallback re-reads the persisted log with `log show` while the
/// stream runs and feeds any announcement this launch made into the same
/// [AppLogStream] the stream feeds, so whichever source sees it first wins
/// and the single `waitForVmServiceUri` wait keeps its progress lines, its
/// fail-at-once on app exit, and its bound.
///
/// Only this launch's own announcement is ever taken: an entry counts only
/// when its `processIdentifier` is the pid `simctl launch` reported for this
/// launch *and* its `timestamp` is at or after a timestamp captured before
/// `simctl launch` ran. Both are checked on every returned entry, in Dart —
/// the `log show` predicate narrows the read but is not what makes an entry
/// count — so a stale announcement from an earlier launch, another process,
/// or a reused pid can never be taken.
///
/// A `log show` call that fails (or answers unparsably) is not fatal: it is
/// logged once per distinct failure and the next poll carries on. No pid from
/// `simctl launch` means no fallback at all — the caller discovers from the
/// stream alone and logs that the fallback is off.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_log.dart';
import 'logging.dart';
import 'vm_service_discovery.dart';

/// Runs a helper process and waits for it: `Process.run` in production, the
/// device's injected runner in tests.
///
/// A local typedef rather than the device's `ProcessRunSync`: the two shapes
/// are identical, so the device passes its runner straight in, and this
/// library stays importable without the device.
typedef SimLogShowRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// Which launch the fallback hunts for: the simulator, the pid `simctl
/// launch` reported for it, and the instant before that launch ran.
typedef SimLogFallbackQuery = ({String udid, int pid, DateTime since});

/// How often the fallback re-reads the persisted log while discovery waits.
///
/// Seconds, not milliseconds: `log show` re-scans the simulator's log store
/// on every poll, and the live stream stays the fast path — the fallback only
/// has to beat the discovery bound, not the stream.
const defaultSimLogFallbackPollInterval = Duration(seconds: 2);

/// The logger the fallback reports through when the caller names none.
final Logger _fallbackLogger = Logger('dev_tool.ios_sim_log');

/// `log show --start` takes `YYYY-MM-DD HH:MM:SS`-shaped instants, which `log`
/// reads as local wall-clock time: format the launch instant the same way, or
/// west of UTC the start lands hours in the future and the read finds nothing.
/// What makes an entry count is still the absolute-time check
/// [findSimLogVmServiceUri] runs on every returned entry.
String _formatShowStart(DateTime instant) {
  final start = instant.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${start.year}-${two(start.month)}-${two(start.day)} '
      '${two(start.hour)}:${two(start.minute)}:${two(start.second)}';
}

/// Parse an instant out of a `log show --style json` timestamp field.
///
/// ISO-8601 first, then the `YYYY-MM-DD HH:MM:SS.ffffff±ZZZZ` shape Apple's
/// `log` writes. Zoneless text reads as UTC, so the same output gates the
/// same way on every machine. Null when the text is no instant at all, in
/// which case the entry cannot prove it is this launch's and does not count.
DateTime? _parseLogTimestamp(String raw) {
  final text = raw.trim();
  try {
    return DateTime.parse(text);
  } on FormatException {
    // Not ISO: fall through to the Apple shape below.
  }
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})'
    r'(?:\.(\d{1,9}))?\s*([+-]\d{2}:?\d{2}|Z)?$',
  ).firstMatch(text);
  if (match == null) return null;
  final micros = (match.group(7) ?? '0').padRight(6, '0').substring(0, 6);
  var instant = DateTime.utc(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
    int.parse(match.group(6)!),
    0,
    int.parse(micros),
  );
  final zone = match.group(8);
  if (zone != null && zone != 'Z') {
    final sign = zone.startsWith('-') ? -1 : 1;
    final digits = zone.substring(1).replaceAll(':', '');
    instant = instant.subtract(
      Duration(
        hours: sign * int.parse(digits.substring(0, 2)),
        minutes: sign * int.parse(digits.substring(2, 4)),
      ),
    );
  }
  return instant;
}

/// Read one decoded entry's discovery fields: the first [String] under any of
/// [keys], or null.
String? _firstString(Map<Object?, Object?> entry, List<String> keys) {
  for (final key in keys) {
    final value = entry[key];
    if (value is String) return value;
  }
  return null;
}

/// The pid a decoded `log` JSON entry was written by.
///
/// The key spelled the way Apple's `log` spells it, plus the shortenings a
/// fixture or a future format may use, tolerating a string encoding. Shared
/// with the live discovery stream, which judges entries the same way this
/// fallback does. Null when the entry carries no pid, in which case the entry
/// cannot prove it is this launch's and does not count.
int? simLogEntryPid(Map<Object?, Object?> entry) {
  for (final key in const [
    'processIdentifier',
    'processID',
    'processId',
    'pid',
  ]) {
    final value = entry[key];
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
  }
  return null;
}

/// The message text of a decoded `log` JSON entry, or null when it has none.
///
/// Shared with the live discovery stream, which reads the same entries out of
/// `log stream` instead of `log show`.
String? simLogEntryMessage(Map<Object?, Object?> entry) =>
    _firstString(entry, const ['eventMessage', 'message']);

/// The VM-service URI [message] announces, or null when it announces none.
///
/// The engine's `The Dart VM service is listening on ...` line — the same
/// pattern every log-based discovery wait reads — shared with the live
/// discovery stream so both sources take the same announcement.
Uri? simLogAnnouncementUri(String message) {
  final match = vmServiceUriPattern.firstMatch(message);
  if (match == null) return null;
  return Uri.parse(match.group(1)!);
}

/// Judge one decoded entry: this launch's announcement, or null.
///
/// Null covers every way an entry does not count — no message, another
/// process's pid, no pid, older than the launch, an unparsable timestamp, or
/// carrying no announcement — because only a proven entry may feed discovery.
/// The timestamp check runs in absolute time, whatever zone the text names.
Uri? _judgeJsonEntry(
  Map<Object?, Object?> entry, {
  required int pid,
  required DateTime since,
}) {
  final message = simLogEntryMessage(entry);
  if (message == null) return null;
  if (simLogEntryPid(entry) != pid) return null;
  final rawTimestamp = _firstString(entry, const ['timestamp', 'time']);
  final timestamp = rawTimestamp == null
      ? null
      : _parseLogTimestamp(
          rawTimestamp,
        );
  if (timestamp == null || timestamp.isBefore(since)) return null;
  return simLogAnnouncementUri(message);
}

/// The JSON document inside one `log show` call's stdout.
///
/// `simctl spawn … log` prints non-JSON lines before its own output on the
/// runners (`getpwuid_r did not find a match for uid 501`, on stdout or
/// stderr), so the read starts at the first line that opens the array.
/// Output with no such line comes back whole, so the decode below reports it
/// as before instead of mistaking it for quiet.
String _jsonDocument(String text) {
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trimLeft().startsWith('[')) {
      return lines.sublist(i).join('\n');
    }
  }
  return text;
}

/// Find this launch's VM-service announcement in one `log show` call's
/// output, or null when it holds none.
///
/// The output is the JSON document `--style json` prints: an array of entries
/// whose first line is `[{`, whose entries are joined as `},{`, and whose last
/// line is `}]`. Non-JSON lines before the document (the runners' `getpwuid_r`
/// preamble) are skipped. Entries are judged in order and the first proven one
/// wins (`log show` reads oldest-first). Throws [FormatException] when the
/// output holds no JSON document at all — that is not "no announcement yet",
/// it is a caller looking at something that is not `log show` output, and the
/// poller reports it rather than mistaking it for quiet.
Uri? findSimLogVmServiceUri(
  String output, {
  required int pid,
  required DateTime since,
}) {
  final text = output.trim();
  if (text.isEmpty) return null;
  late final List<Object?> entries;
  try {
    final decoded = json.decode(_jsonDocument(text));
    if (decoded is! List) {
      throw const FormatException('not a JSON array of log entries');
    }
    entries = decoded;
  } on FormatException {
    final head = text;
    throw FormatException(
      'expected `log show --style json` entries, got: '
      '${head.substring(0, head.length < 120 ? head.length : 120)}',
    );
  }
  for (final entry in entries) {
    if (entry is! Map<Object?, Object?>) continue;
    final found = _judgeJsonEntry(entry, pid: pid, since: since);
    if (found != null) return found;
  }
  return null;
}

/// The persisted-log fallback for one simulator launch.
///
/// Built from the launch's [query] plus the discovery wait's clock; [feedAnnouncements]
/// polls `log show` into a shared [AppLogStream] until [stop] completes.
class SimLogFallback {
  /// Which launch to hunt for.
  final SimLogFallbackQuery query;

  /// Runs `log show`: `Process.run` in production, the device's injected
  /// runner in tests.
  final SimLogShowRunner runProcess;

  /// How long to wait between `log show` polls. The first poll runs at once,
  /// so this only spaces the retries.
  final Duration pollInterval;

  /// Where time comes from; the discovery wait's clock, so fake-time tests
  /// drive the poll gaps without sleeps.
  final VmDiscoveryClock clock;

  /// Where the once-per-failure lines go; the run's logger in production.
  final Logger? logger;

  /// The persisted-log fallback for one simulator launch.
  SimLogFallback({
    required this.query,
    required this.runProcess,
    this.pollInterval = defaultSimLogFallbackPollInterval,
    this.clock = const SystemVmDiscoveryClock(),
    this.logger,
  });

  Logger get _log => logger ?? _fallbackLogger;

  /// The `log show` invocation that re-reads this launch's announcements.
  ///
  /// `--start` and the predicate narrow the read; what makes an entry count
  /// is the pid-and-timestamp check [findSimLogVmServiceUri] runs on every
  /// returned entry.
  List<String> get logShowArgs => [
    'simctl',
    'spawn',
    query.udid,
    'log',
    'show',
    '--start',
    _formatShowStart(query.since),
    '--style',
    'json',
    '--predicate',
    'processIdentifier == ${query.pid} AND '
        '(eventMessage CONTAINS "Dart VM service" OR '
        'eventMessage CONTAINS "Observatory")',
  ];

  /// Poll `log show` and feed this launch's announcements into [out].
  ///
  /// Returns when [stop] completes — the discovery wait ends it however the
  /// wait concluded — or when [stop] is null never arrives, so a null stop
  /// polls until the caller drops the future. A failing or unparsable call
  /// is reported once per distinct failure and never ends the polling: the
  /// live stream and the next poll carry on.
  Future<void> feedAnnouncements(
    AppLogStream out, {
    Future<void>? stop,
  }) async {
    var stopped = false;
    final onStop = stop?.then((_) => stopped = true);
    final seen = <String>{};
    final reported = <String>{};
    while (!stopped) {
      await _pollOnce(out, seen, reported);
      if (stopped) break;
      final gap = Completer<void>();
      final timer = clock.startTimer(pollInterval, () {
        if (!gap.isCompleted) gap.complete();
      });
      try {
        if (onStop != null) {
          await Future.any([gap.future, onStop]);
        } else {
          await gap.future;
        }
      } finally {
        timer.cancel();
      }
    }
  }

  /// One `log show` read: feed this launch's announcement, if it is there.
  ///
  /// Spawn failures, refusals, and unparsable answers are reported once per
  /// distinct failure; the poller carries on either way. Text on stderr next
  /// to a zero exit is not a failure: the runners print there too, and the
  /// announcement on stdout still counts.
  Future<void> _pollOnce(
    AppLogStream out,
    Set<String> seen,
    Set<String> reported,
  ) async {
    final ProcessResult result;
    try {
      result = await runProcess('xcrun', logShowArgs);
    } on ProcessException catch (e) {
      _reportOnce(
        reported,
        'could not run `log show`: $e',
      );
      return;
    }
    if (result.exitCode != 0) {
      _reportOnce(
        reported,
        '`log show` exited with code ${result.exitCode}: ${result.stderr}',
      );
      return;
    }
    final Uri? uri;
    try {
      uri = findSimLogVmServiceUri(
        result.stdout as String,
        pid: query.pid,
        since: query.since,
      );
    } on FormatException catch (e) {
      _reportOnce(reported, 'could not parse `log show` output: $e');
      return;
    }
    if (uri == null) return;
    // One line, shaped like the stream's own: the wait matches on message
    // content, and this is the message the engine printed. `seen` keeps a
    // re-read log from announcing twice.
    if (seen.add(uri.toString())) {
      out.add('The Dart VM service is listening on $uri');
    }
  }

  /// Log a poll failure the first time its exact text appears.
  ///
  /// Once per *distinct* failure, not once per poll: a `log show` the
  /// simulator refuses for the whole wait says so one time, while a new
  /// failure mode still gets its own line.
  void _reportOnce(Set<String> reported, String detail) {
    if (!reported.add(detail)) return;
    _log.warning({
      'message': 'sim_log_fallback_poll_failed',
      'text':
          'The iOS simulator persisted-log fallback (`log show`) failed and '
          ' discovery continues on the live stream: $detail',
      'udid': query.udid,
      'pid': query.pid,
      'detail': detail,
    });
  }
}
