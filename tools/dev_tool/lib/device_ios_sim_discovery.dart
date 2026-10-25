/// Pid-gated live-stream discovery for the iOS Simulator.
///
/// The discovery stream runs `simctl spawn <udid> log stream --style json`,
/// which prints one pretty-printed JSON entry per log line: entries joined by
/// `},{` lines, `"key" : value` fields, exactly as `log show --style json`
/// prints them (see the `simulators_test.dart` fixtures in flutter_tools).
/// Every entry carries the writing process in `processID`, so the stream
/// judges each VM-service announcement by the pid `simctl launch` reported
/// for this launch — the same check the persisted-log fallback runs, so a
/// concurrent app or a second dev_tool session on the same simulator can
/// never hand discovery its own URI. Matching the app name or bundle path
/// would not do: a second session of the same app has the same path and a
/// different pid.
///
/// The stream starts before `simctl launch` returns, so the pid is not known
/// when the first entries arrive. Announcements parsed before the pid arrives
/// are held, then judged once it does: an early announcement that turns out
/// to be this launch's is still taken, and one from any other pid never is.
/// No pid from `simctl launch` (an unknown format) keeps the old behaviour,
/// where the stream takes the first announcement.
///
/// Non-entry lines — the runners' `getpwuid_r did not find a match for uid
/// 501` preamble, the stream's `Filtering the log data using ...` header, any
/// other line that is neither a field nor a delimiter — are skipped, not
/// fatal. An announcement from another pid is reported once per pid and URI
/// at warning level, so a concurrent app is visible in the run log.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_log.dart';
import 'ios_sim_log_fallback.dart';
import 'logging.dart';

/// One `"key" : value` field of a pretty-printed `log --style json` entry.
///
/// The value runs to the end of the line, trailing comma included: it is
/// stripped before decoding, so `  "processID" : 4242,` reads as `4242`.
final _fieldPattern = RegExp(r'^"([^"]+)"\s*:\s*(.+?)\s*$');

/// The `[{`, `},{` and `}]` lines joining pretty-printed entries.
///
/// A field line always carries quotes and a colon, so the two shapes never
/// overlap: anything that is neither is a non-entry line and is skipped.
final _entryBoundary = RegExp(r'^[\[\]{},]+$');

/// One parsed announcement: the URI, the message that carried it, and the pid
/// of the entry that carried it.
///
/// A null [pid] means the entry carried no process id at all, so it cannot
/// prove it is this launch's.
typedef SimStreamAnnouncement = ({int? pid, Uri uri, String message});

/// Reads `log stream --style json` lines and forwards this launch's
/// VM-service announcement.
///
/// One feed per launch: entries are judged by the pid `simctl launch`
/// reported, delivered through [setPid]. Announcements parsed before the pid
/// arrives are held, then judged — never dropped, never taken blind.
class SimDiscoveryFeed {
  /// Reads `log stream --style json` lines for one launch.
  SimDiscoveryFeed({required this.out, required this.log});

  /// Where this launch's announcement goes.
  final AppLogStream out;

  /// Where the foreign-announcement lines go.
  final Logger log;

  /// The pid `simctl launch` reported, once [setPid] has run.
  int? _launchPid;

  /// Whether [setPid] has run: nothing is judged before it.
  bool _pidKnown = false;

  /// Announcements parsed before the pid arrived, for [setPid] to judge.
  final List<SimStreamAnnouncement> _held = [];

  /// Foreign announcements already reported, by pid and URI.
  final Set<String> _reportedForeign = {};

  /// The entry in flight: decoded `"key" : value` fields so far.
  Map<String, Object?> _current = {};

  /// Read one stream line: a field joins the entry in flight, a delimiter
  /// ends it, anything else is skipped, not fatal.
  void addLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    final field = _fieldPattern.firstMatch(trimmed);
    if (field != null) {
      _addField(field.group(1)!, field.group(2)!);
      return;
    }
    if (_entryBoundary.hasMatch(trimmed)) _endEntry();
    // Anything else — the `getpwuid_r ...` preamble, the `Filtering the log
    // data using ...` header — is skipped, not fatal.
  }

  /// Judge every announcement parsed so far against [pid], then judge every
  /// later one live.
  ///
  /// A null [pid] is the unknown `simctl launch` format: with nothing to
  /// check against, the held announcements are taken in order, as before.
  void setPid(int? pid) {
    _launchPid = pid;
    _pidKnown = true;
    for (final announcement in _held) {
      _judge(announcement);
    }
    _held.clear();
  }

  /// Judge a trailing entry the stream's end cut off from its delimiter.
  void flush() => _endEntry();

  /// Decode one `"key" : value` field into the entry in flight.
  ///
  /// A field whose value does not decode is skipped, not fatal: one odd
  /// field must not lose the entry around it.
  void _addField(String key, String rawValue) {
    var value = rawValue.trim();
    if (value.endsWith(',')) value = value.substring(0, value.length - 1);
    try {
      _current[key] = json.decode(value);
    } on FormatException {
      // Skip the field, keep the entry: the lines around it still judge.
    }
  }

  /// Judge the entry in flight, if it announces a VM service.
  ///
  /// Held when the pid is not known yet; otherwise taken when it proves to
  /// be this launch's, reported and skipped when it does not.
  void _endEntry() {
    if (_current.isEmpty) return;
    final entry = _current;
    _current = {};
    final message = simLogEntryMessage(entry);
    if (message == null) return;
    final uri = simLogAnnouncementUri(message);
    if (uri == null) return;
    final announcement = (
      pid: simLogEntryPid(entry),
      uri: uri,
      message: message,
    );
    if (!_pidKnown) {
      _held.add(announcement);
      return;
    }
    _judge(announcement);
  }

  /// Judge one announcement: take this launch's, report and skip any other's.
  ///
  /// An entry with no pid cannot prove it is this launch's, so with a known
  /// launch pid it is skipped like any other unproven entry. No launch pid
  /// keeps the old behaviour — the first announcement wins — because there
  /// is nothing to check against.
  void _judge(SimStreamAnnouncement announcement) {
    final pid = announcement.pid;
    if (_launchPid == null || pid == _launchPid) {
      out.add(announcement.message);
      return;
    }
    final key = '$pid:${announcement.uri}';
    if (_reportedForeign.add(key)) {
      log.warning({
        'message': 'sim_discovery_foreign_announcement',
        'text':
            'The iOS simulator live stream saw a VM-service announcement '
            'from another process (pid $pid): ${announcement.uri}. It was '
            "not taken; discovery keeps waiting for this launch's "
            'announcement.',
        'pid': pid,
        'uri': announcement.uri.toString(),
      });
    }
  }
}

/// The live source of one simulator launch's VM-service discovery.
///
/// Starts reading its `log stream` process pid-gated from the first line:
/// the pid arrives through [pid] once `simctl launch` answers, and entries
/// parsed before then are held, not dropped, and judged once it does.
class SimDiscoverySource {
  /// Start reading [process] pid-gated from its first line.
  ///
  /// Both output streams are drained from the start, so nothing the stream
  /// prints before `simctl launch` answers is lost; judging starts once
  /// [pid] completes. [pump] ends with the process, and [dispose] ends it
  /// with discovery — either way [lines] keeps what was judged this
  /// launch's, for the discovery wait to read.
  SimDiscoverySource(Process process, {required Logger logger})
    : process = process {
    final feed = SimDiscoveryFeed(out: lines, log: logger);
    pump = pumpProcessLines(
      process,
      lines,
      transform: (line) {
        feed.addLine(line);
        return null;
      },
    );
    unawaited(pump.done.then((_) => feed.flush()));
    unawaited(pid.future.then(feed.setPid));
  }

  /// The `log stream` process being read.
  final Process process;

  /// This launch's announcement, once judged to be its own, lands here.
  final AppLogStream lines = AppLogStream();

  /// The pid `simctl launch` reports for this launch, once it answers.
  ///
  /// Complete it right after the launch call: entries parsed before then are
  /// held, and completing with null (an unknown `simctl` format) keeps the
  /// old behaviour, where the stream takes the first announcement.
  final Completer<int?> pid = Completer<int?>();

  /// Forwards [process] into [lines] until the process ends or [dispose].
  late final AppLogPump pump;

  /// Stop forwarding and release [lines].
  ///
  /// The discovery wait's `finally` gets here however the wait concluded, and
  /// a build mode that serves no VM service comes here instead of waiting.
  Future<void> dispose() async {
    await pump.dispose();
    await lines.close();
  }
}
