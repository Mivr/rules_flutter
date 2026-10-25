/// Unit tests for the per-process e2e log recorder.
///
/// Each case wraps a real short-lived child process in a `DevToolProcess` and
/// reads back the `.log` file the recorder wrote. The children are Dart
/// scripts run with the VM executing the test, so they behave the same on
/// every host: interleaved stdout and stderr lines, one machine-protocol
/// envelope, and short sleeps between lines.
import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'e2e/dev_tool_e2e_harness.dart';
import 'e2e/dev_tool_e2e_log_recorder.dart';

/// Every record looks like `<stamp> <tag> <text>`, with a UTC stamp at
/// exactly millisecond precision.
final _recordShape = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z '
  r'(start|stdout|stderr|exit) ',
);

/// Splits one `<stamp> <tag> <text>` record.
({DateTime stamp, String tag, String text}) _parseRecord(String line) {
  final first = line.indexOf(' ');
  final second = line.indexOf(' ', first + 1);
  return (
    stamp: DateTime.parse(line.substring(0, first)),
    tag: line.substring(first + 1, second),
    text: line.substring(second + 1),
  );
}

/// Writes [body] as a Dart child script under [dir] and returns its path.
///
/// A real process with real stdout/stderr pipes is the point: only one can
/// prove a line is on disk while its process is still running.
Future<String> _writeChild(Directory dir, String name, String body) async {
  final script = File('${dir.path}${Platform.pathSeparator}$name.dart');
  await script.writeAsString(
    "import 'dart:async';\n"
    "import 'dart:io';\n"
    'Future<void> main() async {\n$body}\n',
  );
  return script.path;
}

/// Wraps a real child process running [script] in a `DevToolProcess`.
Future<DevToolProcess> _spawnChild(String script) async => DevToolProcess(
  await Process.start(Platform.resolvedExecutable, [script]),
);

/// The `.log` files in [dir].
List<File> _logFiles(Directory dir) => dir
    .listSync()
    .whereType<File>()
    .where((file) => file.path.endsWith('.log'))
    .toList();

/// Polls [read] until [done] holds or the budget runs out, then returns the
/// last value. Harness lists and log files both fill in asynchronously behind
/// the child, so every assertion below waits its turn instead of racing them.
Future<T> _poll<T>(Future<T> Function() read, bool Function(T) done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  var value = await read();
  while (!done(value)) {
    if (DateTime.now().isAfter(deadline)) return value;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    value = await read();
  }
  return value;
}

/// Stops [tool]'s process and disposes the harness. Safe to call on an
/// already-exited run: the kill is then a no-op and teardown takes the
/// graceful path.
Future<void> _stop(DevToolProcess tool) async {
  tool.process.kill();
  await tool.process.exitCode;
  await tool.dispose();
}

void main() {
  late Directory logDir;

  setUp(() async {
    logDir = await Directory.systemTemp.createTemp('dev-tool-e2e-log-');
    DevToolE2eLogRecorder.testOnlyLogDirectory = logDir.path;
  });

  tearDown(() {
    DevToolE2eLogRecorder.testOnlyLogDirectory = null;
    if (logDir.existsSync()) logDir.deleteSync(recursive: true);
  });

  test('one process gives one file with start, every line and exit', () async {
    final tool = await _spawnChild(
      await _writeChild(logDir, 'case_one', '''
  stdout.writeln('out-1');
  stderr.writeln('err-1');
  stdout.writeln('[{"event":"app.log","params":{}}]');
  await Future<void>.delayed(const Duration(milliseconds: 500));
  stdout.writeln('out-2');
  stderr.writeln('err-2');
'''),
    );
    try {
      await tool.process.exitCode;
      await _poll(
        () async => tool.nonProtocolStdoutLines.length,
        (n) => n >= 2,
      );
      await _poll(() async => tool.stderrLines.length, (n) => n >= 2);
      await _poll(() async => tool.events.length, (n) => n >= 1);
      await tool.dispose();

      final files = _logFiles(logDir);
      expect(files, hasLength(1));
      expect(files.single.path, contains('${tool.process.pid}'));
      final raw = files.single.readAsLinesSync();
      for (final line in raw) {
        expect(line, matches(_recordShape));
      }
      final records = raw.map(_parseRecord).toList();
      expect(records.first.tag, 'start');
      expect(records.first.text, contains('pid=${tool.process.pid}'));
      expect(records.last.tag, 'exit');
      expect(records.last.text, 'code=0');
      final stdoutTexts = [
        for (final record in records)
          if (record.tag == 'stdout') record.text,
      ];
      expect(stdoutTexts, [
        'out-1',
        '[{"event":"app.log","params":{}}]',
        'out-2',
      ]);
      expect(
        [
          for (final record in records)
            if (record.tag == 'stderr') record.text,
        ],
        ['err-1', 'err-2'],
      );

      // Recording changes nothing the test observes.
      expect(tool.nonProtocolStdoutLines, ['out-1', 'out-2']);
      expect(tool.stderrLines, ['err-1', 'err-2']);
      expect(
        tool.events.any((event) => event['event'] == 'app.log'),
        isTrue,
      );
    } finally {
      await _stop(tool);
    }
  });

  test('timestamps are taken when the harness receives each line', () async {
    final tool = await _spawnChild(
      await _writeChild(logDir, 'case_stamps', '''
  stdout.writeln('tick-one');
  await Future<void>.delayed(const Duration(seconds: 1));
  stdout.writeln('tick-two');
'''),
    );
    try {
      await tool.process.exitCode;
      await _poll(
        () async => tool.nonProtocolStdoutLines.length,
        (n) => n >= 2,
      );
      await tool.dispose();

      final files = _logFiles(logDir);
      expect(files, hasLength(1));
      final records = files.single
          .readAsLinesSync()
          .map(_parseRecord)
          .where((record) => record.tag == 'stdout')
          .toList();
      expect(records, hasLength(2));
      final gap = records[1].stamp.difference(records[0].stamp);
      // About the second the child slept: far above same-instant writes, far
      // below any scheduling stall.
      expect(gap.inMilliseconds, greaterThanOrEqualTo(500));
      expect(gap.inMilliseconds, lessThan(15000));
    } finally {
      await _stop(tool);
    }
  });

  test('a line is on disk while its process is still running', () async {
    final tool = await _spawnChild(
      await _writeChild(logDir, 'case_write_through', '''
  stdout.writeln('early-line');
  await Future<void>.delayed(const Duration(seconds: 30));
'''),
    );
    try {
      // The harness has read the line once it shows up in its own lists.
      await _poll(
        () async => tool.nonProtocolStdoutLines.contains('early-line'),
        (seen) => seen,
      );
      final files = _logFiles(logDir);
      expect(files, hasLength(1));
      expect(
        files.single.readAsLinesSync().any(
          (line) => line.endsWith(' stdout early-line'),
        ),
        isTrue,
        reason: 'the line the harness read must already be on disk',
      );
      // And the child that printed it must still be running.
      final exited = await Future.any([
        tool.process.exitCode.then((_) => true),
        Future<void>.delayed(const Duration(seconds: 2)).then((_) => false),
      ]);
      expect(
        exited,
        isFalse,
        reason: 'the line must be on disk before the child exits',
      );
    } finally {
      await _stop(tool);
    }
  });

  test('two processes give two files', () async {
    final first = await _spawnChild(
      await _writeChild(logDir, 'case_two_a', "  stdout.writeln('alpha');\n"),
    );
    final second = await _spawnChild(
      await _writeChild(logDir, 'case_two_b', "  stdout.writeln('beta');\n"),
    );
    try {
      await first.process.exitCode;
      await second.process.exitCode;
      await _poll(
        () async => first.nonProtocolStdoutLines.length,
        (n) => n >= 1,
      );
      await _poll(
        () async => second.nonProtocolStdoutLines.length,
        (n) => n >= 1,
      );
      await first.dispose();
      await second.dispose();

      final files = _logFiles(logDir);
      expect(files, hasLength(2));
      expect(files[0].path, isNot(files[1].path));
      final starts = {
        for (final file in files)
          _parseRecord(file.readAsLinesSync().first).text,
      };
      expect(starts, {
        'pid=${first.process.pid}',
        'pid=${second.process.pid}',
      });
    } finally {
      await _stop(first);
      await _stop(second);
    }
  });

  test(
    'an empty directory writes nothing and changes nothing observed',
    () async {
      DevToolE2eLogRecorder.testOnlyLogDirectory = '';
      final tool = await _spawnChild(
        await _writeChild(logDir, 'case_unset', '''
  stdout.writeln('plain-line');
  stderr.writeln('err-line');
  stdout.writeln('[{"event":"app.log","params":{}}]');
'''),
      );
      try {
        await tool.process.exitCode;
        await _poll(
          () async => tool.nonProtocolStdoutLines.length,
          (n) => n >= 1,
        );
        await _poll(() async => tool.stderrLines.length, (n) => n >= 1);
        await _poll(() async => tool.events.length, (n) => n >= 1);
        await tool.dispose();

        expect(_logFiles(logDir), isEmpty);
        expect(tool.nonProtocolStdoutLines, ['plain-line']);
        expect(tool.stderrLines, ['err-line']);
        expect(
          tool.events.any((event) => event['event'] == 'app.log'),
          isTrue,
        );

        // The unset variable takes the same path: no directory, no file.
        DevToolE2eLogRecorder.testOnlyLogDirectory = null;
        if ((Platform.environment[devToolE2eLogDirVar] ?? '').isEmpty) {
          expect(DevToolE2eLogRecorder.maybeStart(tool.process.pid), isNull);
        }
      } finally {
        await _stop(tool);
      }
    },
  );
}
