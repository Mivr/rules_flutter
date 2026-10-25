import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/device_ios_sim.dart';
import 'package:flutter_bazel_dev_tool/device_ios_sim_discovery.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'fakes.dart';

/// Lines of one `log stream --style json` entry announcing [uri] from [pid]:
/// `"key" : value` fields closed by the `},{` delimiter Apple joins entries
/// with. The message comes before the pid, the way Apple's field order
/// prints them, so every test also proves the judgement does not depend on
/// field order.
List<String> _streamAnnouncement({
  required int pid,
  required String uri,
}) => [
  '  "traceID" : 37579774151491588,',
  '  "eventMessage" : ${json.encode('The Dart VM service is listening on $uri')},',
  '  "eventType" : "logEvent",',
  '  "processID" : $pid,',
  '},{',
];

/// Emit one [_streamAnnouncement] on [stream]'s stdout.
void _emitAnnouncement(
  FakeProcess stream, {
  required int pid,
  required String uri,
}) {
  for (final line in _streamAnnouncement(pid: pid, uri: uri)) {
    stream.emitStdout(line);
  }
}

/// The structured `message` of a log record, or null for plain-text records.
String? _messageOf(LogRecord record) {
  final object = record.object;
  if (object is Map) return object['message'] as String?;
  return null;
}

/// One scripted simulator launch through the device's injected runner and
/// starter with fake streams.
///
/// `simctl launch` reports pid 4242 once [openLaunch] completes; `ps`
/// answers [appAlive]; `log show` answers empty, so only the live stream can
/// announce.
class _ScriptedLaunch {
  _ScriptedLaunch({bool holdLaunch = false}) {
    if (!holdLaunch) openLaunch.complete();
    final device =
        IOSSimulatorDevice(
            udid: 'TEST-UDID',
            bundleId: 'com.example.test',
            runProcess: _run,
            startProcess: _start,
          )
          ..vmServiceTimeout = const Duration(seconds: 10)
          ..simLogFallbackPollInterval = const Duration(milliseconds: 10);
    done = device.launch('/path/to/MyApp.app');
  }

  /// What `simctl launch` reports, once [openLaunch] completes.
  static const launchPid = 4242;

  /// Whether the pid `simctl launch` reported is still running.
  ///
  /// Flipped by the app-exit test once the foreign announcement has been
  /// judged, so the exit lands after the stream was read.
  bool appAlive = true;

  /// The launch, for the test to await.
  late final Future<AppInstance> done;

  /// Completes the pending `simctl launch`, if it was held.
  final Completer<void> openLaunch = Completer<void>();

  FakeProcess? _discovery;
  FakeProcess? _output;
  final Completer<void> _bothSpawned = Completer<void>();
  int _spawns = 0;

  /// The discovery stream, once spawned. Await [FakeProcess.outputAttached]
  /// on it before emitting: the pid-gated pump reads from spawn, and the
  /// controllers are broadcast, so anything earlier is dropped.
  Future<FakeProcess> get discovery async {
    await _bothSpawned.future;
    return _discovery!;
  }

  /// The app-output stream, once spawned. It attaches before `simctl launch`
  /// answers in every version, so emitting into the discovery stream once
  /// this is attached proves the lines arrived before the pid was known.
  Future<FakeProcess> get output async {
    await _bothSpawned.future;
    return _output!;
  }

  Future<ProcessResult> _run(String exe, List<String> args) async {
    if (args.contains('show')) return ProcessResult(0, 0, '[]', '');
    if (exe == 'ps') return ProcessResult(0, appAlive ? 0 : 1, '', '');
    if (args.contains('launch')) {
      await openLaunch.future;
      return ProcessResult(0, 0, 'com.example.test: $launchPid', '');
    }
    return ProcessResult(0, 0, '', '');
  }

  Future<Process> _start(String exe, List<String> args) async {
    final process = FakeProcess();
    if (args.any((a) => a.contains('Dart VM service'))) {
      _discovery = process;
    } else {
      _output = process;
    }
    if (++_spawns == 2) _bothSpawned.complete();
    return process;
  }
}

void main() {
  group('iOS simulator discovery stream pid gate', () {
    test(
      'takes this launch announcement after another pid announces',
      () async {
        final launch = _ScriptedLaunch();
        final discovery = await launch.discovery;
        await discovery.outputAttached;
        _emitAnnouncement(
          discovery,
          pid: 9999,
          uri: 'http://127.0.0.1:1111/other=/',
        );
        _emitAnnouncement(
          discovery,
          pid: 4242,
          uri: 'http://127.0.0.1:4242/own=/',
        );

        final instance = await launch.done;
        expect(
          instance.vmServiceUri.toString(),
          'http://127.0.0.1:4242/own=/',
        );
      },
    );

    test('takes no announcement from other pids when the app exits', () async {
      final records = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(records.add);
      final launch = _ScriptedLaunch();
      try {
        final discovery = await launch.discovery;
        await discovery.outputAttached;
        _emitAnnouncement(
          discovery,
          pid: 9999,
          uri: 'http://127.0.0.1:1111/other=/',
        );
        // Let the stream judge the foreign announcement before the exit
        // lands: the skip is logged, and the wait then fails on the exit.
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!records.any(
          (r) => _messageOf(r) == 'sim_discovery_foreign_announcement',
        )) {
          if (DateTime.now().isAfter(deadline)) {
            fail('the foreign announcement was never judged');
          }
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        final text =
            (records
                        .firstWhere(
                          (r) =>
                              _messageOf(r) ==
                              'sim_discovery_foreign_announcement',
                        )
                        .object
                    as Map)['text']
                as String;
        expect(text, contains('9999'));
        expect(text, contains('http://127.0.0.1:1111/other=/'));

        launch.appAlive = false;
        await expectLater(launch.done, throwsStateError);
      } finally {
        await sub.cancel();
      }
    });

    test(
      'takes an announcement printed before simctl launch answers',
      () async {
        final launch = _ScriptedLaunch(holdLaunch: true);
        final discovery = await launch.discovery;
        // The output pump attaches before `simctl launch` answers, and the
        // discovery pump attaches earlier still: emitting now proves the
        // lines arrived while the pid was still unknown.
        await (await launch.output).outputAttached;
        _emitAnnouncement(
          discovery,
          pid: 4242,
          uri: 'http://127.0.0.1:4242/early=/',
        );
        // Let the lines reach the pump while the pid is still unknown, so
        // the announcement is held, not judged — then open the launch.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        launch.openLaunch.complete();

        final instance = await launch.done;
        expect(
          instance.vmServiceUri.toString(),
          'http://127.0.0.1:4242/early=/',
        );
      },
    );
  });

  group('sim discovery feed', () {
    test('skips the preamble, the header and blank lines', () async {
      final lines = AppLogStream();
      final feed = SimDiscoveryFeed(out: lines, log: Logger('test.feed'));
      feed.addLine('getpwuid_r did not find a match for uid 501');
      feed.addLine('Filtering the log data using "eventMessage CONTAINS ..."');
      feed.addLine('');
      feed.addLine(
        '  "eventMessage" : "The Dart VM service is listening on http://127.0.0.1:1/x=/",',
      );
      feed.addLine('},{');
      feed.setPid(null);

      expect(
        lines.read(-10).lines.map((l) => l.text),
        contains('The Dart VM service is listening on http://127.0.0.1:1/x=/'),
      );
      await lines.close();
    });

    test('reports a foreign announcement once, with pid and URI', () async {
      final records = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(records.add);
      try {
        final lines = AppLogStream();
        final feed = SimDiscoveryFeed(out: lines, log: Logger('test.feed'));
        feed.setPid(4242);
        for (var i = 0; i < 2; i++) {
          feed.addLine(
            '  "eventMessage" : "The Dart VM service is listening on http://127.0.0.1:9/f=/",',
          );
          feed.addLine('  "processID" : 9999,');
          feed.addLine('},{');
        }
        feed.flush();

        final foreign = records
            .where(
              (r) => _messageOf(r) == 'sim_discovery_foreign_announcement',
            )
            .toList();
        expect(foreign, hasLength(1));
        final text = (foreign.single.object as Map)['text'] as String;
        expect(text, contains('9999'));
        expect(text, contains('http://127.0.0.1:9/f=/'));
        expect(lines.read(-10).lines, isEmpty);
        await lines.close();
      } finally {
        await sub.cancel();
      }
    });

    test(
      'skips a pid-less announcement once the launch pid is known',
      () async {
        final lines = AppLogStream();
        final feed = SimDiscoveryFeed(out: lines, log: Logger('test.feed'));
        feed.setPid(4242);
        feed.addLine(
          '  "eventMessage" : "The Dart VM service is listening on http://127.0.0.1:9/n=/",',
        );
        feed.addLine('},{');
        feed.flush();

        expect(lines.read(-10).lines, isEmpty);
        await lines.close();
      },
    );
  });
}
