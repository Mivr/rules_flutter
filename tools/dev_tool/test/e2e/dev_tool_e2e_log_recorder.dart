/// Per-process log of what the e2e harness observed from one wrapped process.
///
/// The iOS lane (`dev-tool-ios`) sets `DEV_TOOL_E2E_LOG_DIR` to a directory
/// under the runner's temp area and uploads that directory after the run, so
/// a red run keeps what the dev tool printed and when it printed it. The
/// harness otherwise keeps each process's output in memory only, and whatever
/// nobody waited on is lost with the runner.
///
/// One file per process, named for its pid and start time so the several
/// test-file VMs writing into one directory never collide. Each record is one
/// line, `<timestamp> <tag> <text>`:
///
/// * the timestamp is UTC wall-clock time with millisecond precision,
///   `YYYY-MM-DDTHH:MM:SS.mmmZ`, taken when the harness received the line;
/// * the tag is one of `start`, `stdout`, `stderr` or `exit`;
/// * the text is the line verbatim for `stdout`/`stderr` (machine-protocol
///   envelopes, non-protocol and empty lines included), `pid=<pid>` for
///   `start`, and `code=<exit code>` for `exit`.
///
/// Records are written through: each is on disk as soon as the harness has
/// read its line, while the process is still running. A failure to write
/// never fails or hangs a test: it is reported once on stderr and recording
/// stops for that process.
import 'dart:io';

/// The environment variable that turns per-process logging on.
///
/// When set and not empty, every process wrapped in a `DevToolProcess` writes
/// one `.log` file of its own into the named directory, created when missing.
/// When unset or empty, nothing is written anywhere.
const devToolE2eLogDirVar = 'DEV_TOOL_E2E_LOG_DIR';

/// Formats [time] as a UTC `YYYY-MM-DDTHH:MM:SS.mmmZ` stamp.
///
/// Exactly millisecond precision: sub-millisecond ticks are dropped, never
/// rounded up into the next millisecond, so the stamp never claims a time
/// later than the moment it was taken.
String formatDevToolE2eLogStamp(DateTime time) {
  final utc = time.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-'
      '${two(utc.day)}T${two(utc.hour)}:${two(utc.minute)}:'
      '${two(utc.second)}.${utc.millisecond.toString().padLeft(3, '0')}Z';
}

/// One wrapped process's log file.
///
/// Created through [maybeStart], fed from the harness's own stdout/stderr
/// listeners after they have handled each line, and finished either when the
/// process has exited and both streams have ended ([noteExit] plus
/// [noteStdoutDone] and [noteStderrDone]) or from teardown ([finishOnDispose]).
class DevToolE2eLogRecorder {
  /// Test hook: when non-null, replaces the environment lookup in
  /// [maybeStart], so unit tests can point the recorder at a temp directory
  /// without forking a VM with a set variable. Empty disables recording, the
  /// way an empty variable does. Production code never sets this.
  static String? testOnlyLogDirectory;

  final RandomAccessFile _sink;

  /// Where this process's records go. Tests read the file back through it.
  final String filePath;

  int? _exitCode;
  bool _stdoutDone = false;
  bool _stderrDone = false;
  bool _closed = false;
  bool _failed = false;

  DevToolE2eLogRecorder._(this._sink, {required this.filePath});

  /// Starts recording the process with [pid], or returns null when
  /// `DEV_TOOL_E2E_LOG_DIR` is unset or empty.
  ///
  /// Creates the directory when missing and writes the `start` record before
  /// returning, so a process that exits immediately still leaves a file that
  /// names its pid. Never throws: a directory or file that cannot be written
  /// is reported once on stderr and recording stays off for that process.
  static DevToolE2eLogRecorder? maybeStart(int pid) {
    final dirName =
        testOnlyLogDirectory ?? Platform.environment[devToolE2eLogDirVar];
    if (dirName == null || dirName.isEmpty) return null;
    try {
      return _open(dirName, pid, DateTime.now().toUtc());
    } on IOException catch (e) {
      stderr.writeln(
        'DevTool e2e log disabled for pid $pid: cannot write to "$dirName": '
        '$e',
      );
      return null;
    }
  }

  static DevToolE2eLogRecorder _open(
    String dirName,
    int pid,
    DateTime now,
  ) {
    final path = _uniquePath(dirName, pid, now);
    Directory(dirName).createSync(recursive: true);
    final recorder = DevToolE2eLogRecorder._(
      File(path).openSync(mode: FileMode.write),
      filePath: path,
    );
    recorder._appendAt('start', 'pid=$pid', now);
    return recorder;
  }

  /// A log file name carrying the pid and the start time, with a counter
  /// while one already exists, so two processes never share a file even when
  /// two VMs start same-pid processes in the same millisecond.
  static String _uniquePath(String dirName, int pid, DateTime now) {
    final stamp = formatDevToolE2eLogStamp(now).replaceAll(':', '-');
    var candidate = '$dirName${Platform.pathSeparator}dev-tool-$pid-$stamp.log';
    var n = 0;
    while (File(candidate).existsSync()) {
      n += 1;
      candidate =
          '$dirName${Platform.pathSeparator}dev-tool-$pid-$stamp-$n.log';
    }
    return candidate;
  }

  /// Records one line read from the process's stdout, verbatim.
  void recordStdout(String line) =>
      _appendAt('stdout', line, DateTime.now().toUtc());

  /// Records one line read from the process's stderr, verbatim.
  void recordStderr(String line) =>
      _appendAt('stderr', line, DateTime.now().toUtc());

  /// Notes the process's exit code. The `exit` record still waits for both
  /// streams to end, so every line read is already on disk when it lands.
  void noteExit(int code) {
    _exitCode = code;
    _finishIfReady();
  }

  /// Notes the stdout stream's end.
  void noteStdoutDone() {
    _stdoutDone = true;
    _finishIfReady();
  }

  /// Notes the stderr stream's end.
  void noteStderrDone() {
    _stderrDone = true;
    _finishIfReady();
  }

  void _finishIfReady() {
    if (_exitCode != null && _stdoutDone && _stderrDone) {
      _finish('code=$_exitCode');
    }
  }

  /// Ends the record from teardown's side, when the process may still be
  /// running: `code=?` while the exit code is not yet known. A no-op once the
  /// `exit` record is written. The file is closed after this returns.
  void finishOnDispose() {
    _finish('code=${_exitCode ?? '?'}');
  }

  void _appendAt(String tag, String text, DateTime at) {
    if (_closed || _failed) return;
    try {
      _sink.writeStringSync('${formatDevToolE2eLogStamp(at)} $tag $text\n');
      _sink.flushSync();
    } on IOException catch (e) {
      _failed = true;
      _closeQuietly();
      stderr.writeln('DevTool e2e log disabled for $filePath: $e');
    }
  }

  void _finish(String text) {
    if (_closed || _failed) return;
    _closed = true;
    try {
      _sink.writeStringSync(
        '${formatDevToolE2eLogStamp(DateTime.now().toUtc())} exit $text\n',
      );
    } on IOException catch (e) {
      stderr.writeln('DevTool e2e log disabled for $filePath: $e');
    }
    _closeQuietly();
  }

  void _closeQuietly() {
    try {
      _sink.closeSync();
    } on IOException catch (e) {
      stderr.writeln('DevTool e2e log disabled for $filePath: $e');
    }
  }
}
