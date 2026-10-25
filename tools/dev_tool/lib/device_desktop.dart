/// Desktop devices: macOS, Linux and Windows.
///
/// The three desktop launches differ only in how the app is started and how a
/// screenshot is captured; VM-service discovery, logging and teardown are the
/// [Device] base's. [desktopLaunchEnvironment] builds the engine-switch
/// environment every desktop starter launches with, and [detectDevice] picks
/// the device matching the host.
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'device.dart';
import 'logging.dart';
import 'native_patch_delivery.dart';
import 'runfiles_helper.dart';
import 'temp_dir.dart';
import 'vm_service_client.dart';

final _logger = Logger('dev_tool.device');

/// macOS desktop device.
class MacOSDevice extends Device {
  final ProcessRunSync _runProcess;
  final ProcessStarter? _injectedStart;

  /// Starts the bundled screenshot helper, when a test supplies one.
  ///
  /// Separate from [_injectedStart], which carries the app's own launch
  /// environment: a test that fakes a launch must not thereby fake every
  /// capture too.
  final ProcessStarter? _injectedScreenshotStart;

  /// Starts `osascript` for [_bringToFront], when a test supplies one.
  final ProcessStarter? _injectedActivationStart;

  MacOSDevice({
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
    ProcessStarter? startScreenshotProcess,
    ProcessStarter? startActivationProcess,
  }) : _runProcess = runProcess ?? Process.run,
       _injectedStart = startProcess,
       _injectedScreenshotStart = startScreenshotProcess,
       _injectedActivationStart = startActivationProcess;

  /// How long activation through System Events gets before it is killed.
  ///
  /// With the Automation permission undecided the AppleEvent does not fail, it
  /// blocks, so without a bound every launch on a machine that has not granted
  /// it would hang there. Settable so a test can drive the expiry.
  Duration activationBound = const Duration(seconds: 10);

  Future<Process> _startProcess(String exe, List<String> args) =>
      (_injectedStart ?? _defaultStart)(exe, args);

  /// Start the app with the engine switches this launch asked for.
  ///
  /// An instance method because the switches depend on [startPaused], which is
  /// set on the device after it is constructed. The
  /// injected [_startProcess] bypasses this entirely, which is why the
  /// environment it builds lives in [desktopLaunchEnvironment] where a test
  /// can reach it.
  Future<Process> _defaultStart(String exe, List<String> args) => Process.start(
    exe,
    args,
    environment: desktopLaunchEnvironment(startPaused: startPaused),
  );

  @override
  NativePatchDelivery? get nativePatchDelivery => const MacOSPatchDelivery();

  @override
  String get name => 'macOS';

  final _scratch = LaunchScratch();

  /// The app a launch in flight has started, until the launch returns it.
  Process? _launching;

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) =>
      trackedLaunch(() => _launch(appPath, onLog: onLog));

  /// Undo a launch that did not return: the app it started, which runs out of
  /// the extracted copy, and then that copy.
  Future<void> releaseLaunch() async {
    final process = _launching;
    _launching = null;
    if (process != null) {
      await stopProcess('macOS app', process, teardownBound);
    }
    await _scratch.release();
  }

  Future<AppInstance> _launch(String appPath, {AppLogListener? onLog}) async {
    // Extract .app from .zip if needed (Bazel macOS bundles are zipped).
    String resolvedPath = appPath;
    if (appPath.endsWith('.zip')) {
      final unpacked = await _extractAppFromZip(appPath);
      resolvedPath = unpacked.appPath;
      _scratch.hold(unpacked.dir);
    }

    // For .app bundles, find the executable inside.
    String executable;
    if (resolvedPath.endsWith('.app')) {
      // The executable is at Contents/MacOS/<name>.
      final bundleName = resolvedPath.split('/').last.replaceAll('.app', '');
      executable = '$resolvedPath/Contents/MacOS/$bundleName';
    } else {
      executable = resolvedPath;
    }

    final process = _launching = await _startProcess(
      executable,
      [],
    );

    final logs = startProcessLogs(process, onLog);
    final discovery = await discoverDesktopVmService(logs, process);
    if (resolvedPath.endsWith('.app')) {
      await _bringToFront(resolvedPath, process.pid);
    }
    // The shutdown may have arrived while discovery or activation ran: refuse
    // the launch rather than hand back an app nobody will stop.
    throwIfLaunchAbandoned();

    _launching = null;
    return AppInstance(
      process: process,
      vmServiceUri: discovery.uri,
      vmServiceDiscoveryNote: discovery.gaveUpNote,
      logs: logs,
      // The app runs out of this directory, so it goes only once the process
      // has exited — which `stop` awaits before disposing it.
      scratchDirs: _scratch.handOver(),
    );
  }

  /// Bring the launched app's window to the front.
  ///
  /// The app is started as a bare executable, not through LaunchServices, and
  /// a process started that way is not made frontmost. On a Mac with Stage
  /// Manager its window then sits in the strip as a thumbnail, about 113x138 pt
  /// and not on screen at the size the app asked for, and a screenshot of it is
  /// of that — or black, once another app has come forward.
  ///
  /// Two ways, in this order, because neither works everywhere:
  ///
  /// 1. `open` on the running bundle activates that same process, starts no
  ///    second one and needs no permission. It needs LaunchServices to know
  ///    the process, which it does in a desktop session and does not over ssh:
  ///    there it fails with error -600 (procNotFound).
  /// 2. System Events sets the process frontmost by its pid, which does not
  ///    depend on LaunchServices. It needs the Automation permission, and with
  ///    that undecided it blocks, so it is the second resort and is bounded
  ///    ([activationBound]).
  ///
  /// A failure of both is reported and the launch carries on: the app is
  /// running and drivable, only its window may not be on screen at full size.
  /// Everything each step said goes on the record as fields, because a JSON log
  /// keeps fields and drops the prose.
  Future<void> _bringToFront(String bundlePath, int pid) async {
    final failure = <String, Object?>{'bundle': bundlePath, 'pid': pid};
    try {
      final opened = await _runProcess('open', [bundlePath]);
      if (opened.exitCode == 0) return;
      failure['openExitCode'] = opened.exitCode;
      failure['openStderr'] = '${opened.stderr}'.trim();
    } on ProcessException catch (e) {
      failure['openError'] = '$e';
    }
    try {
      final result = await runProcessBounded(
        (exe, args, _) =>
            (_injectedActivationStart ?? Process.start)(exe, args),
        'osascript',
        [
          '-e',
          'tell application "System Events" to set frontmost of '
              '(first process whose unix id is $pid) to true',
        ],
        environment: const {},
        bound: activationBound,
        what: 'Activating the app through System Events',
      );
      if (result.exitCode == 0) return;
      failure['systemEventsExitCode'] = result.exitCode;
      failure['systemEventsStderr'] = '${result.stderr}'.trim();
    } on ProcessException catch (e) {
      failure['systemEventsError'] = '$e';
    } on StateError catch (e) {
      failure['systemEventsError'] = e.message;
    }
    _logger.warning({
      'message': 'macos_app_not_activated',
      ...failure,
      'text':
          'Could not bring the app to the front: $failure. It is running, but '
          'its window may not be on screen at full size. Activation through '
          'System Events needs the Automation permission for the terminal '
          'that runs this tool.',
    });
  }

  @override
  Future<void> stop(AppInstance instance) async {
    await stopProcess('macOS app', instance.process, teardownBound);
    await instance.logs.close();
    await instance.disposeScratchDirs();
  }

  /// How long the bundled ScreenCaptureKit helper gets to answer.
  ///
  /// The capture runs inside an HTTP handler, so a helper that never returns
  /// is an endpoint that never answers — the request stays open and the caller
  /// learns nothing at all, which is strictly worse than any error. Ten seconds
  /// is a wedge, not a slow machine.
  ///
  /// ScreenCaptureKit is a real candidate for wedging: it is TCC-gated, and an
  /// *undecided* Screen Recording permission blocks rather than refuses.
  ///
  /// Settable so a test can drive the expiry in milliseconds.
  Duration screenshotBound = const Duration(seconds: 10);

  /// Captures the launched app's windows via the bundled Swift helper.
  ///
  /// With [vmClient] set, uses `_flutter.screenshot` (Flutter view only).
  /// Otherwise invokes `tools/macos_screenshot:screenshot`, which uses
  /// ScreenCaptureKit's `SCShareableContent` to enumerate on-screen windows
  /// owned by the app's PID and either composites all of them or — when
  /// [window] is provided — captures only the window whose `SCWindow.title`
  /// matches exactly. The helper requires Screen Recording permission for
  /// the terminal that launched the dev tool.
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
    final resolved = resolveRunfileWithManifest(
      'rules_flutter/tools/macos_screenshot/screenshot',
    );
    if (resolved == null) {
      throw StateError(
        'Could not find bundled macOS screenshot tool. '
        'Build first: bazel build //tools/dev_tool:flutter_bazel',
      );
    }
    final result = await runProcessBounded(
      _startScreenshotProcess,
      resolved.path,
      [
        '--pid',
        '${instance.process.pid}',
        '--output',
        outputPath,
        if (window != null) ...['--title', window],
      ],
      environment: {
        ...Platform.environment,
        if (resolved.manifestPath != null)
          'RUNFILES_MANIFEST_FILE': resolved.manifestPath!,
      },
      bound: screenshotBound,
      what: 'The bundled macOS screenshot helper',
    );
    if (result.exitCode != 0) {
      throw StateError('macOS screenshot failed: ${result.stderr}');
    }
  }

  Future<Process> _startScreenshotProcess(
    String exe,
    List<String> args,
    Map<String, String> environment,
  ) => _injectedScreenshotStart != null
      ? _injectedScreenshotStart(exe, args)
      : Process.start(exe, args, environment: environment);

  /// Extract .app bundle from a .zip archive.
  ///
  /// Returns the directory as well as the bundle: the caller runs the app out
  /// of it, so it is the caller — not this function — that knows when it can go.
  Future<({String appPath, Directory dir})> _extractAppFromZip(
    String zipPath,
  ) async {
    final tempDir = await createTempDir('flutter_macos_');
    try {
      final result = await _runProcess('unzip', [
        '-oq',
        zipPath,
        '-d',
        tempDir.path,
      ]);
      if (result.exitCode != 0) {
        throw StateError('Failed to extract zip: ${result.stderr}');
      }
      // Find the .app bundle inside.
      final apps = tempDir
          .listSync()
          .where((e) => e.path.endsWith('.app'))
          .toList();
      if (apps.isEmpty) {
        throw StateError('No .app bundle found in zip');
      }
      return (appPath: apps.first.path, dir: tempDir);
    } catch (_) {
      // Nothing usable came out of the archive; the half-unpacked copy is only
      // going to sit there.
      await deleteTempDir(tempDir);
      rethrow;
    }
  }
}

/// Linux desktop device.
class LinuxDevice extends Device {
  final ProcessRunSync _runProcess;
  final ProcessStarter? _injectedStart;

  LinuxDevice({
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
  }) : _runProcess = runProcess ?? Process.run,
       _injectedStart = startProcess;

  Future<Process> _startProcess(String exe, List<String> args) =>
      (_injectedStart ?? _defaultStart)(exe, args);

  /// Start the app with the engine switches this launch asked for.
  ///
  /// An instance method because the switches depend on [startPaused], which is
  /// set on the device after it is constructed. The
  /// injected [_startProcess] bypasses this entirely, which is why the
  /// environment it builds lives in [desktopLaunchEnvironment] where a test
  /// can reach it.
  Future<Process> _defaultStart(String exe, List<String> args) => Process.start(
    exe,
    args,
    environment: desktopLaunchEnvironment(startPaused: startPaused),
  );

  @override
  String get name => 'Linux';

  @override
  List<String> get buildArgs => Platform.isLinux
      ? const []
      : const ['--platforms=@rules_flutter//flutter/platforms:linux_x64'];

  /// The app a launch in flight has started, until the launch returns it.
  Process? _launching;

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) =>
      trackedLaunch(() => _launch(appPath, onLog: onLog));

  /// Undo a launch that did not return: kill the app it started.
  Future<void> releaseLaunch() async {
    final process = _launching;
    _launching = null;
    if (process != null) {
      await stopProcess('Linux app', process, teardownBound);
    }
  }

  Future<AppInstance> _launch(String appPath, {AppLogListener? onLog}) async {
    // Bundle directories contain the executable at <dir>/<name>.
    String executable = appPath;
    if (FileSystemEntity.isDirectorySync(appPath)) {
      final dirName = p.basename(appPath);
      executable = p.join(appPath, dirName);
    }

    final process = _launching = await _startProcess(executable, []);
    final logs = startProcessLogs(process, onLog);
    final discovery = await discoverDesktopVmService(logs, process);
    // The shutdown may have arrived while discovery ran: refuse the launch
    // rather than hand back an app nobody will stop.
    throwIfLaunchAbandoned();
    _launching = null;
    return AppInstance(
      process: process,
      vmServiceUri: discovery.uri,
      vmServiceDiscoveryNote: discovery.gaveUpNote,
      logs: logs,
    );
  }

  @override
  Future<void> stop(AppInstance instance) async {
    await stopProcess('Linux app', instance.process, teardownBound);
    await instance.logs.close();
  }

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
    final result = await _runProcess('scrot', [outputPath]);
    if (result.exitCode != 0) {
      throw StateError('scrot failed: ${result.stderr}');
    }
  }
}

/// Windows desktop device.
class WindowsDevice extends Device {
  final ProcessStarter? _injectedStart;
  final Directory Function() _makeStagingDir;
  Directory? _staged;

  /// Starts the bundled screenshot helper, when a test supplies one.
  ///
  /// Separate from [_injectedStart], which carries the app's own launch
  /// environment: a test that fakes a launch must not thereby fake every
  /// capture too.
  final ProcessStarter? _injectedScreenshotStart;

  WindowsDevice({
    ProcessStarter? startProcess,
    ProcessStarter? startScreenshotProcess,
    Directory Function()? makeStagingDir,
  }) : _injectedStart = startProcess,
       _injectedScreenshotStart = startScreenshotProcess,
       _makeStagingDir = makeStagingDir ?? _defaultStagingDir;

  Future<Process> _startProcess(String exe, List<String> args) =>
      (_injectedStart ?? _defaultStart)(exe, args);

  static Directory _defaultStagingDir() =>
      Directory.systemTemp.createTempSync('flutter_bazel_win_app');

  /// Start the app with the engine switches this launch asked for.
  ///
  /// An instance method because the switches depend on [startPaused], which is
  /// set on the device after it is constructed. The
  /// injected [_startProcess] bypasses this entirely, which is why the
  /// environment it builds lives in [desktopLaunchEnvironment] where a test
  /// can reach it.
  Future<Process> _defaultStart(String exe, List<String> args) => Process.start(
    exe,
    args,
    environment: desktopLaunchEnvironment(startPaused: startPaused),
  );

  @override
  bool get usesWindowsPaths => true;

  @override
  String get name => 'Windows';

  @override
  List<String> get buildArgs => Platform.isWindows
      ? const []
      : const ['--platforms=@rules_flutter//flutter/platforms:windows_x64'];

  /// The app a launch in flight has started, until the launch returns it.
  Process? _launching;

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) =>
      trackedLaunch(() => _launch(appPath, onLog: onLog));

  /// Undo a launch that did not return: kill the staged app it started.
  Future<void> releaseLaunch() async {
    final process = _launching;
    _launching = null;
    if (process != null) {
      await stopProcess('Windows app', process, teardownBound);
    }
    _clearStaging();
  }

  Future<AppInstance> _launch(String appPath, {AppLogListener? onLog}) async {
    // Run from a copy, never from `bazel-out` itself.
    //
    // Windows holds an exclusive lock on a running executable image, so while
    // the app is up, bazel cannot replace `bin/app/app.exe` — and the bundling
    // action does exactly that on any rebuild, which `app.restart` performs
    // before it swaps the kernel in. macOS and Linux let a running image be
    // unlinked and replaced, so only Windows needs the copy.
    final launchPath = _stage(appPath);

    // Bundle directories contain the executable at <dir>/<name>.exe.
    String executable = launchPath;
    if (FileSystemEntity.isDirectorySync(launchPath)) {
      final dirName = p.basename(launchPath);
      executable = p.join(launchPath, '$dirName.exe');
    }

    final process = _launching = await _startProcess(executable, []);
    final logs = startProcessLogs(process, onLog);
    final discovery = await discoverDesktopVmService(logs, process);
    // The shutdown may have arrived while discovery ran: refuse the launch
    // rather than hand back an app nobody will stop.
    throwIfLaunchAbandoned();
    _launching = null;
    return AppInstance(
      process: process,
      vmServiceUri: discovery.uri,
      vmServiceDiscoveryNote: discovery.gaveUpNote,
      logs: logs,
    );
  }

  /// Copies the built bundle out of `bazel-out` and returns the copy's path.
  ///
  /// A bundle is a directory whose layout the runner depends on — it resolves
  /// `data/flutter_assets` relative to its own executable — so the whole tree
  /// is copied, not just the `.exe`. Each launch gets a fresh directory and
  /// the previous one is removed, so a relaunch never runs yesterday's assets.
  String _stage(String appPath) {
    _clearStaging();
    final staging = _makeStagingDir();
    _staged = staging;

    final source = FileSystemEntity.typeSync(appPath);
    if (source != FileSystemEntityType.directory) {
      final dest = p.join(staging.path, p.basename(appPath));
      File(appPath).copySync(dest);
      return dest;
    }

    final dest = Directory(p.join(staging.path, p.basename(appPath)))
      ..createSync(recursive: true);
    for (final entity in Directory(appPath).listSync(recursive: true)) {
      final relative = p.relative(entity.path, from: appPath);
      final target = p.join(dest.path, relative);
      if (entity is Directory) {
        Directory(target).createSync(recursive: true);
      } else if (entity is File) {
        Directory(p.dirname(target)).createSync(recursive: true);
        entity.copySync(target);
      }
    }
    return dest.path;
  }

  void _clearStaging() {
    final staged = _staged;
    _staged = null;
    if (staged != null && staged.existsSync()) {
      staged.deleteSync(recursive: true);
    }
  }

  @override
  Future<void> stop(AppInstance instance) async {
    await stopProcess('Windows app', instance.process, teardownBound);
    await instance.logs.close();
    _clearStaging();
  }

  /// How long the bundled DXGI screenshot helper gets to answer.
  ///
  /// The capture runs inside an HTTP handler, so a helper that never returns
  /// is an endpoint that never answers: the request stays open and the caller
  /// learns nothing at all, which is strictly worse than any error. Desktop
  /// Duplication is a plausible way to wedge — it blocks on the compositor
  /// handing over a frame, and a session with nothing being drawn to (a locked
  /// workstation, an RDP session that has detached) is a real state on a CI
  /// runner.
  ///
  /// Generous rather than tight: what matters here is that the request ends.
  ///
  /// Settable so a test can drive the expiry in milliseconds.
  Duration screenshotBound = const Duration(seconds: 30);

  /// Captures the screen with the bundled DXGI Desktop Duplication helper.
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
    // GDI CopyFromScreen cannot capture D3D/Flutter surfaces.
    // Use DXGI Desktop Duplication via the bundled native helper.
    final resolved = resolveRunfileWithManifest(
      'rules_flutter/tools/windows_screenshot/screenshot',
    );
    if (resolved == null) {
      throw StateError(
        'Could not find bundled Windows screenshot tool. '
        'Build first: bazel build //tools/dev_tool:flutter_bazel',
      );
    }
    final result = await runProcessBounded(
      _startScreenshotProcess,
      resolved.path,
      [outputPath],
      environment: {
        ...Platform.environment,
        if (resolved.manifestPath != null)
          'RUNFILES_MANIFEST_FILE': resolved.manifestPath!,
      },
      bound: screenshotBound,
      what: 'The bundled Windows screenshot helper',
    );
    if (result.exitCode != 0) {
      throw StateError('DXGI screenshot failed: ${result.stderr}');
    }
  }

  Future<Process> _startScreenshotProcess(
    String exe,
    List<String> args,
    Map<String, String> environment,
  ) => _injectedScreenshotStart != null
      ? _injectedScreenshotStart(exe, args)
      : Process.start(exe, args, environment: environment);
}

/// The environment a desktop Flutter app is launched with.
///
/// The desktop embedders take engine switches from the environment and nowhere
/// else — `FLUTTER_ENGINE_SWITCHES` holds the count and `FLUTTER_ENGINE_SWITCH_<N>`
/// holds each switch, numbered from 1. The runner's own argv is passed to the
/// Dart entrypoint, not to the engine, so there is no command line to put them
/// on.
///
/// A function rather than something assembled inline in each device's process
/// starter: the starters are the one seam tests replace, so anything built
/// inside them is invisible to every test that injects one.
///
/// [base] defaults to this process's environment, which the app inherits.
Map<String, String> desktopLaunchEnvironment({
  bool startPaused = false,
  Map<String, String>? base,
}) {
  final switches = <String>[
    if (startPaused) 'start-paused=true',
  ];
  return {
    ...(base ?? Platform.environment),
    // Always: a fixed port would collide across a multi-device run, and 0
    // makes the embedder pick one and announce it on stdout, which is where
    // [waitForVmServiceUri] reads it from.
    'FLUTTER_VM_SERVICE_PORT': '0',
    if (switches.isNotEmpty) 'FLUTTER_ENGINE_SWITCHES': '${switches.length}',
    for (var i = 0; i < switches.length; i++)
      'FLUTTER_ENGINE_SWITCH_${i + 1}': switches[i],
  };
}

/// Detect the appropriate device for the current platform.
Device detectDevice() {
  if (Platform.isMacOS) return MacOSDevice();
  if (Platform.isLinux) return LinuxDevice();
  if (Platform.isWindows) return WindowsDevice();
  throw UnsupportedError(
    'No device available for ${Platform.operatingSystem}. '
    'Desktop devices are supported on macOS, Linux, and Windows.',
  );
}
