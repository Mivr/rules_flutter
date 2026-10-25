/// Android device, over adb, and its logcat parsing.
///
/// [AndroidDevice] installs the APK with `adb install`, tails `adb logcat`
/// as the app's only log source, and discovers the VM service in-band from
/// that stream. [LogcatLine] parses one `-v time` record;
/// [androidLogFilter] drops everything but the app's own lines.
/// [extractPackageInfo] reads the package name and launchable activity out
/// of an APK through `aapt2 dump badging`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'device.dart';
import 'host_tools.dart';
import 'logging.dart';
import 'native_patch_delivery.dart';
import 'temp_dir.dart';
import 'vm_service_client.dart';
import 'vm_service_discovery.dart';

final _logger = Logger('dev_tool.device');

/// Android device (via adb).
class AndroidDevice extends Device {
  final String? deviceId;
  String? _packageName;
  String? _activityName;
  final String abi;
  final String? _explicitAdbPath;
  final String? _explicitAapt2Path;
  final ProcessRunSync _runProcess;
  final ProcessStarter _startProcess;

  /// Starts the `adb` a capture shells to, when a test supplies one.
  ///
  /// Separate from [_startProcess], which is the launch's own logcat: a test
  /// that fakes a launch must not thereby fake every capture too.
  final ProcessStarter? _injectedScreenshotStart;

  /// The host port `adb forward tcp:0` allocated for this launch, if any.
  ///
  /// Held so [stop] can remove exactly the forward this launch created. The
  /// forward is not a process: it is state inside the adb *server*, which
  /// outlives every dev tool run and every device disconnect, so nothing
  /// reclaims it on its own. Clearing all forwards instead would take out
  /// another session's on the same host.
  int? _forwardedHostPort;

  /// Whether the upcoming launch expects the app to host a Dart VM service
  /// (debug/JIT builds). Set by the run command before [launch]; enables the
  /// INTERNET-permission preflight, which release/profile launches skip.
  bool expectsVmService = false;

  /// The logcat a launch in flight has started, until the launch returns it.
  ///
  /// logcat is how the URI arrives *and* the instance's process; killing it on
  /// abandonment ends both the discovery wait and the log source at once. The
  /// app itself runs on the device and is force-stopped by [_releaseApp].
  Process? _launchingLogcat;

  AndroidDevice({
    this.deviceId,
    String? packageName,
    String? activityName,
    this.abi = 'arm64',
    String? adbPath,
    String? aapt2Path,
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
    ProcessStarter? startScreenshotProcess,
  }) : _packageName = packageName,
       _activityName = activityName,
       _explicitAdbPath = adbPath,
       _explicitAapt2Path = aapt2Path,
       _runProcess = runProcess ?? Process.run,
       _startProcess = startProcess ?? Process.start,
       _injectedScreenshotStart = startScreenshotProcess;

  /// The `adb` to run, resolved on first use.
  ///
  /// Lazy so that merely naming an Android serial on a machine with no SDK is
  /// not itself an error — [preflight] is where that gets reported, with the
  /// context that a run is about to need it.
  late final String adbPath = _explicitAdbPath ?? adbTool().require();

  /// The `aapt2` to run, resolved on first use. Only a launch that has to read
  /// the APK's manifest touches it.
  late final String aapt2Path = _explicitAapt2Path ?? aapt2Tool().require();

  @override
  Future<List<HostTool>> requiredHostTools() async => [
    if (_explicitAdbPath == null) adbTool(),
    // Needed only to read the package name and launchable activity out of
    // the APK, which a caller that already named them skips.
    if (_packageName == null && _explicitAapt2Path == null) aapt2Tool(),
  ];

  @override
  NativePatchDelivery? get nativePatchDelivery {
    final packageName = _packageName;
    if (packageName == null) return null;
    return AndroidPatchDelivery(
      packageName: packageName,
      adb: adbPath,
      adbPrefix: _adbArgs(const []),
      run: _runProcess,
    );
  }

  @override
  String get name => 'Android${deviceId != null ? ' ($deviceId)' : ''}';

  @override
  String pickArtifact(List<String> outputs) {
    // android_binary emits `<name>_deploy.jar`, `<name>_unsigned.apk`,
    // and `<name>.apk`. Only the signed `.apk` is installable; the
    // deploy jar comes first in the output list and would trip
    // `adb install` with `filename doesn't end .apk or .apex`.
    for (final f in outputs) {
      if (f.endsWith('.apk') && !f.endsWith('_unsigned.apk')) return f;
    }
    return outputs.first;
  }

  @override
  List<String> get buildArgs => [
    '--platforms=@rules_flutter//flutter/platforms:android_$abi',
  ];

  /// Build the common adb prefix args (includes -s <deviceId> if set).
  List<String> _adbArgs(List<String> args) {
    if (deviceId != null) return ['-s', deviceId!, ...args];
    return args;
  }

  /// What adb said, plus which device this asked it about.
  ///
  /// adb's own errors name neither the serial nor the flag that carried it, and
  /// some of them are *about* the serial — `unknown host service
  /// '<tail>:features'` is what it answers when the `-s` value has a colon in it
  /// and the server splits on that colon. A reader who cannot see the serial the
  /// tool used has nothing to compare against the one they would have typed.
  ///
  /// Omitted entirely when no device was named, because there is then no serial
  /// to doubt: adb chose, and its message says so.
  String _adbFailure(String what, Object? stderr) => deviceId == null
      ? 'adb $what failed: $stderr'
      : 'adb $what failed (adb -s $deviceId): $stderr';

  /// Discover the VM-service URI from logcat.
  ///
  /// A release build serves none, so there is nothing to wait for. logcat is
  /// a helper rather than the app — which runs on the device — so its end is
  /// not an app exit: without a liveness signal the wait ends at the
  /// announcement or the log's end, and only the bound still waits out a
  /// living app.
  Future<VmServiceDiscovery> _discoverAndroidVmService(AppLogStream logs) {
    if (!buildMode.servesVmService) {
      return Future.value((uri: null, gaveUpNote: null));
    }
    return waitForVmServiceUri(
      logs: logs,
      deviceName: name,
      config: discoveryConfig(),
      logger: activeDiscoveryLogger(),
      abandoned: launchAbortSignal,
    );
  }

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) =>
      trackedLaunch(() => _launch(appPath, onLog: onLog));

  @override
  Future<void> abandonLaunch() async {
    // The signal and the logcat release run in `super`: see
    // [Device.abandonLaunch] for why the signal comes first.
    await super.abandonLaunch();
    await _releaseApp();
  }

  /// Undo a launch that did not return: kill the logcat it started.
  ///
  /// The app on the device is force-stopped by the [_releaseApp] the override
  /// runs next: a launch abandoned after `am start` must not leave it running.
  Future<void> releaseLaunch() async {
    final logcat = _launchingLogcat;
    _launchingLogcat = null;
    if (logcat != null) {
      await stopProcess('adb logcat', logcat, teardownBound);
    }
  }

  Future<AppInstance> _launch(String appPath, {AppLogListener? onLog}) async {
    final packageName = _packageName ?? await _readPackageName(appPath);

    // Step 1: Install the APK.
    final installResult = await _runProcess(
      adbPath,
      _adbArgs(['install', '-r', appPath]),
    );
    if (installResult.exitCode != 0) {
      final stderr = '${installResult.stderr}';
      if (stderr.contains('INSTALL_FAILED_INSUFFICIENT_STORAGE')) {
        throw StateError(
          await _insufficientStorageMessage(appPath, packageName, stderr),
        );
      }
      throw StateError(_adbFailure('install', stderr));
    }

    // Step 1a: Debug launches await the VM service, which can never come up
    // without android.permission.INTERNET — fail fast instead.
    if (expectsVmService) {
      await _verifyInternetPermission(packageName, appPath);
    }
    // Installing and verifying took a while: the shutdown may have arrived
    // meanwhile, and neither step observes the abandonment.
    throwIfLaunchAbandoned();

    // Step 2: Start adb logcat — the app's log source as well as where the
    // VM-service announcement appears.
    //
    // Deliberately unfiltered at the adb level (`-v time`, no tag spec) with
    // filtering done in Dart by [androidLogFilter]: an adb-level tag spec such
    // as `flutter:I *:S` silences everything but the `flutter` tag, hiding Java
    // exceptions (`AndroidRuntime`), VM messages (`DartVM`) and native crashes
    // — exactly the output you most need when an app misbehaves. Matches
    // flutter_tools' AdbLogReader, which filters host-side for the same reason.
    final logcat = _launchingLogcat = await _startProcess(
      adbPath,
      _adbArgs(['logcat', '-v', 'time', '-T', '1']),
    );
    // logcat has no stdout/stderr split: severity lives in the line's tag, so
    // [androidLogFilter] decides, and the raw stderr channel (adb's own
    // diagnostics) is not treated as app error output.
    final logs = startProcessLogs(
      logcat,
      onLog,
      stderrIsError: false,
      transform: androidLogFilter,
    );

    // Step 3: Launch the activity.
    final activity = _activityName ?? '.MainActivity';
    // Starting logcat took a while: refuse before `am start` puts an app on
    // the device that nobody will stop.
    throwIfLaunchAbandoned();
    final startResult = await _runProcess(
      adbPath,
      _adbArgs([
        'shell', 'am', 'start',
        // `--ez <key> <bool>` is an intent extra; the embedder reads
        // `start-paused` off the launch intent.
        if (startPaused) ...['--ez', 'start-paused', 'true'],
        '-n', '$packageName/$activity',
      ]),
    );
    if (startResult.exitCode != 0) {
      throw StateError(_adbFailure('am start', startResult.stderr));
    }

    // Step 4: Discover VM service URI from logcat (see
    // [_discoverAndroidVmService] for the wait's shape).
    final discovery = await _discoverAndroidVmService(logs);
    final deviceUri = discovery.uri;

    // Port forwarding — the URI logcat announces is device-local, and a failed
    // forward has no usable second answer. `127.0.0.1:<devicePort>` on the host
    // is not the device's loopback for a handset over USB, and not the
    // emulator's either (that loopback lives inside its own VM), so any
    // fallback would hand on a URI nothing could dial — adb's error arriving
    // later as a connect timeout against whatever the *host* has on that port,
    // blaming the app.
    Uri? vmServiceUri;
    if (deviceUri != null) {
      final devicePort = deviceUri.port;
      final forwardResult = await _runProcess(
        adbPath,
        _adbArgs(['forward', 'tcp:0', 'tcp:$devicePort']),
      );
      if (forwardResult.exitCode != 0) {
        throw StateError(
          'adb forward tcp:0 tcp:$devicePort failed on $name, so the VM '
          'service it announced at $deviceUri cannot be reached from this '
          'host: ${forwardResult.stderr}',
        );
      }
      // `tcp:0` asks adb to allocate the host port and print it. Anything else
      // on stdout means the forward is not the one this code goes on to dial.
      final printed = (forwardResult.stdout as String).trim();
      final hostPort = int.tryParse(printed);
      if (hostPort == null) {
        throw StateError(
          'adb forward tcp:0 tcp:$devicePort reported success on $name but '
          'printed "$printed" where the host port it allocated belongs, so '
          'there is no port to reach the VM service on.',
        );
      }
      _forwardedHostPort = hostPort;
      vmServiceUri = deviceUri.replace(host: '127.0.0.1', port: hostPort);
    }
    // The shutdown may have arrived while discovery ran: refuse the launch
    // rather than hand back an app nobody will stop.
    throwIfLaunchAbandoned();
    _launchingLogcat = null;

    return AppInstance(
      process: logcat,
      vmServiceUri: vmServiceUri,
      vmServiceDiscoveryNote: discovery.gaveUpNote,
      logs: logs,
    );
  }

  /// Read the package name (and launchable activity) out of the APK.
  ///
  /// Fatal when it fails, because the package name is what starts the activity
  /// and what [stop] force-stops: a launch without one installs an APK, runs
  /// nothing, and then waits out VM-service discovery on an app that was never
  /// started, blaming the wrong culprit.
  Future<String> _readPackageName(String appPath) async {
    if (!appPath.endsWith('.apk')) {
      throw StateError(
        'Cannot launch $appPath on $name: it is not an APK, so there is no '
        'manifest to read the package name from.',
      );
    }
    final info = await extractPackageInfo(
      appPath,
      runProcess: _runProcess,
      aapt2Path: aapt2Path,
    );
    _packageName = info.packageName;
    _activityName ??= info.activityName;
    return info.packageName;
  }

  /// What to say when `adb install` ran out of room.
  ///
  /// adb reports `Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE: Failed to
  /// override installation location]` and stops there, naming neither the size
  /// of the thing it could not fit nor the space it had. Both are one adb call
  /// and a `stat` away, and without them the failure reads as a bug in this
  /// tool — the message is the whole fix, because there is nothing here to
  /// retry: the device is genuinely out of room.
  ///
  /// Deliberately **not** an uninstall-and-reinstall. Upstream's
  /// `flutter_tools` does exactly that, and it is wrong twice over: it throws
  /// away the user's app data to work around a full disk, and it does nothing
  /// at all when no earlier copy is installed. Removing an existing copy is
  /// offered as a command the developer can run, not taken behind their back.
  ///
  /// PackageManager's own estimate is left unquantified on purpose: it counts
  /// the staged APK and the uncompressed libraries at once, and there is no
  /// reliable multiplier to state.
  Future<String> _insufficientStorageMessage(
    String apkPath,
    String packageName,
    String adbStderr,
  ) async {
    final apkBytes = await File(apkPath).length();
    final free = await _freeSpaceOnData();
    final installed = await _isInstalled(packageName);
    return 'adb install failed: the device is out of room for this APK.\n'
        '  APK:  ${_formatBytes(apkBytes)} ($apkPath)\n'
        '  Free: $free on /data\n'
        'A debug APK carries the entire Flutter debug engine — libflutter.so '
        'plus the Vulkan validation layer, both stored uncompressed — so it '
        'is hundreds of megabytes, and Android needs room for more than the '
        'file itself while it installs.\n'
        '${installed ? 'A copy of $packageName is already installed; '
                  'removing it frees its share first:\n'
                  '  adb ${deviceId != null ? '-s $deviceId ' : ''}uninstall '
                  '$packageName\n' : '$packageName is not currently installed, so '
                  'there is no earlier copy holding the space.\n'}'
        'On an emulator the durable fix is a bigger data partition: raise '
        'disk.dataPartition.size in the AVD\'s config.ini '
        '(~/.android/avd/<name>.avd/config.ini) and restart it. Measured with '
        'a 640 MB debug APK: a 6 GB partition does not take it, a 16 GB one '
        'does. Note the emulator\'s -partition-size flag does not resize '
        'userdata.\n'
        'adb said: $adbStderr';
  }

  /// Free space on the device's `/data`, as a human-readable string.
  ///
  /// Reported rather than parsed into a number the caller compares: this
  /// exists only to be printed beside the APK size. When `df` cannot be read
  /// its own output is quoted instead of a fabricated figure — an error path
  /// that lies about the device is worse than one that admits it does not
  /// know.
  Future<String> _freeSpaceOnData() async {
    final result = await _runProcess(
      adbPath,
      _adbArgs(['shell', 'df', '/data']),
    );
    if (result.exitCode != 0) {
      return 'unknown (`adb shell df /data` failed: ${result.stderr})';
    }
    final lines = const LineSplitter()
        .convert('${result.stdout}')
        .where((l) => l.trim().isNotEmpty);
    if (lines.isEmpty) return 'unknown (`adb shell df /data` printed nothing)';
    // `Filesystem 1K-blocks Used Available Use% Mounted on` — the available
    // column, in 1K blocks, off the last row df printed.
    final fields = lines.last.trim().split(RegExp(r'\s+'));
    final availableKb = fields.length > 3 ? int.tryParse(fields[3]) : null;
    if (availableKb == null) return 'unknown (df said: ${lines.last.trim()})';
    return _formatBytes(availableKb * 1024);
  }

  /// Whether [packageName] is installed, by asking for the path of its APK.
  ///
  /// `pm path` exits non-zero and prints nothing for a package that is not
  /// there, which is the answer rather than an error.
  Future<bool> _isInstalled(String packageName) async {
    final result = await _runProcess(
      adbPath,
      _adbArgs(['shell', 'pm', 'path', packageName]),
    );
    return result.exitCode == 0 && '${result.stdout}'.contains('package:');
  }

  /// Bytes as the size a person would say out loud — `640.1 MB`, `2.5 GB`.
  ///
  /// Powers of 1024 with SI-style suffixes, which is what `df -h` and `ls -lh`
  /// print, so the number here can be compared with the ones a developer sees
  /// from those tools.
  static String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  /// Fails the launch when the installed [packageName] does not request
  /// `android.permission.INTERNET`.
  ///
  /// Android enforces the INTERNET permission at the kernel level (AID_INET
  /// group membership): a process without it cannot create any socket —
  /// including the 127.0.0.1 server socket the Dart VM service must bind —
  /// so a debug launch would only ever time out waiting for the service.
  /// Queries the installed package (not the APK on disk) so the check
  /// reflects exactly what the device enforces.
  Future<void> _verifyInternetPermission(
    String packageName,
    String apkPath,
  ) async {
    final result = await _runProcess(
      adbPath,
      _adbArgs(['shell', 'dumpsys', 'package', packageName]),
    );
    if (result.exitCode != 0) {
      throw StateError(
        'Could not verify INTERNET permission for $packageName: '
        '`adb shell dumpsys package` failed (exit ${result.exitCode}): '
        '${result.stderr}',
      );
    }
    final output = result.stdout as String;
    if (!output.contains('Package [$packageName]')) {
      throw StateError(
        'Could not verify INTERNET permission for $packageName: '
        '`adb shell dumpsys package` returned no package record:\n'
        '${output.trim()}',
      );
    }
    if (!_requestsInternetPermission(output)) {
      throw StateError(
        '$packageName ($apkPath) does not request '
        'android.permission.INTERNET, so the Dart VM service cannot bind '
        'its socket and this debug launch would hang.\n'
        'Debug APKs built with flutter_android_app get INTERNET from the '
        'debug variant manifest '
        '(android/app/src/debug/AndroidManifest.xml, merged into -c dbg '
        'builds): make sure that file exists (flutter create emits it) '
        'and was not disabled via debug_manifest = False. For a custom '
        'manifest, add <uses-permission '
        'android:name="android.permission.INTERNET"/> or pass a '
        'debug_manifest. Alternatively pass --allow-no-vm-service to '
        'launch without debugging.',
      );
    }
  }

  /// True when the dumpsys package record lists
  /// `android.permission.INTERNET` under `requested permissions:`.
  /// A package that requests no permissions has no such section at all.
  static bool _requestsInternetPermission(String dumpsysOutput) {
    final lines = const LineSplitter().convert(dumpsysOutput);
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim() != 'requested permissions:') continue;
      final headerIndent = lines[i].length - lines[i].trimLeft().length;
      for (var j = i + 1; j < lines.length; j++) {
        final line = lines[j];
        if (line.trim().isEmpty) break;
        final indent = line.length - line.trimLeft().length;
        if (indent <= headerIndent) break;
        final permission = line.trim().split(RegExp(r'[:\s]')).first;
        if (permission == 'android.permission.INTERNET') return true;
      }
    }
    return false;
  }

  /// Force-stops the app, removes this launch's `adb forward`, and kills
  /// logcat.
  ///
  /// The forward has to be removed by hand because it is not a process: `adb
  /// forward` writes a rule into the adb server, and the server survives the
  /// app exiting, the device unplugging and the dev tool quitting. A launch
  /// that skips the removal leaves a host port bound to a device port for as
  /// long as the adb server runs.
  ///
  /// Only this launch's forward, named by the host port adb allocated —
  /// `adb forward --remove-all` would take out a concurrent session's on the
  /// same host, and there is no way to tell from a rule which run owns it.
  ///
  /// A run that never reaches here still leaks one: nothing in the adb server
  /// is tied to the dev tool's lifetime, so a killed or crashed run leaves its
  /// rule behind. That is accepted rather than reconciled at launch, because
  /// there is nothing to reconcile *against* — `tcp:0` has adb allocate a
  /// fresh host port every time, and the device port is whichever ephemeral
  /// port the app's VM service happened to bind, so no two launches share a
  /// pair to match on. `adb forward --list`, or restarting the adb server,
  /// clears what a killed run left.
  @override
  Future<void> stop(AppInstance instance) async {
    await _releaseApp();
    await stopProcess('Android logcat', instance.process, teardownBound);
    await instance.logs.close();
  }

  /// The launch's logcat ends with this process; the app and the forward,
  /// which live on the device and in the adb server, do not.
  ///
  /// [abandonLaunch] runs [releaseLaunch] first (killing the logcat a launch
  /// in flight started) and [_releaseApp] next (force-stopping the app and
  /// removing the forward): one override for both, in launch order.

  /// Stop the app and remove the forward this launch created.
  Future<void> _releaseApp() async {
    if (_packageName != null) {
      await _runProcess(
        adbPath,
        _adbArgs(['shell', 'am', 'force-stop', _packageName!]),
      );
    }
    final hostPort = _forwardedHostPort;
    if (hostPort != null) {
      final removal = await _runProcess(
        adbPath,
        _adbArgs(['forward', '--remove', 'tcp:$hostPort']),
      );
      _forwardedHostPort = null;
      if (removal.exitCode != 0) {
        _logger.warning({
          'message': 'adb_forward_remove_failed',
          'text':
              'Could not remove this run\'s adb forward on $name: '
              'host port $hostPort stays bound to the device until the adb '
              'server restarts. adb said: ${removal.stderr}',
          'device': name,
          'hostPort': hostPort,
          'error': '${removal.stderr}',
        });
      }
    }
  }

  /// How long a whole capture gets to answer — all three `adb` calls, not
  /// each.
  ///
  /// The capture runs inside an HTTP handler, so an `adb` that never returns
  /// is an endpoint that never answers: the request stays open and the caller
  /// learns nothing at all, which is strictly worse than any error. One
  /// deadline across the sequence rather than one per call, because what has
  /// to be bounded is what the caller waits for; three separate bounds would
  /// let the endpoint hold a request for three times the number written here.
  ///
  /// Thirty seconds is not a slow device, it is a wedge — with room for an
  /// `adb` that has to start its server first.
  ///
  /// Settable so a test can drive the expiry in milliseconds.
  Duration screenshotBound = const Duration(seconds: 30);

  /// Whether this device is a local emulator rather than a physical one.
  ///
  /// `emulator-5554` and friends are the serials `adb` gives an emulator whose
  /// console it can reach on the loopback — which is exactly the set that can
  /// be captured through that console, and exactly the set whose `screencap`
  /// cannot see a Flutter surface. A device reached as `host:port` or by a
  /// hardware serial is not one of them.
  bool get _isEmulator => deviceId?.startsWith('emulator-') ?? false;

  /// Captures the device's screen.
  ///
  /// Two mechanisms, chosen by what the device *is* rather than tried in turn:
  /// a physical device is captured with `adb screencap`, an emulator through
  /// its own console. Neither is a fallback for the other, because on an
  /// emulator `screencap` does not fail — it succeeds and returns a fully
  /// transparent PNG.
  ///
  /// How much of the screen goes blank varies with the emulator's GPU mode and
  /// is deliberately not relied on. What holds across all of them is that
  /// `screencap` can report success and return nothing, and that the console
  /// capture works in every GPU mode — so the choice is made by device kind,
  /// never by inspecting the pixels that came back.
  ///
  /// **Rotation.** The console captures the emulator's window, so it is
  /// faithful to what a person looking at that window sees. Rotate with
  /// `adb -s <serial> emu rotate` (or the emulator's own controls), which
  /// turns the window and the guest display together and yields an upright
  /// landscape capture. `settings put system user_rotation` turns only the
  /// guest: the window stays portrait with the UI lying on its side, and a
  /// capture that showed anything else would be misreporting the screen.
  ///
  /// Bounded by [screenshotBound]: see there for why an unbounded capture is
  /// the one failure this path must not have.
  @override
  Future<void> screenshot(
    AppInstance instance,
    String outputPath, {
    VmServiceClient? vmClient,
    String? window,
  }) async {
    if (vmClient != null) {
      return vmClient.screenshot(outputPath);
    }
    if (_isEmulator) return _consoleScreenshot(outputPath);
    const remotePath = '/sdcard/flutter_screenshot.png';
    final deadline = DateTime.now().add(screenshotBound);
    Future<ProcessResult> step(List<String> args, String what) =>
        runProcessBounded(
          _startScreenshotProcess,
          adbPath,
          _adbArgs(args),
          environment: const {},
          bound: deadline.difference(DateTime.now()),
          what: what,
        );

    final capResult = await step([
      'shell',
      'screencap',
      '-p',
      remotePath,
    ], 'adb screencap');
    if (capResult.exitCode != 0) {
      throw StateError(_adbFailure('screencap', capResult.stderr));
    }
    final pullResult = await step(['pull', remotePath, outputPath], 'adb pull');
    if (pullResult.exitCode != 0) {
      throw StateError(_adbFailure('pull', pullResult.stderr));
    }
    await step(['shell', 'rm', remotePath], 'adb rm of the captured file');
  }

  /// Captures an emulator's screen through its console.
  ///
  /// `adb emu screenrecord screenshot <dir>` tells the emulator process to
  /// write a PNG of its own framebuffer into [dir], naming the file itself
  /// (`Screenshot_<n>.png`). That host-side capture is the one that sees a
  /// Flutter surface — see [screenshot].
  ///
  /// **The file on disk is the only evidence the capture worked.** `adb emu`
  /// answers `OK` and exits 0 even for a directory that does not exist, so
  /// neither the exit code nor the console's own reply distinguishes a capture
  /// from a no-op. A directory created fresh for
  /// this one call, holding exactly one PNG afterwards, does: it cannot be
  /// satisfied by a leftover from an earlier capture, and it does not depend
  /// on the emulator's choice of filename.
  Future<void> _consoleScreenshot(String outputPath) =>
      withTempDir('flutter_emu_shot_', (dir) async {
        final result = await runProcessBounded(
          _startScreenshotProcess,
          adbPath,
          _adbArgs(['emu', 'screenrecord', 'screenshot', dir.path]),
          environment: const {},
          bound: screenshotBound,
          what: 'adb emu screenrecord screenshot',
        );
        final pngs = dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.toLowerCase().endsWith('.png'))
            .toList();
        if (pngs.isEmpty) {
          throw StateError(
            'The emulator console wrote no PNG for $name. It was asked to '
            'capture into ${dir.path} and answered '
            '"${'${result.stdout}'.trim()}" (exit ${result.exitCode}) — but '
            '`adb emu` reports OK even when it writes nothing, so that reply '
            'is not evidence of a capture.\n'
            'Check that this emulator is a local one whose console adb can '
            'reach: the console capture is what sees a Flutter surface, which '
            '`adb screencap` on an emulator cannot.',
          );
        }
        if (pngs.length > 1) {
          throw StateError(
            'The emulator console wrote ${pngs.length} PNGs into ${dir.path} '
            'for $name and there is no way to tell which is this capture: '
            '${pngs.map((f) => p.basename(f.path)).join(', ')}.',
          );
        }
        await pngs.single.copy(outputPath);
      });

  /// Starts the `adb` a capture shells to.
  ///
  /// [Process.start] with an empty [environment] still inherits the parent's,
  /// which is what `adb` needs — there is nothing extra to add, unlike the
  /// bundled helpers that have to be told where their runfiles are.
  Future<Process> _startScreenshotProcess(
    String exe,
    List<String> args,
    Map<String, String> environment,
  ) => _injectedScreenshotStart != null
      ? _injectedScreenshotStart(exe, args)
      : Process.start(exe, args, environment: environment);
}

/// Extract package name and launchable activity from an APK via aapt2.
///
/// [aapt2Path] names the binary to run; when omitted it is resolved through
/// [aapt2Tool], which throws a [MissingHostToolException] rather than handing
/// `Process.run` a bare `'aapt2'` and letting a misconfigured SDK surface as a
/// failure to launch.
Future<({String packageName, String? activityName})> extractPackageInfo(
  String apkPath, {
  ProcessRunSync? runProcess,
  String? aapt2Path,
}) async {
  final run = runProcess ?? Process.run;
  final aapt2 = aapt2Path ?? aapt2Tool().require();
  final result = await run(aapt2, ['dump', 'badging', apkPath]);
  if (result.exitCode != 0) {
    throw StateError(
      '`$aapt2 dump badging $apkPath` failed '
      '(exit ${result.exitCode}): ${result.stderr}',
    );
  }
  final output = result.stdout as String;
  final pkgMatch = RegExp(r"package: name='([^']+)'").firstMatch(output);
  if (pkgMatch == null) {
    throw StateError('Could not extract package name from APK');
  }
  final actMatch = RegExp(
    r"launchable-activity: name='([^']+)'",
  ).firstMatch(output);
  return (
    packageName: pkgMatch.group(1)!,
    activityName: actMatch?.group(1),
  );
}

/// One parsed `adb logcat -v time` record.
///
/// The `-v time` format is
/// `MM-DD HH:MM:SS.mmm L/Tag( pid): message`, where the pid is space-padded to
/// a fixed width and the tag may itself contain dots (`System.err`).
class LogcatLine {
  /// Priority letter: V, D, I, W, E or F.
  final String level;
  final String tag;
  final String message;

  /// The record without its timestamp — what gets shown.
  final String display;

  const LogcatLine({
    required this.level,
    required this.tag,
    required this.message,
    required this.display,
  });
}

const _logcatTimestamp = r'^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\s+';
final _logcatTimestampPrefix = RegExp(_logcatTimestamp);
final _logcatTimeFormat = RegExp(
  '$_logcatTimestamp'
  r'([VDIWEF])/(.*?)\(\s*\d+\):\s?(.*)$',
);

/// Parse a `-v time` logcat record, or null if the line isn't one (banners,
/// continuation lines, partial reads).
///
/// Parsing once and matching on the parsed tag is deliberate: flutter_tools'
/// equivalent allowlist is a set of regexes written against a tag-only format
/// even though it requests `-v time`, so several of them — `AndroidRuntime`,
/// `System.err`, fatal `F/` — never match a real padded-pid line. Copying them
/// verbatim would silently drop exactly the crash output this is here to
/// surface.
LogcatLine? parseLogcatLine(String rawLine) {
  final match = _logcatTimeFormat.firstMatch(rawLine);
  if (match == null) return null;
  final level = match.group(1)!;
  final tag = match.group(2)!.trim();
  final message = match.group(3)!;
  return LogcatLine(
    level: level,
    tag: tag,
    message: message,
    display: rawLine.replaceFirst(_logcatTimestampPrefix, ''),
  );
}

/// Tags worth showing from an Android device.
///
/// `adb logcat` carries the whole device's logging, almost none of which
/// concerns the app under development, so this is an allowlist. The set is
/// flutter_tools' (`AdbLogReader._allowedTags`):
///
///   * `flutter*` — Dart `print`/`debugPrint` output.
///   * `DartVM*` — VM messages, including the VM-service announcement.
///   * `AndroidRuntime` — uncaught Java exceptions, i.e. crashes.
///   * `System.err` — Java stderr.
///   * `ActivityManager` — but only when it mentions the app.
///   * any tag at all when the record is fatal (`F`).
///
/// Not ported: flutter's tombstone state machine and repeated-line collapsing.
/// Those polish a crash report; the allowlist is what makes crashes *visible*.
bool _isAndroidTagOfInterest(LogcatLine line) {
  final tag = line.tag.toLowerCase();
  if (line.level == 'F') return true;
  if (tag.startsWith('flutter')) return true;
  if (tag.startsWith('dartvm') && (line.level == 'I' || line.level == 'E')) {
    return true;
  }
  if (!const {'W', 'E', 'F'}.contains(line.level)) return false;
  if (tag == 'androidruntime' || tag == 'system.err') return true;
  if (tag == 'activitymanager') {
    return RegExp(r'\b(flutter|domokit|sky)\b').hasMatch(line.message);
  }
  return false;
}

/// Messages that pass the tag allowlist but are never actionable.
///
/// From flutter_tools' `AdbLogReader._filteredMessages`.
final _androidFilteredMessages = <RegExp>[
  RegExp(r'^Failed to find sync for id=\d+$'),
  RegExp(r'^updateAcquireFence: Did not find frame\.$'),
  RegExp(r'ViewPostIme pointer'),
  RegExp(r'mali\.instrumentation\.graph\.work'),
];

/// Decide whether a raw `adb logcat -v time` line is worth showing, returning
/// it with the timestamp stripped, or null to drop it.
///
/// Exposed for testing.
String? androidLogFilter(String rawLine) {
  final line = parseLogcatLine(rawLine);
  // Banners ("--------- beginning of main") and anything else that isn't a
  // record.
  if (line == null) return null;
  if (!_isAndroidTagOfInterest(line)) return null;
  if (_androidFilteredMessages.any((re) => re.hasMatch(line.message))) {
    return null;
  }
  return line.display;
}
