/// iOS simulator launcher for `flutter_integration_test`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';

import 'chmod.dart' as chmodlib;
import 'flutter_integration_test_launcher.dart';
import 'ios_simulator_boot.dart';
import 'test_support.dart';
import 'zip_reader.dart';
import 'zip_writer.dart' show ZipEntry;

export 'ios_simulator_boot.dart';

/// Name of the file, under the app data container's `tmp/`, through which the
/// launcher delivers the per-launch harness URL to the iOS app.
///
/// `Platform.environment` is always empty on iOS (the Dart SDK's
/// runtime/bin/platform_macos.cc returns no entries under DART_HOST_OS_IOS;
/// flutter/flutter#114849), so the `SIMCTL_CHILD_` launch environment never
/// reaches Dart. After install and before launch the launcher instead resolves
/// the app's data container with `simctl get_app_container` and writes the URL
/// to `<container>/tmp/<this name>`; the iOS bootstrap reads that path as
/// `Directory.systemTemp`, falling back from the environment variable. The
/// Linux bootstrap never reads it.
const iosHarnessUrlFileName = 'flutter_integration_test_harness_url';

/// How long the harness waits for an iOS simulator app to dial back before
/// failing the run.
///
/// COV-4 measured first launches near 240 s on cold CI runners, so iOS waits
/// several minutes; the other platforms keep 45 s (see
/// [dialBackBoundForPlatform]).
const iosDialBackBound = Duration(seconds: 300);

/// How long the harness waits for [platform]'s target to dial back before
/// failing the run: [iosDialBackBound] for iOS, 45 s for every other platform.
Duration dialBackBoundForPlatform(String platform) {
  if (platform == 'ios') return iosDialBackBound;
  return const Duration(seconds: 45);
}

/// Builds the iOS launcher: the simulator app on a booted iOS simulator via
/// `xcrun simctl`.
IosPlatformLauncher iosLauncherFromEnv(
  Map<String, String> env,
  Runfiles r,
) {
  final appKey = env['FLUTTER_INTEGRATION_TEST_IOS_APP'];
  final bundleId = env['FLUTTER_INTEGRATION_TEST_IOS_BUNDLE_ID'];
  if (appKey == null || appKey.isEmpty) {
    throw const FormatException(
      'FLUTTER_INTEGRATION_TEST_IOS_APP must be set for platform="ios".',
    );
  }
  if (bundleId == null || bundleId.isEmpty) {
    throw const FormatException(
      'FLUTTER_INTEGRATION_TEST_IOS_BUNDLE_ID must be set for platform="ios".',
    );
  }
  return IosPlatformLauncher(
    appPath: r.rlocation(appKey),
    bundleId: bundleId,
    baseTempDir: env['TEST_TMPDIR'] ?? Directory.systemTemp.path,
  );
}

/// The deadlines the iOS launcher's `xcrun simctl` calls run under.
///
/// Every call except the long-lived `launch` runs through the boot module's
/// bounded helpers under one of these; past a deadline the child is killed and
/// the run fails with one line naming the step and the bound. The install,
/// get_app_container, terminate and uninstall bounds are at least the
/// `verify_ios_simulator_test.dart` budgets (180 s, 60 s, 60 s); the listing
/// and boot bounds reuse the boot module's defaults.
class IosLauncherBounds {
  const IosLauncherBounds({
    this.listBounds = defaultListBounds,
    this.bootBounds = defaultBootBounds,
    this.bootstatusTimeout = const Duration(seconds: 600),
    this.installTimeout = const Duration(seconds: 180),
    this.appContainerTimeout = const Duration(seconds: 180),
    this.terminateTimeout = const Duration(seconds: 60),
    this.uninstallTimeout = const Duration(seconds: 60),
  });

  /// Bounds for `simctl list -j`, shared with [BootOptions]' default.
  final RetryBounds listBounds;

  /// Bounds for `simctl boot`, shared with [BootOptions]' default.
  final RetryBounds bootBounds;

  /// How long `simctl bootstatus -b` may take before the child is killed.
  final Duration bootstatusTimeout;

  /// How long `simctl install` may take before the child is killed.
  final Duration installTimeout;

  /// How long `simctl get_app_container` may take before the child is killed.
  ///
  /// Shares the install bound's 180 s default: resolving the container is an
  /// installd/containermanager query issued right after install, and on a
  /// cold simulator it is as slow as install (a cold-booted run saw it exceed
  /// 60 s). Pass an explicit value to bound it differently.
  final Duration appContainerTimeout;

  /// How long `simctl terminate` may take before the child is killed.
  final Duration terminateTimeout;

  /// How long `simctl uninstall` may take before the child is killed.
  final Duration uninstallTimeout;
}

/// Starts the long-lived `xcrun simctl launch` child carrying the harness URL.
///
/// Injected (rather than started directly) so tests can capture the launch
/// arguments and environment without an `xcrun`.
typedef LaunchProcess = Future<Process> Function(
  String executable,
  List<String> args,
  Map<String, String> environment,
);

/// Extracts `Payload/<name>.app` from the `.ipa` bytes [ipaBytes] under
/// [destDir], keeping executable bits and symlinks, and returns the extracted
/// app directory's path.
///
/// No host `unzip` or `ditto`: entries are read with `zip_reader.dart` and
/// written back with directories, files and links recreated. Exactly one
/// `.app` directly under `Payload/` must be present; anything else throws a
/// [FormatException] naming the `.ipa`.
String extractIpaApp({
  required Uint8List ipaBytes,
  required Directory destDir,
}) {
  final entries = readZipEntries(ipaBytes)
    ..sort((a, b) => a.path.compareTo(b.path));
  final appName = _singlePayloadApp(entries);
  final prefix = 'Payload/$appName/';
  for (final entry in entries) {
    if (!entry.path.startsWith(prefix)) continue;
    final rel = entry.path.substring(prefix.length);
    if (rel.isEmpty) continue;
    _writeIpaEntry(destDir, appName, rel, entry);
  }
  return '${destDir.path}/$appName';
}

/// The one `.app` directly under `Payload/`, or a failure naming what the
/// `.ipa` held instead.
String _singlePayloadApp(List<ZipEntry> entries) {
  final names = <String>{};
  for (final entry in entries) {
    final parts = entry.path.split('/');
    if (parts.length < 3 || parts[0] != 'Payload') continue;
    if (parts[1].isEmpty || !parts[1].endsWith('.app')) continue;
    names.add(parts[1]);
  }
  if (names.length != 1) {
    throw FormatException(
      'Expected exactly one .app directly under Payload/ in the .ipa, found '
      '${names.isEmpty ? 'none' : names.join(', ')}.',
    );
  }
  return names.single;
}

/// Writes one `.ipa` member below the extracted app directory, recreating
/// directories, files, executable bits and links.
void _writeIpaEntry(
  Directory destDir,
  String appName,
  String rel,
  ZipEntry entry,
) {
  // rules_apple writes explicit directory entries, which end in `/`. The
  // empty segment after that slash is the directory marker itself; an empty
  // segment anywhere else (`a//b`, a leading `/`), or a `.`/`..` segment,
  // is still refused below.
  final segments = rel.split('/');
  final names = rel.endsWith('/')
      ? segments.sublist(0, segments.length - 1)
      : segments;
  if (names.any((s) => s.isEmpty || s == '.' || s == '..')) {
    throw FormatException(
      'Refusing to extract unsafe .ipa entry: ${entry.path}.',
    );
  }
  final destPath = '${destDir.path}/$appName/$rel';
  if (entry.isDirectory) {
    Directory(destPath).createSync(recursive: true);
    return;
  }
  Directory(destPath).parent.createSync(recursive: true);
  if (entry.isSymlink) {
    _writeIpaSymlink(destPath, entry);
    return;
  }
  File(destPath).writeAsBytesSync(entry.data);
  if (entry.isExecutable) {
    // 0x1ed: the executable bit the archive recorded, as a full rwxr-xr-x.
    chmodlib.chmodFile(destPath, 0x1ed);
  }
}

/// Recreates one `.ipa` symlink member with its exact stored target.
void _writeIpaSymlink(String destPath, ZipEntry entry) {
  final target = utf8.decode(entry.data);
  if (target.isEmpty ||
      target.startsWith('/') ||
      target.split('/').any((s) => s.isEmpty || s == '..')) {
    throw FormatException(
      'Refusing to extract unsafe symlink ${entry.path} -> $target.',
    );
  }
  if (FileSystemEntity.typeSync(destPath, followLinks: false) !=
      FileSystemEntityType.notFound) {
    Link(destPath).deleteSync();
  }
  Link(destPath).createSync(target);
}

/// The first non-blank line of a child's output, or a placeholder when there
/// is none — the most that fits on a failure's one stderr line.
String _firstOutputLine(String output) {
  for (final line in const LineSplitter().convert(output)) {
    if (line.trim().isNotEmpty) return line.trim();
  }
  return 'no output';
}

/// Boots (or reuses) an iOS simulator, installs the built integration test
/// app on it and launches it against the harness.
///
/// The simulator shares the host's loopback, so the app reaches the harness
/// at 127.0.0.1 with no port forward. The harness URL reaches the app through
/// a file in its data container's `tmp/` (see [iosHarnessUrlFileName]): on iOS
/// `Platform.environment` is always empty, so no launch-environment variable
/// can carry it. Every failure throws (never skips) with
/// a one-line reason naming iOS.
class IosPlatformLauncher implements PlatformLauncher {
  IosPlatformLauncher({
    required this.appPath,
    required this.bundleId,
    required this.baseTempDir,
    CommandSpawner? spawner,
    LaunchProcess? launchProcess,
    this.bounds = const IosLauncherBounds(),
  }) : spawner = spawner ?? ProcessCommandSpawner(),
       launchProcess = launchProcess ?? _startLaunchProcess;

  /// Runfiles path of the simulator app: an `.ipa` file or an `.app`
  /// directory.
  final String appPath;

  /// Bundle id the app is installed, launched, terminated and uninstalled
  /// under.
  final String bundleId;

  /// Scratch parent for the extracted `.ipa`.
  final String baseTempDir;

  /// How `xcrun simctl` children are started; inject a stub to test without
  /// an `xcrun`.
  final CommandSpawner spawner;

  /// How the long-lived `simctl launch` child is started; injected in tests.
  final LaunchProcess launchProcess;

  /// The deadlines the bounded `simctl` calls run under.
  final IosLauncherBounds bounds;

  String? _udid;
  Directory? _scratchDir;
  bool _installed = false;
  bool _launched = false;

  @override
  String get platformName => 'ios';

  @override
  String get suiteRuntime => 'vm';

  @override
  String get suiteCompiler => 'kernel';

  @override
  Future<Process> startTarget(HarnessBinding binding) async {
    final udid = await _bootDevice();
    final appDir = _resolveAppDir();
    await _installApp(udid, appDir);
    final harnessUrl = binding.url;
    await _writeHarnessUrlFile(udid, harnessUrl);
    return _launchApp(udid, harnessUrl);
  }

  /// Boots or reuses a simulator with the boot module's selection rules.
  Future<String> _bootDevice() async {
    final SimulatorChoice choice;
    try {
      choice = await bootSimulator(
        BootOptions(
          spawner: spawner,
          bootstatusTimeout: bounds.bootstatusTimeout,
          log: print,
          listBounds: bounds.listBounds,
          bootBounds: bounds.bootBounds,
        ),
      );
    } on BootFailure catch (e) {
      throw StateError('iOS simulator boot failed: ${e.reason}');
    }
    _udid = choice.device.udid;
    return choice.device.udid;
  }

  /// Resolves the app directory to install: an `.app` directory is used as it
  /// is, an `.ipa` file is extracted into the test's temp dir.
  String _resolveAppDir() {
    if (Directory(appPath).existsSync()) return appPath;
    if (!File(appPath).existsSync()) {
      throw StateError(
        'iOS simulator app not found at "$appPath": '
        'expected an .ipa file or an .app directory.',
      );
    }
    final scratch = Directory(
      '$baseTempDir/ios_integration_${pid}_'
      '${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    _scratchDir = scratch;
    try {
      return extractIpaApp(
        ipaBytes: File(appPath).readAsBytesSync(),
        destDir: scratch,
      );
    } on Exception catch (e) {
      throw StateError('iOS simulator failed to extract "$appPath": $e');
    }
  }

  /// Installs the app on the booted simulator under its deadline.
  Future<void> _installApp(String udid, String appDir) async {
    final CommandResult result;
    try {
      result = await runSimctl(
        spawner,
        ['simctl', 'install', udid, appDir],
        timeout: bounds.installTimeout,
      );
    } on BootFailure catch (e) {
      throw StateError('iOS simulator install failed: ${e.reason}');
    }
    if (result.exitCode != 0) {
      throw StateError(
        'iOS simulator install of "$appDir" on $udid failed '
        '(exit ${result.exitCode}): ${_firstOutputLine(result.stderrText)}',
      );
    }
    _installed = true;
  }

  /// Delivers the harness URL through the app's data container.
  ///
  /// `Platform.environment` is always empty on iOS, so the `SIMCTL_CHILD_`
  /// launch environment never reaches Dart. After install and before launch
  /// the launcher instead resolves the app's data container with
  /// `simctl get_app_container` and writes the URL into a file under its
  /// `tmp/` (which the app reads as `Directory.systemTemp`). Either step
  /// failing fails the run naming that step, before any launch.
  Future<void> _writeHarnessUrlFile(String udid, String harnessUrl) async {
    final CommandResult result;
    try {
      result = await runSimctl(
        spawner,
        ['simctl', 'get_app_container', udid, bundleId, 'data'],
        timeout: bounds.appContainerTimeout,
      );
    } on BootFailure catch (e) {
      throw StateError('iOS simulator get_app_container failed: ${e.reason}');
    }
    if (result.exitCode != 0) {
      throw StateError(
        'iOS simulator get_app_container of "$bundleId" on $udid failed '
        '(exit ${result.exitCode}): ${_firstOutputLine(result.stderrText)}',
      );
    }
    var container = '';
    for (final line in const LineSplitter().convert(result.stdoutText)) {
      if (line.trim().isNotEmpty) {
        container = line.trim();
        break;
      }
    }
    if (container.isEmpty) {
      throw StateError(
        'iOS simulator get_app_container of "$bundleId" on $udid failed: '
        'no container path in its output.',
      );
    }
    try {
      final file = File('$container/tmp/$iosHarnessUrlFileName');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(harnessUrl);
    } on Exception catch (e) {
      throw StateError(
        'iOS simulator failed to write the harness URL for "$bundleId" '
        'on $udid: $e',
      );
    }
  }

  /// Launches the app carrying the harness URL, and returns the process whose
  /// output is the app's console.
  ///
  /// The URL travels in the data-container file [_writeHarnessUrlFile] wrote
  /// (on iOS `Platform.environment` is always empty, so the launched
  /// process's environment cannot carry it); it is also overlaid on the
  /// `simctl launch` child environment, which documents the launch and keeps
  /// working wherever the environment does reach Dart.
  Future<Process> _launchApp(String udid, String harnessUrl) async {
    final Process launched;
    try {
      launched = await launchProcess(
        'xcrun',
        [
          'simctl',
          'launch',
          '--console-pty',
          '--terminate-running-process',
          udid,
          bundleId,
        ],
        {
          'SIMCTL_CHILD_FLUTTER_INTEGRATION_TEST_HARNESS_URL': harnessUrl,
        },
      );
    } on Exception catch (e) {
      throw StateError(
        'iOS simulator launch of "$bundleId" on $udid failed: $e',
      );
    }
    final earlyExit = await launched.exitCode.timeout(
      Duration.zero,
      onTimeout: () => -1,
    );
    if (earlyExit != -1 && earlyExit != 0) {
      throw StateError(
        'iOS simulator launch of "$bundleId" on $udid failed '
        '(exit $earlyExit before the app connected).',
      );
    }
    _launched = true;
    return launched;
  }

  @override
  Future<void> handleHttpRequest(HttpRequest request) async {
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  @override
  Future<void> dispose() async {
    final udid = _udid;
    _udid = null;
    if (udid != null) {
      if (_launched) {
        await _bestEffortSimctl(
          'terminate',
          ['simctl', 'terminate', udid, bundleId],
          bounds.terminateTimeout,
        );
      }
      _launched = false;
      if (_installed) {
        await _bestEffortSimctl(
          'uninstall',
          ['simctl', 'uninstall', udid, bundleId],
          bounds.uninstallTimeout,
        );
      }
      _installed = false;
    }
    final scratch = _scratchDir;
    _scratchDir = null;
    if (scratch != null && scratch.existsSync()) {
      cleanupQuietly(() => scratch.deleteSync(recursive: true));
    }
  }

  /// Runs one teardown `simctl` call, reporting a failure on stderr instead of
  /// throwing: teardown must never mask the test's own result. The simulator
  /// itself is left booted.
  Future<void> _bestEffortSimctl(
    String step,
    List<String> args,
    Duration timeout,
  ) async {
    try {
      final result = await runSimctl(spawner, args, timeout: timeout);
      if (result.exitCode != 0) {
        stderr.writeln(
          'flutter_integration_test: iOS simulator $step of "$bundleId" '
          'exited ${result.exitCode}: ${_firstOutputLine(result.stderrText)}',
        );
      }
    } on Exception catch (e) {
      stderr.writeln(
        'flutter_integration_test: iOS simulator $step failed: $e',
      );
    }
  }
}

/// Starts [executable] with [args] and [environment], inheriting the parent
/// environment (which `xcrun` needs) with the harness URL overlaid.
Future<Process> _startLaunchProcess(
  String executable,
  List<String> args,
  Map<String, String> environment,
) {
  return Process.start(executable, args, environment: environment);
}
