/// Tests for the iOS simulator boot script — `tool/boot_ios_simulator.dart`.
///
/// The script cannot boot anything on Linux or Windows CI (there is no
/// `xcrun` there, and the contract says that is simply one of its failures),
/// so everything here runs through an injected [CommandSpawner]: the
/// selection rules over synthetic listings, and every failure path over canned
/// child results. Driven through [bootSimulator] rather than a subprocess, so
/// these cases also pin the exact `xcrun` argument lists the script issues.
/// The fake answers a `simctl list` call the way `simctl` does: the `devices`
/// section always, the `runtimes` section only when the argv asks for it — so
/// a script that stopped asking for runtimes would pick an unavailable newest
/// runtime and fail its run as an unexpected child.
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
/// there is no `xcrun` — the shape the real spawner surfaces. A `simctl list`
/// call with no exact stub is answered from [listDevices]/[listRuntimes] the
/// way `simctl` answers: `devices` always, `runtimes` only when asked for.
class FakeSpawner implements CommandSpawner {
  final Map<String, CannedResult> results;
  final bool hasXcrun;
  final Map<String, List<Map<String, dynamic>>>? listDevices;
  final List<Map<String, dynamic>> listRuntimes;

  final started = <String>[];
  final killed = <String>[];

  FakeSpawner(
    this.results, {
    this.hasXcrun = true,
    this.listDevices,
    this.listRuntimes = const [],
  });

  /// The `simctl list` answer for [args], or null when this call is not a
  /// `devices` listing (or no sections were given).
  CannedResult? _listResponse(List<String> args) {
    final devices = listDevices;
    if (devices == null) return null;
    if (args.length < 3 || args[0] != 'simctl' || args[1] != 'list') {
      return null;
    }
    if (!args.contains('devices')) return null;
    return CannedResult(
      stdoutText: json.encode({
        'devices': devices,
        if (args.contains('runtimes')) 'runtimes': listRuntimes,
      }),
    );
  }

  @override
  Future<SpawnedCommand> start(String executable, List<String> args) async {
    final key = '$executable ${args.join(' ')}';
    started.add(key);
    if (!hasXcrun) {
      throw ProcessException(executable, args, 'No such file or directory', 2);
    }
    final canned = results[key] ?? _listResponse(args);
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

String listKey() => 'xcrun simctl list devices runtimes -j';

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

/// The [FakeSpawner] whose `list` call serves [devices] (and [runtimes] when
/// asked for, the way `simctl` does), plus any extra canned children.
FakeSpawner listingSpawner(
  Map<String, List<Map<String, dynamic>>> devices, {
  List<Map<String, dynamic>> runtimes = const [],
  Map<String, CannedResult> extra = const {},
}) => FakeSpawner(
  extra,
  listDevices: devices,
  listRuntimes: runtimes,
);

/// `boot` + `bootstatus` stubs for the device the run is expected to pick: a
/// wrong pick hits no stub and fails the test as an unexpected child.
Map<String, CannedResult> bootStubs(String udid, {bool skipBoot = false}) => {
  if (!skipBoot) 'xcrun simctl boot $udid': const CannedResult(),
  'xcrun simctl bootstatus $udid -b': const CannedResult(),
};

void main() {
  const ios265 = 'com.apple.CoreSimulator.SimRuntime.iOS-26-5';
  const ios2610 = 'com.apple.CoreSimulator.SimRuntime.iOS-26-10';

  group('simulator selection (whole path)', () {
    test('the list call asks simctl for devices and runtimes', () async {
      final spawner = listingSpawner({
        ios265: [
          device('iPhone 17', 'udid-0'),
        ],
      }, extra: bootStubs('udid-0'));
      await bootWith(spawner);
      expect(spawner.started.first, listKey());
    });

    test('takes the newest available iOS runtime, numerically', () async {
      final spawner = listingSpawner({
        'com.apple.CoreSimulator.SimRuntime.iOS-17-2': [
          device('iPhone 15', 'old'),
        ],
        ios265: [
          device('iPhone 17', 'mid'),
        ],
        ios2610: [
          device('iPhone 17 Pro', 'new'),
        ],
      }, extra: bootStubs('new'));
      final outcome = await bootWith(spawner);
      // 26.10 is newer than 26.5: a string compare would order them wrong.
      expect(outcome.udid, 'new');
    });

    test('ignores watchOS, tvOS and visionOS runtimes, however new', () async {
      final spawner = listingSpawner({
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
      }, extra: bootStubs('phone'));
      final outcome = await bootWith(spawner);
      expect(outcome.udid, 'phone');
    });

    test(
      'skips a newest runtime the runtimes array marks unavailable',
      () async {
        final spawner = listingSpawner(
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
          // Stubs only for the fallback: picking the unavailable newest fails
          // the run as an unexpected child.
          extra: bootStubs('mid'),
        );
        final outcome = await bootWith(spawner);
        expect(outcome.udid, 'mid');
        expect(
          spawner.startedCall('xcrun simctl boot new'),
          isFalse,
          reason: 'the unavailable newest runtime must never be booted',
        );
      },
    );

    test('fails when every iOS runtime is unavailable', () async {
      final spawner = listingSpawner(
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
          {'identifier': ios265, 'isAvailable': false},
        ],
      );
      await expectLater(
        bootWith(spawner),
        throwsA(
          isA<BootFailure>().having(
            (e) => e.reason,
            'reason',
            contains('no available iOS runtime'),
          ),
        ),
      );
      expect(
        spawner.started.where((s) => s.contains('simctl boot ')),
        isEmpty,
        reason: 'no runtime means nothing may be booted',
      );
    });

    test('prefers an already-booted iPhone wherever it is listed', () async {
      final spawner = listingSpawner({
        ios265: [
          device('iPhone 17', 'first'),
          device('iPhone 17 Pro', 'second', state: 'Booted'),
        ],
      }, extra: bootStubs('second', skipBoot: true));
      final outcome = await bootWith(spawner);
      expect(outcome.udid, 'second');
    });

    test('otherwise takes the first shutdown iPhone in listed order', () async {
      final spawner = listingSpawner({
        ios265: [
          device('iPad mini', 'pad', state: 'Booted'),
          device('iPhone 17', 'first'),
          device('iPhone 17 Pro', 'second'),
        ],
      }, extra: bootStubs('first'));
      // The booted iPad is not an iPhone; the first shutdown iPhone wins.
      final outcome = await bootWith(spawner);
      expect(outcome.udid, 'first');
    });

    test('ignores unavailable devices', () async {
      final spawner = listingSpawner({
        ios265: [
          device('iPhone 17', 'gone', available: false),
          device('iPhone 17 Pro', 'here'),
        ],
      }, extra: bootStubs('here'));
      final outcome = await bootWith(spawner);
      expect(outcome.udid, 'here');
    });

    test('fails when the listing names no available iOS runtime', () async {
      final spawner = listingSpawner(const {});
      await expectLater(
        bootWith(spawner),
        throwsA(
          isA<BootFailure>().having(
            (e) => e.reason,
            'reason',
            contains('no available iOS runtime'),
          ),
        ),
      );
    });

    test('fails without creating a device when no iPhone qualifies', () async {
      final spawner = listingSpawner({
        ios265: [
          device('iPad Pro', 'pad'),
          device('iPhone 17', 'gone', available: false),
        ],
      });
      await expectLater(
        bootWith(spawner),
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
