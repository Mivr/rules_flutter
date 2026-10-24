/// Tests for the iOS simulator boot script — `tool/boot_ios_simulator.dart`.
///
/// The script cannot boot anything on Linux or Windows CI (there is no
/// `xcrun` there, and the contract says that is simply one of its failures),
/// so everything here runs through an injected [CommandSpawner]: the
/// selection rules over synthetic listings, and every failure path over canned
/// child results. Driven through [bootSimulator] and [selectSimulator] rather
/// than a subprocess, so these cases also pin the exact `xcrun` argument
/// lists the script issues.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/boot_ios_simulator.dart';

/// A canned child result: output plus an optional hang (an exit that never
/// arrives, so the driver's deadline fires and must kill the child).
class CannedResult {
  final int exitCode;
  final String stdoutText;
  final String stderrText;
  final bool hang;

  const CannedResult({
    this.exitCode = 0,
    this.stdoutText = '',
    this.stderrText = '',
    this.hang = false,
  });
}

/// A [CommandSpawner] stub keyed by the joined argument list. Records every
/// start and every kill, and throws [ProcessException] for `xcrun` when told
/// there is no `xcrun` — the shape the real spawner surfaces.
class FakeSpawner implements CommandSpawner {
  final Map<String, CannedResult> results;
  final bool hasXcrun;

  final started = <String>[];
  final killed = <String>[];

  FakeSpawner(this.results, {this.hasXcrun = true});

  @override
  Future<SpawnedCommand> start(String executable, List<String> args) async {
    final key = '$executable ${args.join(' ')}';
    started.add(key);
    if (!hasXcrun) {
      throw ProcessException(executable, args, 'No such file or directory', 2);
    }
    final canned = results[key];
    if (canned == null) fail('unexpected child: $key');
    Future<int> exitCode;
    if (canned.hang) {
      exitCode = Completer<int>().future;
    } else {
      exitCode = Future.value(canned.exitCode);
    }
    return SpawnedCommand(
      exitCode: exitCode,
      stdoutText: Future.value(canned.stdoutText),
      stderrText: Future.value(canned.stderrText),
      kill: () => killed.add(key),
    );
  }

  bool startedCall(String key) => started.any((s) => s == key);
}

/// One device entry in the synthetic listings below.
Map<String, dynamic> device(
  String name,
  String udid, {
  String state = 'Shutdown',
  bool available = true,
}) => {
  'name': name,
  'udid': udid,
  'state': state,
  'isAvailable': available,
};

/// A listing with the given runtime keys (each `runtime key → devices`), plus
/// an optional `runtimes` array for runtime-level availability.
Map<String, dynamic> listing(
  Map<String, List<Map<String, dynamic>>> devices, {
  List<Map<String, dynamic>> runtimes = const [],
}) => {
  'devices': devices,
  if (runtimes.isNotEmpty) 'runtimes': runtimes,
};

String listKey() => 'xcrun simctl list devices -j';

/// Boots through [FakeSpawner] with a short `bootstatus` deadline, capturing
/// the progress lines. Returns the progress plus the reported udid.
Future<({List<String> log, String udid})> bootWith(
  FakeSpawner spawner, {
  Duration bootstatusTimeout = const Duration(seconds: 10),
}) async {
  final log = <String>[];
  final udid = await bootAndReport(
    BootOptions(
      spawner: spawner,
      bootstatusTimeout: bootstatusTimeout,
      log: log.add,
    ),
    log.add,
  );
  return (log: log, udid: udid);
}

/// The [FakeSpawner] whose `list` call serves [devices].
FakeSpawner listingSpawner(
  Map<String, List<Map<String, dynamic>>> devices, {
  List<Map<String, dynamic>> runtimes = const [],
  Map<String, CannedResult> extra = const {},
}) => FakeSpawner({
  listKey(): CannedResult(
    stdoutText: json.encode(listing(devices, runtimes: runtimes)),
  ),
  ...extra,
});

void main() {
  const ios265 = 'com.apple.CoreSimulator.SimRuntime.iOS-26-5';
  const ios2610 = 'com.apple.CoreSimulator.SimRuntime.iOS-26-10';

  group('selectSimulator', () {
    test('takes the newest available iOS runtime, numerically', () {
      final choice = selectSimulator(
        listing({
          'com.apple.CoreSimulator.SimRuntime.iOS-17-2': [
            device('iPhone 15', 'old'),
          ],
          ios265: [
            device('iPhone 17', 'mid'),
          ],
          ios2610: [
            device('iPhone 17 Pro', 'new'),
          ],
        }),
      );
      // 26.10 is newer than 26.5: a string compare would order them wrong.
      expect(choice.device.udid, 'new');
      expect(choice.runtime.label, 'iOS 26.10');
    });

    test('ignores watchOS, tvOS and visionOS runtimes, however new', () {
      final choice = selectSimulator(
        listing({
          ios265: [
            device('iPhone 17', 'phone'),
          ],
          'com.apple.CoreSimulator.SimRuntime.watchOS-26-5': [
            device('Apple Watch SE', 'watch'),
          ],
          'com.apple.CoreSimulator.SimRuntime.tvOS-99-0': [
            device('Apple TV', 'tv'),
          ],
          'com.apple.CoreSimulator.SimRuntime.visionOS-99-0': [
            device('Apple Vision Pro', 'vision'),
          ],
        }),
      );
      expect(choice.device.udid, 'phone');
    });

    test('skips a runtime the runtimes array marks unavailable', () {
      final choice = selectSimulator(
        listing(
          {
            ios265: [
              device('iPhone 17', 'mid'),
            ],
            ios2610: [
              device('iPhone 17 Pro', 'new'),
            ],
          },
          runtimes: [
            {'identifier': ios2610, 'isAvailable': false},
            {'identifier': ios265, 'isAvailable': true},
          ],
        ),
      );
      expect(choice.device.udid, 'mid');
    });

    test('prefers an already-booted iPhone wherever it is listed', () {
      final choice = selectSimulator(
        listing({
          ios265: [
            device('iPhone 17', 'first'),
            device('iPhone 17 Pro', 'second', state: 'Booted'),
          ],
        }),
      );
      expect(choice.device.udid, 'second');
      expect(choice.wasBooted, isTrue);
    });

    test('otherwise takes the first shutdown iPhone in listed order', () {
      final choice = selectSimulator(
        listing({
          ios265: [
            device('iPad mini', 'pad', state: 'Booted'),
            device('iPhone 17', 'first'),
            device('iPhone 17 Pro', 'second'),
          ],
        }),
      );
      // The booted iPad is not an iPhone; the first shutdown iPhone wins.
      expect(choice.device.udid, 'first');
      expect(choice.wasBooted, isFalse);
    });

    test('ignores unavailable devices', () {
      final choice = selectSimulator(
        listing({
          ios265: [
            device('iPhone 17', 'gone', available: false),
            device('iPhone 17 Pro', 'here'),
          ],
        }),
      );
      expect(choice.device.udid, 'here');
    });

    test('fails when the listing names no available iOS runtime', () {
      expect(
        () => selectSimulator(listing(const {})),
        throwsA(
          isA<BootFailure>().having(
            (e) => e.reason,
            'reason',
            contains('no available iOS runtime'),
          ),
        ),
      );
    });

    test('fails without creating a device when no iPhone qualifies', () {
      expect(
        () => selectSimulator(
          listing({
            ios265: [
              device('iPad Pro', 'pad'),
              device('iPhone 17', 'gone', available: false),
            ],
          }),
        ),
        throwsA(
          isA<BootFailure>().having(
            (e) => e.reason,
            'reason',
            allOf(contains('no available iPhone'), contains('iOS 26.5')),
          ),
        ),
      );
    });
  });

  group('parseBootTimeout', () {
    test('defaults to 600 seconds', () {
      expect(parseBootTimeout(const []), const Duration(seconds: 600));
    });

    test('takes the = form', () {
      expect(
        parseBootTimeout(const ['--timeout=30']),
        const Duration(seconds: 30),
      );
    });

    test('rejects a bare flag, an empty value and nonsense', () {
      for (final args in const [
        ['--timeout'],
        ['--timeout='],
        ['--timeout=soon'],
        ['--timeout=0'],
        ['--timeout=-5'],
        ['--verbose'],
      ]) {
        expect(
          () => parseBootTimeout(args),
          throwsA(isA<BootFailure>()),
          reason: '$args',
        );
      }
    });
  });

  group('bootSimulator', () {
    test('boots a shutdown phone, waits, and reports its udid last', () async {
      final spawner = listingSpawner(
        {
          ios265: [
            device('iPhone 17', 'udid-1'),
          ],
        },
        extra: const {
          'xcrun simctl boot udid-1': CannedResult(),
          'xcrun simctl bootstatus udid-1 -b': CannedResult(),
        },
      );
      final (:log, :udid) = await bootWith(spawner);

      expect(udid, 'udid-1');
      expect(log.last, 'booted udid-1');
      expect(log.join('\n'), contains('iPhone 17'));
      expect(log.join('\n'), contains('iOS 26.5'));
      expect(spawner.startedCall('xcrun simctl boot udid-1'), isTrue);
      expect(
        spawner.startedCall('xcrun simctl bootstatus udid-1 -b'),
        isTrue,
      );
    });

    test('skips boot for an already-booted phone but still waits', () async {
      final spawner = listingSpawner(
        {
          ios265: [
            device('iPhone 17', 'udid-2', state: 'Booted'),
          ],
        },
        extra: const {
          'xcrun simctl bootstatus udid-2 -b': CannedResult(),
        },
      );
      final (:log, :udid) = await bootWith(spawner);

      expect(udid, 'udid-2');
      expect(log.last, 'booted udid-2');
      expect(
        spawner.started.where((s) => s.contains('simctl boot ')),
        isEmpty,
        reason: 'an already-booted device must not be booted again',
      );
    });

    test('a missing xcrun fails naming xcrun', () async {
      final spawner = FakeSpawner(const {}, hasXcrun: false);
      await expectLater(
        bootWith(spawner),
        throwsA(
          isA<BootFailure>().having(
            (e) => e.reason,
            'reason',
            contains('no xcrun'),
          ),
        ),
      );
    });

    test('an unparsable listing fails rather than picking blindly', () async {
      final spawner = FakeSpawner({
        listKey(): const CannedResult(stdoutText: 'not json at all {'),
      });
      await expectLater(
        bootWith(spawner),
        throwsA(
          isA<BootFailure>().having(
            (e) => e.reason,
            'reason',
            contains('not valid JSON'),
          ),
        ),
      );
    });

    test('a failed boot names the call and its exit', () async {
      final spawner = listingSpawner(
        {
          ios265: [
            device('iPhone 17', 'udid-3'),
          ],
        },
        extra: const {
          'xcrun simctl boot udid-3': CannedResult(
            exitCode: 1,
            stderrText: 'Unable to boot device in current state: Booted\n',
          ),
        },
      );
      await expectLater(
        bootWith(spawner),
        throwsA(
          isA<BootFailure>().having(
            (e) => e.reason,
            'reason',
            allOf(contains('boot udid-3'), contains('exited 1')),
          ),
        ),
      );
    });

    test('a failed bootstatus fails the run', () async {
      final spawner = listingSpawner(
        {
          ios265: [
            device('iPhone 17', 'udid-4'),
          ],
        },
        extra: const {
          'xcrun simctl boot udid-4': CannedResult(),
          'xcrun simctl bootstatus udid-4 -b': CannedResult(
            exitCode: 1,
            stderrText: 'Device failed to boot\n',
          ),
        },
      );
      await expectLater(
        bootWith(spawner),
        throwsA(
          isA<BootFailure>().having(
            (e) => e.reason,
            'reason',
            contains('bootstatus udid-4'),
          ),
        ),
      );
    });

    test('a hung bootstatus is killed and fails naming the call', () async {
      final spawner = listingSpawner(
        {
          ios265: [
            device('iPhone 17', 'udid-5'),
          ],
        },
        extra: const {
          'xcrun simctl boot udid-5': CannedResult(),
          'xcrun simctl bootstatus udid-5 -b': CannedResult(hang: true),
        },
      );
      await expectLater(
        bootWith(
          spawner,
          bootstatusTimeout: const Duration(milliseconds: 50),
        ),
        throwsA(
          isA<BootFailure>().having(
            (e) => e.reason,
            'reason',
            allOf(contains('bootstatus udid-5'), contains('timed out')),
          ),
        ),
      );
      expect(
        spawner.killed,
        contains('xcrun simctl bootstatus udid-5 -b'),
      );
    });

    test('every failure reason is one line', () async {
      final spawner = listingSpawner(
        {
          ios265: [
            device('iPhone 17', 'udid-6'),
          ],
        },
        extra: const {
          'xcrun simctl boot udid-6': CannedResult(
            exitCode: 1,
            stderrText: 'first line\nsecond line\nthird line\n',
          ),
        },
      );
      final failure = await bootWith(spawner).then<BootFailure>(
        (_) => fail('expected a BootFailure'),
        onError: (Object e) => e as BootFailure,
      );
      expect(failure.reason, isNot(contains('\n')));
    });
  });
}
