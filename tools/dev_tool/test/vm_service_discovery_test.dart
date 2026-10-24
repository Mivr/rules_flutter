/// Fake-time tests for VM-service discovery's waiting policy.
///
/// Every wait here runs on a [FakeVmDiscoveryClock]: virtual seconds pass
/// without real sleeps, so a 90 s announcement, a 40 s app exit and a bound
/// expiry all complete in milliseconds of test time.
import 'dart:async';

import 'package:flutter_bazel_dev_tool/app_log.dart';
import 'package:flutter_bazel_dev_tool/logging.dart';
import 'package:flutter_bazel_dev_tool/vm_service_discovery.dart';
import 'package:logging/logging.dart' show LogRecord;
import 'package:test/test.dart';

import 'fakes.dart';

/// The announcement every launch waits for.
const _vmServiceLine =
    'The Dart VM service is listening on http://127.0.0.1:12345/test=/';

/// A [VmDiscoveryClock] the test drives by hand.
///
/// `sleep` registers a timer; [advance] moves virtual time forward, firing
/// due timers and pumping the event queue between firings so the waiter
/// re-registers its next sleep before the scan continues. Nothing here waits
/// on wall time: the only real-time await is the zero-duration pump.
class FakeVmDiscoveryClock implements VmDiscoveryClock {
  DateTime _now;

  final List<({DateTime at, Completer<void> done})> _timers = [];

  /// A [VmDiscoveryClock] the test drives by hand, starting at [start].
  FakeVmDiscoveryClock({DateTime? start})
    : _now = start ?? DateTime(2026, 1, 1);

  @override
  DateTime now() => _now;

  @override
  Future<void> sleep(Duration duration) {
    final done = Completer<void>();
    _timers.add((at: _now.add(duration), done: done));
    return done.future;
  }

  /// Move virtual time forward by [duration], firing timers due on the way.
  ///
  /// After each firing the event queue is pumped several times so the waiter
  /// can react and re-register its next sleep before the scan continues;
  /// without that, a timer re-registered a few turns later would sit past its
  /// due instant with nothing left to fire it.
  Future<void> advance(Duration duration) async {
    final target = _now.add(duration);
    while (true) {
      _timers.sort((a, b) => a.at.compareTo(b.at));
      final index = _timers.indexWhere((t) => !t.at.isAfter(target));
      if (index == -1) break;
      final timer = _timers.removeAt(index);
      _now = timer.at;
      timer.done.complete();
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    _now = target;
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

/// Capture records on [loggerName] for the duration of the test.
List<LogRecord> captureLog(String loggerName) {
  final records = <LogRecord>[];
  final sub = Logger.root.onRecord.listen((record) {
    if (record.loggerName == loggerName) records.add(record);
  });
  addTearDown(sub.cancel);
  return records;
}

/// The `still waiting` progress records among [records].
List<Map> waitingLines(List<LogRecord> records) => records
    .map((r) => r.object)
    .whereType<Map>()
    .where((o) => o['message'] == 'vm_service_still_waiting')
    .toList();

void main() {
  group('waitForVmServiceUri in fake time', () {
    test(
      'an announcement after 90 s while the app is alive returns the URI '
      'and logs progress',
      () async {
        final clock = FakeVmDiscoveryClock();
        final records = captureLog('test.vm_discovery.late');
        final logs = AppLogStream();
        addTearDown(logs.close);
        final exit = Completer<int?>();

        final pending = waitForVmServiceUri(
          logs: logs,
          deviceName: 'iOS Simulator (TEST)',
          appExit: exit.future,
          config: VmDiscoveryConfig(
            bound: const Duration(seconds: 180),
            clock: clock,
          ),
          logger: Logger('test.vm_discovery.late'),
        );
        await clock.advance(const Duration(seconds: 90));
        logs.add(_vmServiceLine);
        final discovery = await pending;

        expect(
          discovery.uri.toString(),
          'http://127.0.0.1:12345/test=/',
        );
        expect(discovery.gaveUpNote, isNull);
        final progress = waitingLines(records);
        expect(progress.length, greaterThanOrEqualTo(2));
        for (final line in progress) {
          expect(line['text'], contains('still waiting for the VM service'));
          expect(line['text'], matches(RegExp(r'\d+s elapsed')));
        }
      },
    );

    test(
      'an app exit at 40 s fails at once with the exit code and the last '
      'log lines',
      () async {
        final clock = FakeVmDiscoveryClock();
        final start = clock.now();
        captureLog('test.vm_discovery.exit');
        final logs = AppLogStream();
        addTearDown(logs.close);
        final exit = Completer<int?>();
        logs.add('flutter: starting up');
        logs.add('flutter: Null check operator used on a null value');

        final pending = waitForVmServiceUri(
          logs: logs,
          deviceName: 'macOS',
          appExit: exit.future,
          config: VmDiscoveryConfig(
            bound: const Duration(seconds: 180),
            clock: clock,
          ),
          logger: Logger('test.vm_discovery.exit'),
        );
        await clock.advance(const Duration(seconds: 40));
        exit.complete(1);

        await expectLater(
          pending,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('macOS'),
                contains('exit code 1'),
                contains('Null check operator'),
                contains('Last app output'),
              ),
            ),
          ),
        );
        // At once, not at the bound: virtual time never left the exit.
        expect(clock.now().difference(start), const Duration(seconds: 40));
      },
    );

    test(
      'an app that stays alive and silent gives up at the bound with a note '
      'naming it and the option',
      () async {
        final clock = FakeVmDiscoveryClock();
        captureLog('test.vm_discovery.bound');
        final logs = AppLogStream();
        addTearDown(logs.close);
        final exit = Completer<int?>();

        final pending = waitForVmServiceUri(
          logs: logs,
          deviceName: 'macOS',
          appExit: exit.future,
          config: VmDiscoveryConfig(
            bound: const Duration(seconds: 65),
            clock: clock,
          ),
          logger: Logger('test.vm_discovery.bound'),
        );
        await clock.advance(const Duration(seconds: 200));
        // Giving up on a living app is not a throw: the run continues
        // without a URI, and the note carries the bound, the option that
        // raises it, and the last lines.
        final discovery = await pending;

        expect(discovery.uri, isNull);
        expect(
          discovery.gaveUpNote,
          allOf(
            contains('macOS'),
            contains('65s'),
            contains('--vm-service-timeout'),
          ),
        );
        // The exit never completed: nothing was awaited on a dead app.
        expect(exit.isCompleted, isFalse);
      },
    );

    test(
      'an announcement before 30 s returns at once, with no progress line',
      () async {
        final clock = FakeVmDiscoveryClock();
        final start = clock.now();
        final records = captureLog('test.vm_discovery.early');
        final logs = AppLogStream();
        addTearDown(logs.close);
        final exit = Completer<int?>();
        // Buffered before discovery starts: the replay delivers it, so the
        // wait never reaches its first progress point.
        logs.add(_vmServiceLine);

        final discovery = await waitForVmServiceUri(
          logs: logs,
          deviceName: 'Linux',
          appExit: exit.future,
          config: VmDiscoveryConfig(
            bound: const Duration(seconds: 180),
            clock: clock,
          ),
          logger: Logger('test.vm_discovery.early'),
        );

        expect(
          discovery.uri.toString(),
          'http://127.0.0.1:12345/test=/',
        );
        expect(discovery.gaveUpNote, isNull);
        expect(clock.now().difference(start), Duration.zero);
        expect(waitingLines(records), isEmpty);
      },
    );

    test(
      'a log source that ends where nothing observes the app returns null',
      () async {
        final clock = FakeVmDiscoveryClock();
        final logs = AppLogStream();

        final pending = waitForVmServiceUri(
          logs: logs,
          deviceName: 'Android (emulator-5554)',
          config: VmDiscoveryConfig(
            bound: const Duration(seconds: 180),
            clock: clock,
          ),
        );
        await logs.close();

        final discovery = await pending;
        expect(discovery.uri, isNull);
        expect(discovery.gaveUpNote, isNull);
      },
    );

    test(
      'a log source that ends on a living app gives up with a note naming '
      'the bound, the option, and the last lines',
      () async {
        final clock = FakeVmDiscoveryClock();
        final logs = AppLogStream();
        final exit = Completer<int?>();
        logs.add('flutter: warming up');
        logs.add('flutter: still warming up');

        final pending = waitForVmServiceUri(
          logs: logs,
          deviceName: 'Android (emulator-5554)',
          appExit: exit.future,
          config: VmDiscoveryConfig(
            bound: const Duration(seconds: 180),
            clock: clock,
          ),
        );
        var done = false;
        unawaited(
          pending.then((_) {
            done = true;
          }),
        );
        await logs.close();
        // Bounded steps, not one jump: the source-end grace registers only
        // once the wait observes the close, and a jump past it would leave
        // the grace sleep with nothing left to fire it.
        for (var i = 0; i < 60 && !done; i++) {
          await clock.advance(const Duration(seconds: 1));
        }
        expect(done, isTrue);
        final discovery = await pending;

        expect(discovery.uri, isNull);
        expect(
          discovery.gaveUpNote,
          allOf(
            contains('Android (emulator-5554)'),
            contains('180s'),
            contains('--vm-service-timeout'),
            contains('flutter: still warming up'),
            contains('Last app output'),
          ),
        );
        // The exit never completed: nothing was awaited on a dead app.
        expect(exit.isCompleted, isFalse);
      },
    );

    test(
      'an exit that lands just after the log source ends still fails with '
      'the exit code',
      () async {
        final clock = FakeVmDiscoveryClock();
        captureLog('test.vm_discovery.grace');
        final logs = AppLogStream();
        addTearDown(logs.close);
        final exit = Completer<int?>();
        logs.add('flutter: boom');

        final pending = waitForVmServiceUri(
          logs: logs,
          deviceName: 'Linux',
          appExit: exit.future,
          config: VmDiscoveryConfig(
            bound: const Duration(seconds: 180),
            clock: clock,
          ),
          logger: Logger('test.vm_discovery.grace'),
        );
        await logs.close();
        // The exit lands inside the source-end grace: the pipes closed a
        // breath before `exitCode` completed, and the exit still wins.
        exit.complete(1);

        await expectLater(
          pending,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('Linux'),
                contains('exit code 1'),
                contains('flutter: boom'),
              ),
            ),
          ),
        );
      },
    );
  });

  group('simulator liveness', () {
    test('parses the pid simctl launch reports', () {
      expect(
        parseSimctlLaunchPid('com.example.Runner: 51234\n'),
        51234,
      );
      expect(parseSimctlLaunchPid('com.example.Runner: 51234'), 51234);
      expect(parseSimctlLaunchPid(''), isNull);
      expect(parseSimctlLaunchPid('unexpected format'), isNull);
    });

    test(
      'watchHostPid completes once the probe reports the pid gone',
      () async {
        final clock = FakeVmDiscoveryClock();
        var alive = true;
        final watched = watchHostPid(
          pid: 4242,
          isAlive: (_) async => alive,
          config: VmDiscoveryConfig(clock: clock),
        );

        await clock.advance(const Duration(seconds: 40));
        alive = false;
        await clock.advance(const Duration(seconds: 5));

        // Null: a `ps` probe reports alive or not, never an exit code.
        expect(await watched, isNull);
      },
    );

    test('watchHostPid stops probing once the wait ends it', () async {
      final clock = FakeVmDiscoveryClock();
      var probes = 0;
      final stop = Completer<void>();
      final watched = watchHostPid(
        pid: 4242,
        isAlive: (_) async {
          probes++;
          return true;
        },
        config: VmDiscoveryConfig(clock: clock),
        stop: stop.future,
      );

      await clock.advance(const Duration(seconds: 40));
      expect(probes, greaterThan(0));
      final probesBeforeStop = probes;
      // The wait is over, whatever it concluded: end the `ps` polling.
      stop.complete();
      await clock.advance(const Duration(seconds: 60));

      expect(await watched, isNull);
      expect(probes, probesBeforeStop);
    });
  });

  group('child-process liveness', () {
    test(
      'an exited child process fails discovery at once with its exit code',
      () async {
        final clock = FakeVmDiscoveryClock();
        final start = clock.now();
        captureLog('test.vm_discovery.child');
        final logs = AppLogStream();
        final proc = FakeProcess();
        final pump = pumpProcessLines(proc, logs);
        logs.closeWhen([pump.done]);
        addTearDown(() async {
          await pump.dispose();
          await logs.close();
        });

        final pending = waitForVmServiceUri(
          logs: logs,
          deviceName: 'Linux',
          appExit: proc.exitCode,
          config: VmDiscoveryConfig(
            bound: const Duration(seconds: 120),
            clock: clock,
          ),
          logger: Logger('test.vm_discovery.child'),
        );
        proc.emitStdout('flutter: boom');
        // The advance below pumps the event queue while firing timers, so the
        // pump forwards the line into the log buffer — where the failure
        // message quotes it — before the exit lands.
        await clock.advance(const Duration(seconds: 40));
        proc.complete(1);

        await expectLater(
          pending,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('Linux'),
                contains('exit code 1'),
                contains('flutter: boom'),
              ),
            ),
          ),
        );
        expect(clock.now().difference(start), const Duration(seconds: 40));
      },
    );
  });

  group('parseVmServiceTimeoutOption', () {
    test('null means the default bound of at least three minutes', () {
      expect(
        parseVmServiceTimeoutOption(null),
        defaultVmServiceDiscoveryBound,
      );
      expect(
        defaultVmServiceDiscoveryBound.inSeconds,
        greaterThanOrEqualTo(180),
      );
    });

    test('a number means that many seconds', () {
      expect(
        parseVmServiceTimeoutOption('60'),
        const Duration(seconds: 60),
      );
    });

    test('anything else is a FormatException naming the option', () {
      for (final raw in ['0', '-5', 'abc', '1m30s']) {
        expect(
          () => parseVmServiceTimeoutOption(raw),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('--vm-service-timeout'),
            ),
          ),
          reason: 'for "$raw"',
        );
      }
    });
  });
}
