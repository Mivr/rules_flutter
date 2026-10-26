/// Tests for the iOS simulator launcher — `flutter_integration_test_ios.dart`.
///
/// There is no `xcrun` on Linux CI, so everything here runs through an
/// injected [CommandSpawner] (the way the boot test does) and an injected
/// launch starter: the happy path pins the exact `xcrun` argument lists and
/// the launch environment, and every failure path runs over canned children.
@Tags(['runfiles'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import '../flutter_integration_test_ios.dart' as ios;
import '../flutter_integration_test_launcher.dart' as launcher;
import '../flutter_integration_test_runner.dart' as runner;
import '../zip_writer.dart' show ZipEntry, encodeDeterministicZip;

/// A canned `simctl` child: output plus an optional hang (an exit that never
/// arrives, so the driver's deadline fires and must kill the child).
class CannedSimctl {
  const CannedSimctl({
    this.exitCode = 0,
    this.stdoutText = '',
    this.stderrText = '',
    this.hang = false,
  });

  final int exitCode;
  final String stdoutText;
  final String stderrText;
  final bool hang;
}

/// An [ios.CommandSpawner] stub keyed by the joined argument list, with
/// prefix entries for calls (like `install`) whose trailing argument (the
/// extracted app dir) the test only learns from the recorded calls.
class FakeSimctlSpawner implements ios.CommandSpawner {
  FakeSimctlSpawner(this.answers, {this.prefixAnswers = const {}});

  final Map<String, CannedSimctl> answers;
  final Map<String, CannedSimctl> prefixAnswers;

  final List<String> started = [];
  final List<String> killed = [];

  CannedSimctl? _lookup(String key) {
    final exact = answers[key];
    if (exact != null) return exact;
    for (final prefix in prefixAnswers.keys) {
      if (key.startsWith(prefix)) return prefixAnswers[prefix];
    }
    return null;
  }

  @override
  Future<ios.SpawnedCommand> start(
    String executable,
    List<String> args,
  ) async {
    final key = '$executable ${args.join(' ')}';
    started.add(key);
    final canned = _lookup(key);
    if (canned == null) fail('unexpected child: $key');
    return ios.SpawnedCommand(
      exitCode: canned.hang
          ? Completer<int>().future
          : Future.value(canned.exitCode),
      stdoutText: Future.value(canned.stdoutText),
      stderrText: Future.value(canned.stderrText),
      kill: () => killed.add(key),
    );
  }

  /// The recorded call starting with [prefix], failing the test when missing.
  String startedCall(String prefix) {
    return started.firstWhere(
      (s) => s.startsWith(prefix),
      orElse: () => fail('no started call with prefix: $prefix'),
    );
  }
}

/// One simulator entry in the synthetic listings below.
Map<String, dynamic> simulatorPhone(
  String udid, {
  String state = 'Shutdown',
}) => {
  'name': 'iPhone 17',
  'udid': udid,
  'state': state,
  'isAvailable': true,
};

/// A `simctl list -j` stdout describing [phones] on iOS 26.5.
String simulatorListing(List<Map<String, dynamic>> phones) => json.encode({
  'devices': {
    'com.apple.CoreSimulator.SimRuntime.iOS-26-5': phones,
  },
});

/// A minimal `.ipa` holding `Payload/TestApp.app/` with an executable binary,
/// a data file and a symlink, as [Uint8List].
Uint8List fixtureIpaBytes() => encodeDeterministicZip([
  ZipEntry(
    path: 'Payload/TestApp.app/',
    data: Uint8List(0),
    isDirectory: true,
  ),
  ZipEntry(
    path: 'Payload/TestApp.app/TestApp',
    data: Uint8List.fromList(utf8.encode('#!/bin/sh\nexit 0\n')),
    isExecutable: true,
  ),
  ZipEntry(
    path: 'Payload/TestApp.app/Info.plist',
    data: Uint8List.fromList(utf8.encode('<plist/>')),
  ),
  ZipEntry(
    path: 'Payload/TestApp.app/Frameworks/Link',
    data: Uint8List.fromList(utf8.encode('Target')),
    isSymlink: true,
  ),
]);

/// A minimal `.ipa` holding `Payload/TestApp.app/` plus one extra file
/// member at [extraPath], for the unsafe-path refusal tests.
Uint8List fixtureIpaWithExtra(String extraPath) => encodeDeterministicZip([
  ZipEntry(
    path: 'Payload/TestApp.app/',
    data: Uint8List(0),
    isDirectory: true,
  ),
  ZipEntry(
    path: extraPath,
    data: Uint8List.fromList(utf8.encode('evil')),
  ),
]);

/// A launch starter capturing its arguments and environment, returning a
/// process that exits on its own.
Future<Process> captureLaunch(
  Map<String, Object?> captured,
  String executable,
  List<String> args,
  Map<String, String> environment,
) async {
  captured['executable'] = executable;
  captured['args'] = args;
  captured['environment'] = environment;
  return Process.start(Platform.resolvedExecutable, ['--version']);
}

/// Boots through [spawner] against an `.app` directory input (no extraction),
/// capturing the launch.
Future<({ios.IosPlatformLauncher launcher, Map<String, Object?> launch})>
bootAppDir(
  FakeSimctlSpawner spawner,
  Directory appDir, {
  ios.IosLauncherBounds? bounds,
}) async {
  final launch = <String, Object?>{};
  final underTest = ios.IosPlatformLauncher(
    appPath: appDir.path,
    bundleId: 'com.example.testapp',
    baseTempDir: appDir.parent.path,
    spawner: spawner,
    launchProcess: (exe, args, env) => captureLaunch(launch, exe, args, env),
    bounds: bounds ?? const ios.IosLauncherBounds(),
  );
  await underTest.startTarget(4242);
  return (launcher: underTest, launch: launch);
}

/// The canned boot triple (listing, boot, bootstatus) for [udid].
Map<String, CannedSimctl> bootStubs(String udid, {bool skipBoot = false}) => {
  'xcrun simctl list -j': CannedSimctl(
    stdoutText: simulatorListing([simulatorPhone(udid)]),
  ),
  if (!skipBoot) 'xcrun simctl boot $udid': const CannedSimctl(),
  'xcrun simctl bootstatus $udid -b': const CannedSimctl(),
};

/// A canned `simctl get_app_container` answer resolving [bundleId] on [udid]
/// to [containerDir].
CannedSimctl containerStub(String containerDir) =>
    CannedSimctl(stdoutText: '$containerDir\n');

void main() {
  late Directory tmp;
  late Runfiles runfiles;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ios_launcher_test_');
    runfiles = Runfiles.create();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('iosLauncherFromEnv', () {
    test('names a missing app variable', () {
      expect(
        () => ios.iosLauncherFromEnv({}, runfiles),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('FLUTTER_INTEGRATION_TEST_IOS_APP'),
          ),
        ),
      );
    });

    test('names a missing bundle id', () {
      expect(
        () => ios.iosLauncherFromEnv(
          {'FLUTTER_INTEGRATION_TEST_IOS_APP': 'some/app.ipa'},
          runfiles,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('FLUTTER_INTEGRATION_TEST_IOS_BUNDLE_ID'),
          ),
        ),
      );
    });

    test('resolves the app through runfiles', () {
      final underTest = ios.iosLauncherFromEnv({
        'FLUTTER_INTEGRATION_TEST_IOS_APP': 'some/app.ipa',
        'FLUTTER_INTEGRATION_TEST_IOS_BUNDLE_ID': 'com.example.testapp',
      }, runfiles);
      expect(underTest.appPath, runfiles.rlocation('some/app.ipa'));
      expect(underTest.bundleId, 'com.example.testapp');
    });
  });

  group('startTarget', () {
    test(
      'boots, installs the extracted app and launches with the harness URL',
      () async {
        final ipa = File('${tmp.path}/TestApp.ipa')
          ..writeAsBytesSync(fixtureIpaBytes());
        final containerDir = '${tmp.path}/container-happy';
        final spawner = FakeSimctlSpawner(
          {
            ...bootStubs('udid-happy'),
            'xcrun simctl get_app_container udid-happy com.example.testapp data':
                containerStub(containerDir),
            'xcrun simctl terminate udid-happy com.example.testapp':
                const CannedSimctl(),
            'xcrun simctl uninstall udid-happy com.example.testapp':
                const CannedSimctl(),
          },
          prefixAnswers: {
            'xcrun simctl install udid-happy ': const CannedSimctl(),
          },
        );
        final launch = <String, Object?>{};
        final underTest = ios.IosPlatformLauncher(
          appPath: ipa.path,
          bundleId: 'com.example.testapp',
          baseTempDir: tmp.path,
          spawner: spawner,
          launchProcess: (exe, args, env) =>
              captureLaunch(launch, exe, args, env),
        );

        await underTest.startTarget(4242);

        // The calls happen in order: listing, boot, bootstatus, install of the
        // extracted app, get_app_container resolving the data container, then
        // the launch (which goes through the starter, not the spawner).
        expect(spawner.started[0], 'xcrun simctl list -j');
        expect(spawner.started[1], 'xcrun simctl boot udid-happy');
        expect(spawner.started[2], 'xcrun simctl bootstatus udid-happy -b');
        final install = spawner.startedCall(
          'xcrun simctl install udid-happy ',
        );
        expect(spawner.started.indexOf(install), 3);
        final extractedApp = install.split(' ').last;
        expect(extractedApp, endsWith('TestApp.app'));
        expect(Directory(extractedApp).existsSync(), isTrue);
        expect(
          spawner.started[4],
          'xcrun simctl get_app_container udid-happy com.example.testapp data',
        );

        expect(launch['executable'], 'xcrun');
        expect(
          launch['args'],
          [
            'simctl',
            'launch',
            '--console-pty',
            '--terminate-running-process',
            'udid-happy',
            'com.example.testapp',
          ],
        );
        // On iOS `Platform.environment` is always empty, so the app reads the
        // harness URL from the data-container file the launcher wrote; the
        // launch environment carries it too, on 127.0.0.1 with the harness
        // port.
        expect(
          File('$containerDir/tmp/flutter_integration_test_harness_url')
              .readAsStringSync(),
          'ws://127.0.0.1:4242${launcher.integrationWebSocketPath}',
        );
        expect(launch['environment'], {
          'SIMCTL_CHILD_FLUTTER_INTEGRATION_TEST_HARNESS_URL':
              'ws://127.0.0.1:4242${launcher.integrationWebSocketPath}',
        });

        await underTest.dispose();
        final terminate = spawner.startedCall(
          'xcrun simctl terminate udid-happy com.example.testapp',
        );
        final uninstall = spawner.startedCall(
          'xcrun simctl uninstall udid-happy com.example.testapp',
        );
        expect(
          spawner.started.indexOf(terminate),
          lessThan(spawner.started.indexOf(uninstall)),
        );
        expect(Directory(extractedApp).existsSync(), isFalse);
        expect(
          spawner.started.any((s) => s.contains('shutdown')),
          isFalse,
          reason: 'dispose leaves the simulator booted',
        );
      },
    );

    test(
      'writes the harness URL under the returned container path before launch',
      () async {
        final appDir = Directory('${tmp.path}/TestApp.app')..createSync();
        final containerDir = '${tmp.path}/container-write';
        final spawner = FakeSimctlSpawner(
          {
            ...bootStubs('udid-container'),
            'xcrun simctl get_app_container udid-container com.example.testapp data':
                containerStub(containerDir),
            'xcrun simctl terminate udid-container com.example.testapp':
                const CannedSimctl(),
            'xcrun simctl uninstall udid-container com.example.testapp':
                const CannedSimctl(),
          },
          prefixAnswers: {
            'xcrun simctl install udid-container ': const CannedSimctl(),
          },
        );
        var fileExistedAtLaunch = false;
        final launch = <String, Object?>{};
        final underTest = ios.IosPlatformLauncher(
          appPath: appDir.path,
          bundleId: 'com.example.testapp',
          baseTempDir: tmp.path,
          spawner: spawner,
          launchProcess: (exe, args, env) async {
            fileExistedAtLaunch = File(
              '$containerDir/tmp/flutter_integration_test_harness_url',
            ).existsSync();
            return captureLaunch(launch, exe, args, env);
          },
        );

        await underTest.startTarget(4242);

        expect(
          fileExistedAtLaunch,
          isTrue,
          reason: 'the URL file is written before the launch call',
        );
        expect(
          File('$containerDir/tmp/flutter_integration_test_harness_url')
              .readAsStringSync(),
          'ws://127.0.0.1:4242${launcher.integrationWebSocketPath}',
        );
        final installIndex = spawner.started.indexWhere(
          (s) => s.startsWith('xcrun simctl install '),
        );
        final containerIndex = spawner.started.indexOf(
          'xcrun simctl get_app_container udid-container com.example.testapp data',
        );
        expect(containerIndex, greaterThan(installIndex));

        await underTest.dispose();
      },
    );

    test(
      'a failing get_app_container names the step and never launches',
      () async {
        final appDir = Directory('${tmp.path}/TestApp.app')..createSync();
        final spawner = FakeSimctlSpawner(
          {
            ...bootStubs('udid-nocontainer'),
            'xcrun simctl get_app_container udid-nocontainer com.example.testapp data':
                const CannedSimctl(
                  exitCode: 1,
                  stderrText: 'no such app\n',
                ),
          },
          prefixAnswers: {
            'xcrun simctl install udid-nocontainer ': const CannedSimctl(),
          },
        );
        final underTest = ios.IosPlatformLauncher(
          appPath: appDir.path,
          bundleId: 'com.example.testapp',
          baseTempDir: tmp.path,
          spawner: spawner,
          launchProcess: (_, _, _) =>
              fail('must not launch without the harness URL file'),
        );

        await expectLater(
          underTest.startTarget(4242),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('iOS'),
                contains('get_app_container'),
                contains('exit 1'),
              ),
            ),
          ),
        );
      },
    );

    test(
      'a hanging get_app_container fails after its bound naming the step',
      () async {
        final appDir = Directory('${tmp.path}/TestApp.app')..createSync();
        final spawner = FakeSimctlSpawner(
          {
            ...bootStubs('udid-stuck'),
            'xcrun simctl get_app_container udid-stuck com.example.testapp data':
                const CannedSimctl(hang: true),
          },
          prefixAnswers: {
            'xcrun simctl install udid-stuck ': const CannedSimctl(),
          },
        );
        final underTest = ios.IosPlatformLauncher(
          appPath: appDir.path,
          bundleId: 'com.example.testapp',
          baseTempDir: tmp.path,
          spawner: spawner,
          launchProcess: (_, _, _) =>
              fail('must not launch without the harness URL file'),
          bounds: const ios.IosLauncherBounds(
            appContainerTimeout: Duration(seconds: 2),
          ),
        );

        await expectLater(
          underTest.startTarget(4242),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('iOS'),
                contains('get_app_container'),
                contains('timed out'),
              ),
            ),
          ),
        );
        expect(
          spawner.killed,
          hasLength(1),
          reason: 'the hung get_app_container child is killed past its bound',
        );
        expect(
          spawner.killed.single,
          startsWith('xcrun simctl get_app_container '),
        );
      },
    );

    test(
      'no available iOS runtime fails with the boot reason, never skips',
      () async {
        final appDir = Directory('${tmp.path}/TestApp.app')..createSync();
        final spawner = FakeSimctlSpawner({
          'xcrun simctl list -j': CannedSimctl(
            stdoutText: simulatorListing(const []),
          ),
        });
        final underTest = ios.IosPlatformLauncher(
          appPath: appDir.path,
          bundleId: 'com.example.testapp',
          baseTempDir: tmp.path,
          spawner: spawner,
          launchProcess: (_, _, _) => fail('must not launch without a device'),
        );

        await expectLater(
          underTest.startTarget(4242),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('iOS'),
                contains('no available iPhone'),
              ),
            ),
          ),
        );
        expect(spawner.started, ['xcrun simctl list -j']);
      },
    );

    test('a hanging install fails after its bound naming the step', () async {
      final appDir = Directory('${tmp.path}/TestApp.app')..createSync();
      final spawner = FakeSimctlSpawner(
        bootStubs('udid-slow'),
        prefixAnswers: {
          'xcrun simctl install udid-slow ': const CannedSimctl(hang: true),
        },
      );
      final underTest = ios.IosPlatformLauncher(
        appPath: appDir.path,
        bundleId: 'com.example.testapp',
        baseTempDir: tmp.path,
        spawner: spawner,
        launchProcess: (_, _, _) => fail('must not launch without installing'),
        bounds: const ios.IosLauncherBounds(
          installTimeout: Duration(seconds: 2),
        ),
      );

      await expectLater(
        underTest.startTarget(4242),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('iOS'),
              contains('install'),
              contains('timed out'),
            ),
          ),
        ),
      );
      expect(
        spawner.killed,
        hasLength(1),
        reason: 'the hung install child is killed past its bound',
      );
      expect(spawner.killed.single, startsWith('xcrun simctl install '));
    });

    test('a failed install names the step and the exit', () async {
      final appDir = Directory('${tmp.path}/TestApp.app')..createSync();
      final spawner = FakeSimctlSpawner(
        bootStubs('udid-denied'),
        prefixAnswers: {
          'xcrun simctl install udid-denied ': const CannedSimctl(
            exitCode: 1,
            stderrText: 'Unable to install: device locked\n',
          ),
        },
      );
      final underTest = ios.IosPlatformLauncher(
        appPath: appDir.path,
        bundleId: 'com.example.testapp',
        baseTempDir: tmp.path,
        spawner: spawner,
        launchProcess: (_, _, _) => fail('must not launch without installing'),
      );

      await expectLater(
        underTest.startTarget(4242),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('iOS'), contains('install'), contains('exit 1')),
          ),
        ),
      );
    });

    test('a launch that cannot start fails naming iOS', () async {
      final appDir = Directory('${tmp.path}/TestApp.app')..createSync();
      final spawner = FakeSimctlSpawner(
        {
          ...bootStubs('udid-grounded'),
          'xcrun simctl get_app_container udid-grounded com.example.testapp data':
              containerStub('${tmp.path}/container-grounded'),
        },
        prefixAnswers: {
          'xcrun simctl install udid-grounded ': const CannedSimctl(),
        },
      );
      final underTest = ios.IosPlatformLauncher(
        appPath: appDir.path,
        bundleId: 'com.example.testapp',
        baseTempDir: tmp.path,
        spawner: spawner,
        launchProcess: (_, _, _) async =>
            throw const ProcessException('xcrun', ['simctl']),
      );

      await expectLater(
        underTest.startTarget(4242),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('iOS'), contains('launch')),
          ),
        ),
      );
    });

    test('a launch that already exited non-zero fails naming iOS', () async {
      final appDir = Directory('${tmp.path}/TestApp.app')..createSync();
      final dead = await Process.start(
        Platform.resolvedExecutable,
        ['--no-such-option-xyz'],
      );
      final code = await dead.exitCode;
      expect(code, isNot(0));
      final spawner = FakeSimctlSpawner(
        {
          ...bootStubs('udid-dead'),
          'xcrun simctl get_app_container udid-dead com.example.testapp data':
              containerStub('${tmp.path}/container-dead'),
        },
        prefixAnswers: {
          'xcrun simctl install udid-dead ': const CannedSimctl(),
        },
      );
      final underTest = ios.IosPlatformLauncher(
        appPath: appDir.path,
        bundleId: 'com.example.testapp',
        baseTempDir: tmp.path,
        spawner: spawner,
        launchProcess: (_, _, _) async => dead,
      );

      await expectLater(
        underTest.startTarget(4242),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('iOS'), contains('launch')),
          ),
        ),
      );
    });

    test('a missing app fails naming iOS before any xcrun call', () async {
      final spawner = FakeSimctlSpawner({});
      final underTest = ios.IosPlatformLauncher(
        appPath: '${tmp.path}/Missing.ipa',
        bundleId: 'com.example.testapp',
        baseTempDir: tmp.path,
        spawner: spawner,
        launchProcess: (_, _, _) => fail('must not launch without an app'),
      );

      // Booting still happens first; with no listing stub the run fails as an
      // unexpected child, so point the listing at a device and watch the app
      // check fire before install.
      spawner.answers['xcrun simctl list -j'] = CannedSimctl(
        stdoutText: simulatorListing([simulatorPhone('udid-x')]),
      );
      spawner.answers['xcrun simctl boot udid-x'] = const CannedSimctl();
      spawner.answers['xcrun simctl bootstatus udid-x -b'] =
          const CannedSimctl();

      await expectLater(
        underTest.startTarget(4242),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('iOS'), contains('Missing.ipa')),
          ),
        ),
      );
      expect(
        spawner.started.any((s) => s.contains('simctl install')),
        isFalse,
      );
    });
  });

  group('extractIpaApp', () {
    test('keeps the app binary executable and links intact', () {
      final dest = Directory('${tmp.path}/extracted')..createSync();
      final appDir = ios.extractIpaApp(
        ipaBytes: fixtureIpaBytes(),
        destDir: dest,
      );

      expect(appDir, '${dest.path}/TestApp.app');
      final binary = File('$appDir/TestApp');
      expect(binary.existsSync(), isTrue);
      expect(
        FileStat.statSync(binary.path).mode & 0x49,
        isNot(0),
        reason: 'the archived executable bit survives extraction',
      );
      expect(binary.readAsStringSync(), contains('exit 0'));
      expect(File('$appDir/Info.plist').existsSync(), isTrue);
      expect(Link('$appDir/Frameworks/Link').targetSync(), 'Target');
    });

    test('extracts rules_apple-style directory entries', () {
      const appPrefix = 'Payload/TestApp.app/';
      final dest = Directory('${tmp.path}/rules_apple')..createSync();
      final ipa = encodeDeterministicZip([
        ZipEntry(
          path: 'Payload/',
          data: Uint8List(0),
          isDirectory: true,
        ),
        ZipEntry(
          path: appPrefix,
          data: Uint8List(0),
          isDirectory: true,
        ),
        ZipEntry(
          path: '${appPrefix}Base.lproj/LaunchScreen.storyboardc/',
          data: Uint8List(0),
          isDirectory: true,
        ),
        ZipEntry(
          path: '${appPrefix}Base.lproj/LaunchScreen.storyboardc/Info.plist',
          data: Uint8List.fromList(utf8.encode('<plist/>')),
        ),
        ZipEntry(
          path: '${appPrefix}TestApp',
          data: Uint8List.fromList(utf8.encode('#!/bin/sh\nexit 0\n')),
          isExecutable: true,
        ),
      ]);
      final appDir = ios.extractIpaApp(ipaBytes: ipa, destDir: dest);

      expect(appDir, '${dest.path}/TestApp.app');
      expect(
        Directory('$appDir/Base.lproj/LaunchScreen.storyboardc').existsSync(),
        isTrue,
        reason: 'nested directory entries extract as directories',
      );
      expect(
        File('$appDir/Base.lproj/LaunchScreen.storyboardc/Info.plist')
            .readAsStringSync(),
        '<plist/>',
      );
      expect(File('$appDir/TestApp').existsSync(), isTrue);
    });

    test('refuses an empty segment inside the path', () {
      final dest = Directory('${tmp.path}/empty_segment')..createSync();
      expect(
        () => ios.extractIpaApp(
          ipaBytes: fixtureIpaWithExtra('Payload/TestApp.app/a//b'),
          destDir: dest,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Refusing to extract unsafe .ipa entry'),
          ),
        ),
      );
    });

    test('refuses a dot segment', () {
      final dest = Directory('${tmp.path}/dot_segment')..createSync();
      expect(
        () => ios.extractIpaApp(
          ipaBytes: fixtureIpaWithExtra('Payload/TestApp.app/a/./b'),
          destDir: dest,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Refusing to extract unsafe .ipa entry'),
          ),
        ),
      );
    });

    test('refuses a dot-dot segment', () {
      final dest = Directory('${tmp.path}/dotdot_segment')..createSync();
      expect(
        () => ios.extractIpaApp(
          ipaBytes: fixtureIpaWithExtra('Payload/TestApp.app/a/../b'),
          destDir: dest,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Refusing to extract unsafe .ipa entry'),
          ),
        ),
      );
    });

    test('refuses an absolute path', () {
      final dest = Directory('${tmp.path}/absolute_path')..createSync();
      expect(
        () => ios.extractIpaApp(
          ipaBytes: fixtureIpaWithExtra('Payload/TestApp.app//absolute'),
          destDir: dest,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Refusing to extract unsafe .ipa entry'),
          ),
        ),
      );
    });

    test('refuses an archive with no app', () {
      final dest = Directory('${tmp.path}/empty')..createSync();
      final ipa = encodeDeterministicZip([
        ZipEntry(
          path: 'Payload/Notes.txt',
          data: Uint8List.fromList(utf8.encode('hi')),
        ),
      ]);
      expect(
        () => ios.extractIpaApp(ipaBytes: ipa, destDir: dest),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('exactly one .app'),
          ),
        ),
      );
    });
  });

  group('dispose', () {
    test('a failing terminate does not escape dispose', () async {
      final appDir = Directory('${tmp.path}/TestApp.app')..createSync();
      final spawner = FakeSimctlSpawner({
        ...bootStubs('udid-flaky'),
        'xcrun simctl install udid-flaky ${appDir.path}': const CannedSimctl(),
        'xcrun simctl get_app_container udid-flaky com.example.testapp data':
            containerStub('${tmp.path}/container-flaky'),
        'xcrun simctl terminate udid-flaky com.example.testapp':
            const CannedSimctl(
              exitCode: 1,
              stderrText: 'no such process\n',
            ),
        'xcrun simctl uninstall udid-flaky com.example.testapp':
            const CannedSimctl(),
      });
      final (:launcher, :launch) = await bootAppDir(spawner, appDir);

      expect(launch['executable'], 'xcrun');
      await launcher.dispose();

      expect(
        spawner.started,
        contains('xcrun simctl uninstall udid-flaky com.example.testapp'),
      );
    });

    test('without a boot there is nothing to terminate', () async {
      final appDir = Directory('${tmp.path}/TestApp.app')..createSync();
      final spawner = FakeSimctlSpawner({});
      final underTest = ios.IosPlatformLauncher(
        appPath: appDir.path,
        bundleId: 'com.example.testapp',
        baseTempDir: tmp.path,
        spawner: spawner,
      );

      await underTest.dispose();

      expect(spawner.started, isEmpty);
    });
  });

  group('runner', () {
    test('dispatches ios and lists it in the unsupported message', () {
      final underTest = runner.createPlatformLauncher('ios', {
        'FLUTTER_INTEGRATION_TEST_IOS_APP': 'some/app.ipa',
        'FLUTTER_INTEGRATION_TEST_IOS_BUNDLE_ID': 'com.example.testapp',
      }, runfiles);
      expect(underTest.platformName, 'ios');

      expect(
        () => runner.createPlatformLauncher('visionos', {}, runfiles),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('ios'),
          ),
        ),
      );
    });

    test('the iOS dial-back bound covers cold first launches', () {
      expect(
        ios.iosDialBackBound,
        greaterThanOrEqualTo(const Duration(seconds: 300)),
      );
      expect(
        ios.dialBackBoundForPlatform('ios'),
        greaterThanOrEqualTo(const Duration(seconds: 300)),
      );
      expect(
        ios.dialBackBoundForPlatform('android'),
        const Duration(seconds: 45),
      );
      expect(
        runner.dialBackBoundForPlatform('web'),
        const Duration(seconds: 45),
      );
    });
  });
}
