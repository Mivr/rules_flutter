/// Android emulator launcher for `flutter_integration_test`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

import 'flutter_integration_test_launcher.dart';
import 'test_support.dart';

/// Builds the Android launcher: the APK on a hermetic emulator via `adb`.
AndroidPlatformLauncher androidLauncherFromEnv(
  Map<String, String> env,
  Runfiles r,
) {
  final apkKey = env['FLUTTER_INTEGRATION_TEST_ANDROID_APK'];
  final packageName = env['FLUTTER_INTEGRATION_TEST_ANDROID_PACKAGE'];
  final emulatorKey = env['FLUTTER_INTEGRATION_TEST_ANDROID_EMULATOR'];
  final adbKey = env['FLUTTER_INTEGRATION_TEST_ANDROID_ADB'];
  if (apkKey == null || apkKey.isEmpty) {
    throw const FormatException(
      'FLUTTER_INTEGRATION_TEST_ANDROID_APK must be set for platform="android".',
    );
  }
  if (packageName == null || packageName.isEmpty) {
    throw const FormatException(
      'FLUTTER_INTEGRATION_TEST_ANDROID_PACKAGE must be set for platform="android".',
    );
  }
  if (emulatorKey == null || emulatorKey.isEmpty) {
    throw const FormatException(
      'FLUTTER_INTEGRATION_TEST_ANDROID_EMULATOR must be set for platform="android".',
    );
  }
  if (adbKey == null || adbKey.isEmpty) {
    throw const FormatException(
      'FLUTTER_INTEGRATION_TEST_ANDROID_ADB must be set for platform="android".',
    );
  }
  final apkPath = r.rlocation(apkKey);
  final emulatorBinary = r.rlocation(emulatorKey);
  final adbBinary = r.rlocation(adbKey);
  final kvmPath = env['FLUTTER_INTEGRATION_TEST_KVM_PATH'] ?? '/dev/kvm';
  return AndroidPlatformLauncher(
    apkPath: apkPath,
    packageName: packageName,
    emulatorBinary: emulatorBinary,
    adbBinary: adbBinary,
    baseTempDir: env['TEST_TMPDIR'] ?? Directory.systemTemp.path,
    kvmPath: kvmPath,
  );
}

/// Verifies that [kvmPath] (normally `/dev/kvm`) exists and is both readable
/// and writable by the current process.
///
/// Throws a [StateError] with an actionable message when `/dev/kvm` is missing
/// or inaccessible so the test fails immediately rather than hanging or
/// silently skipping.
void verifyKvmAvailable(String kvmPath) {
  RandomAccessFile? reader;
  RandomAccessFile? writer;
  try {
    reader = File(kvmPath).openSync(mode: FileMode.read);
    writer = File(kvmPath).openSync(mode: FileMode.writeOnlyAppend);
  } on FileSystemException catch (e) {
    final osCode = e.osError?.errorCode;
    if (osCode == 2) {
      throw StateError(
        'KVM device not found at "$kvmPath". Android integration tests '
        'require hardware virtualization (/dev/kvm). Enable KVM on the host '
        '(e.g. `KERNEL=="kvm", GROUP="kvm", MODE="0666", '
        'OPTIONS+="static_node=kvm"` in `/etc/udev/rules.d/99-kvm4all.rules`).',
      );
    }
    throw StateError(
      'KVM device "$kvmPath" is not readable and writable '
      '(${e.osError?.message ?? e.message}). Ensure the current user has '
      'read/write permission to "$kvmPath" (e.g. `MODE="0666"` in '
      '`/etc/udev/rules.d/99-kvm4all.rules` or membership in the `kvm` group).',
    );
  } finally {
    cleanupQuietly(() => reader?.closeSync());
    cleanupQuietly(() => writer?.closeSync());
  }
}

/// Builds the hermetic environment for the pinned Android `emulator` and `adb`
/// binaries.
///
/// Restricts `PATH` exclusively to the pinned `platform-tools` and `emulator`
/// directories and `LD_LIBRARY_PATH` to the pinned emulator and Debian sysroot
/// library directories so no host SDK, emulator, adb, or non-glibc shared
/// library is ever loaded.
Map<String, String> buildAndroidRuntimeEnvironment({
  required String sdkRoot,
  required String sysrootDir,
  required String scratchDir,
  required String avdHomeDir,
  required int adbServerPort,
  EnvForwarding forwarding = const EnvForwarding(),
}) {
  final libDirs = <String>[
    '$sdkRoot/emulator/lib64',
    '$sdkRoot/emulator/lib64/gles_swiftshader',
    '$sysrootDir/usr/lib/x86_64-linux-gnu',
    '$sysrootDir/lib/x86_64-linux-gnu',
  ];

  final resolved = resolveForwarding(forwarding);

  final result = <String, String>{
    'PATH': '$sdkRoot/platform-tools:$sdkRoot/emulator',
    'LD_LIBRARY_PATH': libDirs.join(':'),
    'HOME': scratchDir,
    'TMPDIR': scratchDir,
    'USER': 'android',
    'LOGNAME': 'android',
    'ANDROID_SDK_ROOT': sdkRoot,
    'ANDROID_HOME': sdkRoot,
    'ANDROID_AVD_HOME': avdHomeDir,
    'ANDROID_EMULATOR_HOME': '$scratchDir/.android',
    'ANDROID_USER_HOME': '$scratchDir/.android',
    'ANDROID_ADB_SERVER_PORT': '$adbServerPort',
    'ADB_VENDOR_KEYS': '$scratchDir/.android',
    'XDG_CONFIG_HOME': '$scratchDir/.config',
    'XDG_CACHE_HOME': '$scratchDir/.cache',
    'XDG_RUNTIME_DIR': '$scratchDir/xdg-runtime',
    'TZ': resolved.timeZone,
  };
  result.addAll(resolved.declared);
  result['TZ'] = resolved.timeZone;
  return result;
}

/// Generates the top-level `<avdName>.ini` file pointing the emulator at
/// [avdDir].
String buildAndroidAvdIniContent({
  required String avdDir,
  String avdName = 'test',
  int apiLevel = 35,
}) {
  return 'avd.ini.encoding=UTF-8\n'
      'path=$avdDir\n'
      'path.rel=avd/$avdName.avd\n'
      'target=android-$apiLevel\n';
}

/// Generates the `config.ini` for a fresh, headless `aosp_atd` `x86_64` AVD.
String buildAndroidAvdConfigContent({
  String avdName = 'test',
  int apiLevel = 35,
}) {
  return 'AvdId=$avdName\n'
      'PlayStore.enabled=false\n'
      'abi.type=x86_64\n'
      'avd.ini.displayname=$avdName\n'
      'avd.ini.encoding=UTF-8\n'
      'disk.dataPartition.size=4096M\n'
      'fastboot.chosenSnapshotFile=\n'
      'fastboot.forceChosenSnapshotBoot=no\n'
      'fastboot.forceColdBoot=yes\n'
      'fastboot.forceFastBoot=no\n'
      'hw.accelerometer=yes\n'
      'hw.arc=false\n'
      'hw.audioInput=no\n'
      'hw.audioOutput=no\n'
      'hw.battery=yes\n'
      'hw.camera.back=none\n'
      'hw.camera.front=none\n'
      'hw.cpu.arch=x86_64\n'
      'hw.cpu.ncore=4\n'
      'hw.dPad=no\n'
      'hw.gps=no\n'
      'hw.gpu.enabled=yes\n'
      'hw.gpu.mode=swiftshader_indirect\n'
      'hw.initialOrientation=Portrait\n'
      'hw.keyboard=yes\n'
      'hw.lcd.density=160\n'
      'hw.lcd.height=800\n'
      'hw.lcd.width=480\n'
      'hw.mainKeys=no\n'
      'hw.ramSize=2048\n'
      'hw.sdCard=no\n'
      'hw.sensors.orientation=yes\n'
      'hw.sensors.proximity=yes\n'
      'hw.trackBall=no\n'
      'image.sysdir.1=system-images/android-$apiLevel/aosp_atd/x86_64/\n'
      'runtime.network.latency=none\n'
      'runtime.network.speed=full\n'
      'showDeviceFrame=no\n'
      'tag.display=AOSP ATD\n'
      'tag.id=aosp_atd\n'
      'vm.heapSize=256\n';
}

/// Builds the command-line flags passed to the hermetic Android `emulator`.
List<String> buildAndroidEmulatorArguments({
  required String avdName,
  required int consolePort,
  required int adbPort,
}) {
  return <String>[
    '-avd',
    avdName,
    '-no-window',
    '-no-audio',
    '-no-boot-anim',
    '-no-snapshot',
    '-no-snapshot-save',
    '-no-snapshot-load',
    '-wipe-data',
    '-gpu',
    'swiftshader_indirect',
    '-accel',
    'on',
    '-ports',
    '$consolePort,$adbPort',
    '-no-metrics',
  ];
}

/// Allocates a free `(consolePort, adbPort)` pair in `adb`'s local transport
/// discovery range (`5554..5680`) and an ephemeral `adbServerPort`.
Future<({int adbServerPort, int consolePort, int adbPort})>
allocateAndroidEmulatorPorts() async {
  final adbServerSocket = await ServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  final adbServerPort = adbServerSocket.port;
  await adbServerSocket.close();

  const minConsolePort = 5554;
  const maxPairs = 64;
  final startOffset = pid % maxPairs;
  for (var i = 0; i < maxPairs; i++) {
    final idx = (startOffset + i) % maxPairs;
    final candidateConsole = minConsolePort + idx * 2;
    final candidateAdb = candidateConsole + 1;
    if (candidateConsole == adbServerPort || candidateAdb == adbServerPort) {
      continue;
    }
    ServerSocket? s1;
    ServerSocket? s2;
    try {
      s1 = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        candidateConsole,
      );
      s2 = await ServerSocket.bind(InternetAddress.loopbackIPv4, candidateAdb);
      await s1.close();
      await s2.close();
      return (
        adbServerPort: adbServerPort,
        consolePort: candidateConsole,
        adbPort: candidateAdb,
      );
    } on SocketException {
      // A half-bound probe pair must not leak sockets into the next attempt.
      await teardownQuietly(() async => await s1?.close());
      await teardownQuietly(() async => await s2?.close());
    }
  }
  throw StateError(
    'Could not find a free (consolePort, adbPort) pair in 5554..5681 for the '
    'Android emulator.',
  );
}

/// Boots a hermetic, pinned headless Android `x86_64` emulator accelerated with
/// KVM, installs the built integration test APK, forwards the harness WebSocket
/// port via `adb reverse`, and launches `FlutterActivity`.
class AndroidPlatformLauncher implements PlatformLauncher {
  AndroidPlatformLauncher({
    required this.apkPath,
    required this.packageName,
    required this.emulatorBinary,
    required this.adbBinary,
    required this.baseTempDir,
    this.kvmPath = '/dev/kvm',
    this.bootTimeout = const Duration(seconds: 120),
  });

  /// APK installed on the emulator for the run.
  final String apkPath;

  /// Application ID the APK is installed and launched under.
  final String packageName;

  /// Pinned emulator binary backing the headless AVD.
  final String emulatorBinary;

  /// Pinned `adb` binary driving the emulator.
  final String adbBinary;

  /// Scratch parent for the AVD home and XDG homes.
  final String baseTempDir;

  /// KVM device passed through to the emulator.
  final String kvmPath;

  /// How long the emulator may take to boot before the run fails.
  final Duration bootTimeout;

  Directory? _scratchDir;
  Process? _emulatorProcess;
  Process? _logcatProcess;
  Timer? _watchdogTimer;
  Map<String, String>? _runtimeEnv;
  bool _disposing = false;
  int? _emulatorExitCode;

  @override
  String get platformName => 'android';

  @override
  String get suiteRuntime => 'vm';

  @override
  String get suiteCompiler => 'kernel';

  /// Creates the scratch tree and a fresh headless AVD for one run.
  ({Directory scratch, Directory avdHomeDir}) _prepareAndroidScratch() {
    final scratch = Directory(
      '$baseTempDir/android_integration_${pid}_${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    _scratchDir = scratch;

    final avdHomeDir = Directory('${scratch.path}/.android/avd')
      ..createSync(recursive: true);
    final avdDir = Directory('${avdHomeDir.path}/test.avd')
      ..createSync(recursive: true);
    Directory('${scratch.path}/.config').createSync(recursive: true);
    Directory('${scratch.path}/.cache').createSync(recursive: true);
    Directory('${scratch.path}/xdg-runtime').createSync(recursive: true);

    File('${avdHomeDir.path}/test.ini').writeAsStringSync(
      buildAndroidAvdIniContent(avdDir: avdDir.path),
    );
    File('${avdDir.path}/config.ini').writeAsStringSync(
      buildAndroidAvdConfigContent(),
    );
    return (scratch: scratch, avdHomeDir: avdHomeDir);
  }

  /// Starts the hermetic `adb` server on the allocated port.
  Future<void> _startAdbServer(
    Map<String, String> runtimeEnv,
    int adbServerPort,
  ) async {
    final startServerResult = await Process.run(
      adbBinary,
      const <String>['start-server'],
      environment: runtimeEnv,
      includeParentEnvironment: false,
    );
    if (startServerResult.exitCode != 0) {
      throw StateError(
        'Failed to start hermetic adb server on port $adbServerPort:\n'
        '${startServerResult.stdout}\n${startServerResult.stderr}',
      );
    }
  }

  /// Launches the emulator, records its logs, and watches for a premature
  /// exit so the boot wait can report it instead of timing out.
  Future<Process> _launchEmulator(
    List<String> emulatorArgs,
    String scratchPath,
    Map<String, String> runtimeEnv,
    List<String> emulatorLogs,
  ) async {
    final emulator = await Process.start(
      emulatorBinary,
      emulatorArgs,
      workingDirectory: scratchPath,
      environment: runtimeEnv,
      includeParentEnvironment: false,
    );
    _emulatorProcess = emulator;

    void recordEmulatorLine(String prefix, String line) {
      if (emulatorLogs.length < 150) {
        emulatorLogs.add('[$prefix] $line');
      }
    }

    emulator.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) => recordEmulatorLine('emu-out', l));
    emulator.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) => recordEmulatorLine('emu-err', l));

    unawaited(
      emulator.exitCode.then((code) {
        _emulatorExitCode = code;
        if (!_disposing) {
          _logcatProcess?.kill(ProcessSignal.sigkill);
        }
      }),
    );
    return emulator;
  }

  /// Waits for `sys.boot_completed`, failing fast when the emulator already
  /// exited instead of sitting out the whole boot timeout.
  Future<void> _waitForEmulatorBoot(
    String serial,
    List<String> emulatorLogs,
    DateTime bootDeadline,
  ) async {
    var booted = false;
    while (DateTime.now().isBefore(bootDeadline)) {
      if (_emulatorExitCode != null) {
        throw StateError(
          'Android emulator exited prematurely with code $_emulatorExitCode '
          'before completing boot:\n${emulatorLogs.join("\n")}',
        );
      }
      final propResult = await _runAdb(
        serial,
        const <String>['shell', 'getprop', 'sys.boot_completed'],
      );
      if (propResult.exitCode == 0 && '${propResult.stdout}'.trim() == '1') {
        booted = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (!booted) {
      throw TimeoutException(
        'Timed out after ${bootTimeout.inSeconds}s waiting for Android '
        'emulator ($serial) to finish booting:\n${emulatorLogs.join("\n")}',
      );
    }
  }

  /// Forwards the harness port into the emulator over `adb reverse`, so the
  /// app can dial `ws://127.0.0.1:<harnessPort>/…` (and the fallback 38427).
  Future<void> _forwardHarnessPorts(String serial, int harnessPort) async {
    for (final remotePort in <int>{harnessPort, 38427}) {
      final rev = await _runAdb(
        serial,
        <String>['reverse', 'tcp:$remotePort', 'tcp:$harnessPort'],
      );
      if (rev.exitCode != 0) {
        throw StateError(
          'adb reverse tcp:$remotePort tcp:$harnessPort failed on $serial:\n'
          '${rev.stdout}\n${rev.stderr}',
        );
      }
    }
  }

  /// Installs the built integration test APK on the booted emulator.
  Future<void> _installApk(String serial) async {
    final installResult = await _runAdb(
      serial,
      <String>['install', '-r', apkPath],
      timeout: const Duration(seconds: 90),
    );
    if (installResult.exitCode != 0) {
      throw StateError(
        'adb install -r "$apkPath" failed on $serial '
        '(exit ${installResult.exitCode}):\n'
        '${installResult.stdout}\n${installResult.stderr}',
      );
    }
  }

  /// Aligns the device timezone with the test's TZ so the app observes it.
  Future<void> _configureDeviceTimezone(String serial) async {
    final deviceTz = Platform.environment['TZ'] ?? 'UTC';
    await _runAdb(serial, <String>[
      'shell',
      'settings',
      'put',
      'global',
      'time_zone',
      deviceTz,
    ]);
    await _runAdb(serial, <String>[
      'shell',
      'setprop',
      'persist.sys.timezone',
      deviceTz,
    ]);
  }

  /// Launches the app's `FlutterActivity` with the harness URL as its
  /// entrypoint args. Returns the harness URL the app dials.
  Future<String> _startFlutterActivity(
    String serial,
    String harnessUrl,
  ) async {
    final startResult = await _runAdb(
      serial,
      <String>[
        'shell',
        'am',
        'start',
        '-W',
        '-n',
        '$packageName/io.flutter.embedding.android.FlutterActivity',
        '--esal',
        'dart_entrypoint_args',
        harnessUrl,
      ],
      timeout: const Duration(seconds: 45),
    );
    final startOutput = '${startResult.stdout}\n${startResult.stderr}';
    if (startResult.exitCode != 0 ||
        startOutput.contains('Error:') ||
        startOutput.contains('Exception')) {
      throw StateError(
        'Failed to start FlutterActivity for $packageName on $serial:\n'
        '$startOutput',
      );
    }
    return harnessUrl;
  }

  /// Tails the app's logcat and arms the crash watchdog. The returned
  /// process stands in for the target: when it dies, the run ends.
  Future<Process> _startLogcat(
    String serial,
    Map<String, String> runtimeEnv,
  ) async {
    final logcat = await Process.start(
      adbBinary,
      <String>[
        '-s',
        serial,
        'logcat',
        '-v',
        'time',
        'flutter:V',
        'DartVM:V',
        'AndroidRuntime:E',
        'ActivityManager:W',
        'DEBUG:V',
        'libc:F',
        '*:S',
      ],
      environment: runtimeEnv,
      includeParentEnvironment: false,
    );
    _logcatProcess = logcat;

    _startWatchdog(serial);
    return logcat;
  }

  @override
  Future<Process> startTarget(HarnessBinding binding) async {
    verifyKvmAvailable(kvmPath);

    if (!File(emulatorBinary).existsSync()) {
      throw StateError(
        'Pinned Android emulator binary not found at "$emulatorBinary".',
      );
    }
    if (!File(adbBinary).existsSync()) {
      throw StateError('Pinned Android adb binary not found at "$adbBinary".');
    }
    if (!File(apkPath).existsSync()) {
      throw StateError('Built Android APK not found at "$apkPath".');
    }

    // emulatorBinary is at <repoRoot>/sdk/emulator/emulator.
    final sdkRoot = File(emulatorBinary).parent.parent.path;
    final repoRoot = Directory(sdkRoot).parent.path;
    final sysrootDir = '$repoRoot/sysroot';

    final prepared = _prepareAndroidScratch();
    final scratch = prepared.scratch;

    final ports = await allocateAndroidEmulatorPorts();
    final declaredEnv = decodeDeclaredEnv(
      Platform.environment['FLUTTER_INTEGRATION_TEST_DECLARED_ENV'],
    );
    final tz = Platform.environment['TZ'];
    final runtimeEnv = buildAndroidRuntimeEnvironment(
      sdkRoot: sdkRoot,
      sysrootDir: sysrootDir,
      scratchDir: scratch.path,
      avdHomeDir: prepared.avdHomeDir.path,
      adbServerPort: ports.adbServerPort,
      forwarding: EnvForwarding(env: declaredEnv, tz: tz),
    );
    _runtimeEnv = runtimeEnv;

    await _startAdbServer(runtimeEnv, ports.adbServerPort);

    final emulatorArgs = buildAndroidEmulatorArguments(
      avdName: 'test',
      consolePort: ports.consolePort,
      adbPort: ports.adbPort,
    );
    final emulatorLogs = <String>[];
    await _launchEmulator(
      emulatorArgs,
      scratch.path,
      runtimeEnv,
      emulatorLogs,
    );

    final serial = 'emulator-${ports.consolePort}';
    final bootDeadline = DateTime.now().add(bootTimeout);
    await _waitForEmulatorBoot(serial, emulatorLogs, bootDeadline);

    await _forwardHarnessPorts(serial, binding.port);
    await _installApk(serial);
    await _configureDeviceTimezone(serial);

    // Clear logcat buffers prior to launching the activity.
    await _runAdb(serial, const <String>['logcat', '-b', 'all', '-c']);

    await _startFlutterActivity(serial, binding.url);
    return _startLogcat(serial, runtimeEnv);
  }

  void _startWatchdog(String serial) {
    var checkInFlight = false;
    var sawRunningPid = false;
    final launchedAt = DateTime.now();

    _watchdogTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_disposing || checkInFlight) return;
      checkInFlight = true;
      try {
        final crashResult = await _runAdb(
          serial,
          const <String>['logcat', '-b', 'crash', '-d'],
          timeout: const Duration(seconds: 5),
        );
        final crashOut = '${crashResult.stdout}'.trim();
        if (crashOut.isNotEmpty &&
            (crashOut.contains(packageName) ||
                crashOut.contains('FATAL EXCEPTION') ||
                crashOut.contains('Build fingerprint:'))) {
          stderr.writeln(
            'flutter_integration_test: Android crash detected for '
            '$packageName:\n$crashOut',
          );
          _logcatProcess?.kill(ProcessSignal.sigkill);
          return;
        }

        final pidResult = await _runAdb(
          serial,
          <String>['shell', 'pidof', packageName],
          timeout: const Duration(seconds: 5),
        );
        final pidOut = '${pidResult.stdout}'.trim();
        if (pidResult.exitCode == 0 && pidOut.isNotEmpty) {
          sawRunningPid = true;
        } else if (sawRunningPid ||
            DateTime.now().difference(launchedAt) >
                const Duration(seconds: 10)) {
          if (!_disposing) {
            _logcatProcess?.kill(ProcessSignal.sigkill);
          }
        }
      } on IOException {
        // Ignore transient adb errors during teardown.
      } on StateError {
        // Ignore races with dispose() clearing the runtime environment.
      } finally {
        checkInFlight = false;
      }
    });
  }

  Future<ProcessResult> _runAdb(
    String serial,
    List<String> args, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final env = _runtimeEnv;
    if (env == null) {
      throw StateError('Android runtime environment not initialized.');
    }
    final proc = await Process.start(
      adbBinary,
      <String>['-s', serial, ...args],
      environment: env,
      includeParentEnvironment: false,
    );
    final stdoutFuture = proc.stdout.transform(utf8.decoder).join();
    final stderrFuture = proc.stderr.transform(utf8.decoder).join();
    final exitCode = await proc.exitCode.timeout(
      timeout,
      onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    return ProcessResult(
      proc.pid,
      exitCode,
      await stdoutFuture,
      await stderrFuture,
    );
  }

  @override
  Future<void> handleHttpRequest(HttpRequest request) async {
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  @override
  Future<void> dispose() async {
    _disposing = true;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;

    final logcat = _logcatProcess;
    _logcatProcess = null;
    if (logcat != null) {
      logcat.kill(ProcessSignal.sigkill);
      await teardownQuietly(
        () => logcat.exitCode.timeout(
          const Duration(seconds: 2),
          onTimeout: () => 0,
        ),
      );
    }

    final emulator = _emulatorProcess;
    _emulatorProcess = null;
    if (emulator != null) {
      emulator.kill(ProcessSignal.sigkill);
      await teardownQuietly(
        () => emulator.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () => 0,
        ),
      );
    }

    final env = _runtimeEnv;
    _runtimeEnv = null;
    if (env != null && File(adbBinary).existsSync()) {
      // Best-effort: a stuck daemon only costs the next run seconds of
      // `adb start-server`; a teardown failure here must never mask the
      // integration result the `finally` block is unwinding.
      await teardownQuietly(() async {
        final killProc = await Process.start(
          adbBinary,
          const <String>['kill-server'],
          environment: env,
          includeParentEnvironment: false,
        );
        await killProc.exitCode.timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            killProc.kill(ProcessSignal.sigkill);
            return 0;
          },
        );
      });
    }

    final dir = _scratchDir;
    _scratchDir = null;
    if (dir != null && dir.existsSync()) {
      cleanupQuietly(() => dir.deleteSync(recursive: true));
    }
  }
}
