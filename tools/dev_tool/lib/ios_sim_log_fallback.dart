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

/// One `log show --style json` entry's discovery-relevant fields.
class _SimLogEntry {
  int? pid;
  DateTime? timestamp;
  String? message;
}

/// A line opening a JSON object starts a new entry, in both the
/// pretty-printed form (a bare `{`) and the compact form (the whole entry on
/// one line).
final _entryStart = RegExp(r'^\s*\{');

/// A line closing a pretty-printed entry: the brace is required, so blank
/// lines between entries end nothing.
final _entryEnd = RegExp(r'^\s*\},?\s*$');

/// `"processIdentifier" : 123` — the pid key spelled the way Apple's `log`
/// spells it, plus the shortenings a fixture or a future format may use.
final _entryPid = RegExp(
  r'"(?:processIdentifier|processID|processId|pid)"\s*:\s*(\d+)',
);

/// `"timestamp" : "..."` — the instant the entry was logged.
final _entryTimestamp = RegExp(r'"(?:timestamp|time)"\s*:\s*"([^"]+)"');

/// `"eventMessage" : "..."` — the full JSON string literal, escapes intact,
/// for `json.decode` to unquote.
final _entryMessage = RegExp(
  r'"(?:eventMessage|message)"\s*:\s*("(?:[^"\\]|\\.)*")',
);

/// `log show --start` takes `YYYY-MM-DD HH:MM:SS`-shaped instants; the
/// fallback reads in UTC so the text is unambiguous.
String _formatShowStart(DateTime instant) {
  final start = instant.toUtc();
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

/// Read one line's discovery fields into the entry under construction.
///
/// Field order is the entry's, not the reader's: pretty-printed entries put
/// the pid and timestamp on their own lines in whatever order `log` chooses,
/// and compact entries put everything on one line, so each line only adds
/// what it carries and the entry is judged when it ends.
void _readEntryLine(_SimLogEntry entry, String line) {
  final pid = _entryPid.firstMatch(line);
  if (pid != null) entry.pid ??= int.parse(pid.group(1)!);
  final timestamp = _entryTimestamp.firstMatch(line);
  if (timestamp != null) {
    entry.timestamp ??= _parseLogTimestamp(timestamp.group(1)!);
  }
  final message = _entryMessage.firstMatch(line);
  if (message != null && entry.message == null) {
    try {
      final decoded = json.decode(message.group(1)!);
      if (decoded is String) entry.message = decoded;
    } on FormatException {
      // A truncated line's half-string is no message; the entry simply has
      // none, which is judged below like any entry without one.
    }
  }
}

/// Judge a finished entry: this launch's announcement, or null.
///
/// Null covers every way an entry does not count — unfinished (no pid, no
/// timestamp, no message), another process's, older than the launch, or
/// carrying no announcement — because only a proven entry may feed
/// discovery.
Uri? _judgeEntry(
  _SimLogEntry? entry, {
  required int pid,
  required DateTime since,
}) {
  final message = entry?.message;
  if (message == null) return null;
  if (entry!.pid != pid) return null;
  final timestamp = entry.timestamp;
  if (timestamp == null || timestamp.isBefore(since)) return null;
  final match = vmServiceUriPattern.firstMatch(message);
  if (match == null) return null;
  return Uri.parse(match.group(1)!);
}

/// Find this launch's VM-service announcement in one `log show` call's
/// output, or null when it holds none.
///
/// Total over well-formed output: entries are judged in order and the first
/// proven one wins (`log show` reads oldest-first). Throws [FormatException]
/// when non-blank output holds no entry at all — that is not "no announcement
/// yet", it is a caller looking at something that is not `log show` JSON,
/// and the poller reports it rather than mistaking it for quiet.
Uri? findSimLogVmServiceUri(
  String output, {
  required int pid,
  required DateTime since,
}) {
  _SimLogEntry? current;
  var entries = 0;
  Uri? judge() {
    entries++;
    final found = _judgeEntry(current, pid: pid, since: since);
    current = null;
    return found;
  }

  for (final line in output.split('\n')) {
    if (_entryStart.hasMatch(line)) {
      if (current != null) {
        final found = judge();
        if (found != null) return found;
      }
      current = _SimLogEntry();
    }
    final entry = current;
    if (entry == null) continue;
    // A compact entry's only line opens it and carries its fields together;
    // a lone `{` carries none, so reading every non-closing line is what
    // covers both shapes.
    if (_entryEnd.hasMatch(line)) {
      final found = judge();
      if (found != null) return found;
    } else {
      _readEntryLine(entry, line);
    }
  }
  if (current != null) {
    // A compact entry is judged on its single line above; reaching here with
    // one still open means trailing lines without a closer, which judge the
    // same either way.
    final found = judge();
    if (found != null) return found;
  }
  if (output.trim().isNotEmpty && entries == 0) {
    final head = output.trim();
    throw FormatException(
      'expected `log show --style json` entries, got: '
      '${head.substring(0, head.length < 120 ? head.length : 120)}',
    );
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
  /// distinct failure; the poller carries on either way.
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
