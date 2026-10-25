/// Device abstraction for launching Flutter apps.
///
/// Handles platform-specific launch, VM service discovery, and
/// process lifecycle management.
///
/// ## One log source per platform
///
/// Every launched app exposes its console output on [AppInstance.logs]. Which
/// source feeds that stream is a per-platform decision, and there is exactly
/// one source per platform — this is an invariant, not a preference:
///
/// | Platform            | Source                                        |
/// | ------------------- | --------------------------------------------- |
/// | macOS/Linux/Windows | the app process's stdout + stderr             |
/// | Android             | `adb logcat`                                  |
/// | iOS Simulator       | a dedicated `simctl spawn log stream`         |
/// | iOS device          | `devicectl --console`, plus lldb's own output |
/// | Chrome (DDC)        | DWDS VM service `Stdout`/`Stderr` streams     |
/// | Chrome (WASM)       | CDP `Runtime.consoleAPICalled`                |
/// | attach mode         | VM service `Stdout`/`Stderr` streams          |
///
/// A Dart `print()` on a native device reaches *both* the process's stdout and
/// the VM service's `Stdout` stream, so subscribing to both would print every
/// line twice. VM-service streams are therefore used only where no process log
/// source exists (web, attach). This mirrors flutter_tools' `DeviceLogReader`
/// and is the reason the tempting "just read the VM service everywhere"
/// simplification is wrong.
///
/// ## Finding the VM service
///
/// On every platform above, the VM-service URI arrives in-band: the engine
/// prints it, so discovery is a *reader* of the log stream and never an owner
/// of the underlying subscriptions (see [pumpProcessLines] and
/// [waitForVmServiceUri]).
///
/// A physical iOS device is the one exception, and it is out-of-band rather
/// than a second in-band source: a wirelessly attached device has no console
/// channel at all, and the one a wired device has belongs to the `devicectl`
/// invocation that launched the app. The URI is taken from the app's
/// `_dartVmService._tcp` mDNS advertisement instead
/// ([MdnsVmServiceDiscovery]). That is the single mechanism for iOS hardware,
/// wired and wireless alike; nothing races it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_log.dart';
import 'build_mode.dart';
import 'cdp_console.dart';
import 'compiler_config.dart';
import 'device_ios_lldb.dart';
import 'host_tools.dart';
import 'key_press.dart';
import 'logging.dart';
import 'mdns_vm_service_discovery.dart';
import 'native_patch_delivery.dart';
import 'reload_strategy.dart';
import 'runfiles_helper.dart';
import 'temp_dir.dart';
import 'toolchain_info.dart';
import 'vm_service_client.dart';
import 'vm_service_discovery.dart';
import 'teardown.dart';
import 'web_module_server.dart';
import 'web_options.dart';

export 'app_log.dart' show AppLogLine, AppLogStream, LogPage;
export 'build_mode.dart' show BuildMode;
export 'host_tools.dart' show HostTool, MissingHostToolException;
export 'vm_service_discovery.dart' show vmServiceUriPattern;

final _logger = Logger('dev_tool.device');

/// The inputs [Device.createCompilerConfig] varies by platform.
///
/// One object for the values the base implementation threads one argument at
/// a time: the web toolchain, the filesystem roots and scheme, and the Dart
/// defines, registrant URI and experiments the compiler is started with.
typedef CompilerConfigInputs = ({
  WebToolchainPaths? webToolchain,
  List<String> fileSystemRoots,
  String fileSystemScheme,
  List<String> dartDefines,
  String dartPluginRegistrantUri,
  List<String> enableExperiments,
});

/// How long [ChromeSession.launch] waits for the browser to come up.
///
/// One object for the three waits a launch tunes in tests: the debugging-port
/// announcement, the app page appearing, and the poll interval between looks.
typedef ChromeLaunchWaits = ({
  Duration portTimeout,
  Duration pageTimeout,
  Duration pollInterval,
});

/// The browser page [applyViewportOverCdp] drives, by CDP port and app URL.
///
/// One object for the two values every viewport call threads together: the
/// debugging port discovered from Chrome's stderr, and the localhost URL of
/// the launched tab.
typedef CdpPageTarget = ({int cdpPort, String appUrl});

/// Report a process the OS would not let us kill.
///
/// Every `stop` implementation kills the process it launched; a refused kill
/// leaves an app (or a log tailer) running that the next run will collide with,
/// so it must be said out loud rather than swallowed by the `await exitCode`
/// that follows.
/// Stop [process], escalating past a SIGTERM it refuses.
///
/// SIGTERM is a request: a wedged process can take it and keep running, so
/// `await process.exitCode` on its own is unbounded.
///
/// SIGKILL is not refusable, so here the bound has a real remedy rather than
/// only a report. Should even that not land, this returns anyway and says so —
/// a teardown that cannot confirm a death is still better than one that never
/// ends, and the user needs to be told which they got.
///
/// Neither `kill`'s return value is read. `false` is what it reports for a
/// process that has already exited, which is the outcome being asked for: a
/// Ctrl-C in a terminal reaches the app along with this tool, so by the time
/// teardown asks, the app has often gone. Whether a stop worked is settled by
/// the process exiting, which is what the bound waits for.
Future<void> stopProcess(String what, Process process, Duration bound) async {
  process.kill();
  if (await _exitedWithin(process, bound)) return;

  _logger.warning({
    'message': 'process_kill_escalated',
    'text':
        'The $what process (pid ${process.pid}) did not exit within '
        '${bound.inMilliseconds}ms of being asked to. Sending SIGKILL.',
    'process': what,
    'pid': process.pid,
  });
  process.kill(ProcessSignal.sigkill);
  if (await _exitedWithin(process, bound)) return;

  _logger.severe({
    'message': 'process_survived_sigkill',
    'text':
        'The $what process (pid ${process.pid}) did not exit even after '
        'SIGKILL. Ending the run without it; kill it by hand if the next run '
        'finds the port or window already taken.',
    'process': what,
    'pid': process.pid,
  });
}

/// Whether [process] exits within [bound].
Future<bool> _exitedWithin(Process process, Duration bound) =>
    process.exitCode.then((_) => true).timeout(bound, onTimeout: () => false);

/// Run a helper to completion under [bound], or kill it and say what it said.
///
/// `Process.run` cannot express this: it has no bound, and there is no handle
/// to kill through even if there were. A helper that never exits therefore
/// makes its *caller* never return, and where the caller is an HTTP handler
/// that is a request held open forever — the one outcome that leaves the other
/// end with nothing to act on.
///
/// Both output streams are drained from the moment the process exists, into
/// buffers rather than futures. A read started only after the deadline loses
/// whatever the helper managed to say before it wedged, which is exactly the
/// part a reader needs; and buffers can be read on the expiry path without
/// awaiting anything, so the diagnostic itself cannot be what hangs.
///
/// SIGKILL rather than SIGTERM-then-SIGKILL: this is not a teardown that a
/// well-behaved helper should get to finish, it is a wedge, and an escalation
/// ladder here would only add a second bound to wait out.
Future<ProcessResult> runProcessBounded(
  ProcessStarterWithEnvironment start,
  String executable,
  List<String> arguments, {
  required Map<String, String> environment,
  required Duration bound,
  required String what,
}) async {
  final process = await start(executable, arguments, environment);
  final out = StringBuffer();
  final err = StringBuffer();
  final drained = Future.wait([
    process.stdout.transform(utf8.decoder).forEach(out.write),
    process.stderr.transform(utf8.decoder).forEach(err.write),
  ]);
  final int exitCode;
  try {
    exitCode = await process.exitCode.timeout(bound);
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    throw StateError(
      '$what (pid ${process.pid}) did not answer within '
      '${bound.inMilliseconds}ms and was killed. What it had written by then, '
      'on stderr: ${err.isEmpty ? '(nothing)' : err}',
    );
  }
  await drained;
  return ProcessResult(process.pid, exitCode, out.toString(), err.toString());
}

/// Called for each line of a running app's console output.
typedef AppLogListener = void Function(AppLogLine line);

/// A running Flutter application instance.
class AppInstance {
  final Process process;
  final Uri? vmServiceUri;

  /// Why VM-service discovery gave up while the app was still alive.
  ///
  /// Null when discovery announced a URI, or never waited on a living app
  /// (no liveness signal, or a build mode that serves no VM service). The
  /// run's abort-or-continue decision reports this when the launch continues
  /// without a URI: the bound, the option that raises it, and the last log
  /// lines.
  final String? vmServiceDiscoveryNote;

  /// Optional HTTP server (used by WebDevice).
  final HttpServer? server;

  /// The app's console output, for the lifetime of the run.
  ///
  /// Buffered, so a consumer that attaches after launch still sees everything
  /// printed during startup. Closed by the owning device's `stop()`.
  final AppLogStream logs;

  /// Helper processes spawned alongside [process] that must die with the run —
  /// e.g. the iOS Simulator's second `log stream`. Tracked here so `stop()`
  /// cannot leak them, rather than each device inventing its own field.
  final List<Process> auxiliaryProcesses;

  /// Temporary directories this launch created that live as long as it does —
  /// an unpacked `.app`, a staging copy, a throwaway browser profile.
  ///
  /// Here for the same reason [auxiliaryProcesses] is: the directory belongs to
  /// the launch, not to the device object, and a device that tracks one
  /// privately never deletes it.
  final List<Directory> scratchDirs;

  AppInstance({
    required this.process,
    this.vmServiceUri,
    this.vmServiceDiscoveryNote,
    this.server,
    AppLogStream? logs,
    this.auxiliaryProcesses = const [],
    this.scratchDirs = const [],
  }) : logs = logs ?? AppLogStream();

  /// Kill every [auxiliaryProcesses] entry and await its exit.
  /// [bound] is how long each one gets before it is escalated to SIGKILL —
  /// these are the same refusable SIGTERMs every other stopped process gets,
  /// and a log tailer that ignores one would hang the whole teardown.
  Future<void> disposeAuxiliaryProcesses(Duration bound) async {
    await Future.wait(
      auxiliaryProcesses.map((aux) => stopProcess('auxiliary', aux, bound)),
    );
  }

  /// Remove every [scratchDirs] entry.
  ///
  /// Call after the processes that were using them have exited: a directory
  /// deleted out from under a still-running program comes back partly written.
  Future<void> disposeScratchDirs() async {
    for (final dir in scratchDirs) {
      await deleteTempDir(dir);
    }
  }
}

/// A temp folder that a launch in flight owns: the unpacked app it installs
/// or runs.
///
/// A launch that returns hands the folder to its [AppInstance], whose `stop`
/// deletes it. Until then the launch must delete it on every way out: a throw,
/// and an abandon from a teardown that may end the tool before the launch
/// unwinds. Otherwise each failed launch leaves a copy of the app in TMPDIR.
class LaunchScratch {
  Directory? _dir;

  void hold(Directory dir) => _dir = dir;

  /// Gives the folder to the [AppInstance] being returned, which deletes it
  /// from then on.
  List<Directory> handOver() {
    final dir = _dir;
    _dir = null;
    return [?dir];
  }

  /// Deletes the folder, unless it was handed over.
  Future<void> release() async {
    final dir = _dir;
    _dir = null;
    if (dir != null) await deleteTempDir(dir);
  }
}

/// Abstract device that can launch and manage a Flutter app.
abstract class Device {
  /// How long [stop] waits on any one thing it is stopping before giving up on
  /// that step and moving to the next.
  ///
  /// Teardown talks to peers this process does not control — a browser, an
  /// app's VM service, a third-party service's own shutdown — and any of them
  /// can stop answering. Every await on one is bounded by this, so a wedged
  /// peer costs a run a few seconds instead of never returning: the whole
  /// chain must reach the kill, and `flutter_bazel` must come back.
  ///
  /// Settable so tests can drive the expiry paths in milliseconds instead of
  /// waiting out the real bound.
  Duration teardownBound = const Duration(seconds: 5);

  /// How long VM-service discovery waits for the app's announcement.
  ///
  /// While the app is alive the wait keeps going up to this bound, logging
  /// `still waiting` progress lines; a hung app still fails at it. The
  /// `dev_tool run --vm-service-timeout` value in production, which
  /// [prepareDevicesForLaunch] copies here before [launch].
  ///
  /// Settable so tests can drive the expiry in seconds instead of minutes.
  Duration vmServiceTimeout = defaultVmServiceDiscoveryBound;

  /// The run's logger, for discovery's progress lines.
  ///
  /// Set by [prepareDevicesForLaunch] so the `still waiting` lines go through
  /// the same logger the rest of the run reports through. Null outside a run
  /// (tests, direct use), where discovery falls back to the module logger.
  Logger? discoveryLogger;

  /// The discovery wait this device launches with: its [vmServiceTimeout] as
  /// the bound, on the system clock.
  VmDiscoveryConfig discoveryConfig() =>
      VmDiscoveryConfig(bound: vmServiceTimeout);

  /// Where discovery's progress lines go: the run's logger, or the module
  /// logger outside a run.
  Logger activeDiscoveryLogger() => discoveryLogger ?? _logger;

  /// Wait for a desktop app's VM-service announcement on [logs].
  ///
  /// Null URI in a build mode that serves none (release): there is nothing
  /// to wait for, so the launch continues at once. Otherwise the wait lasts
  /// while the app lives — a desktop app is a child process, so its exit
  /// ends the wait at once — up to [vmServiceTimeout].
  Future<VmServiceDiscovery> discoverDesktopVmService(
    AppLogStream logs,
    Process process,
  ) {
    if (!buildMode.servesVmService) {
      return Future.value((uri: null, gaveUpNote: null));
    }
    return waitForVmServiceUri(
      logs: logs,
      deviceName: name,
      appExit: process.exitCode,
      config: discoveryConfig(),
      logger: activeDiscoveryLogger(),
      abandoned: launchAbortSignal,
    );
  }

  /// Launch the app and return the running instance.
  ///
  /// [appPath] is the path to the built application artifact.
  ///
  /// [onLog] is attached to the app's output stream *before* VM-service
  /// discovery begins, so a caller sees startup output as it happens rather
  /// than in a burst once `launch` returns. That matters most when discovery
  /// never succeeds: an app that crashes before binding its VM service prints
  /// the reason during the discovery window. Callers that pass [onLog] must
  /// not also subscribe to [AppInstance.logs], or every line arrives twice.
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog});

  /// Stop the running app.
  Future<void> stop(AppInstance instance);

  /// Release what a launch left running when no session took ownership of it.
  ///
  /// The launcher gives this to the run's teardown before it calls [launch],
  /// because a session's own disposer is registered only once the launch and
  /// the VM-service connect after it have both finished — minutes, on a
  /// physical device. A teardown in that window (SIGTERM, `daemon.shutdown`)
  /// otherwise reaches nothing on the device, and helpers that outlive this
  /// process keep ports and apps up with nothing left to stop them. A launch
  /// still in flight must fail rather than start anything more.
  ///
  /// The base records the abandonment: every discovery wait a launch in
  /// flight is sitting in ends at once through [launchAbortSignal], and a
  /// later launch on this device refuses rather than starts anything more —
  /// a relaunch in flight at shutdown must stop, not go on to leave an app
  /// running after the shutdown released the apps. The signal completes
  /// before anything is stopped, so a shutdown that kills the app reports
  /// the cancellation (the signal won the race) while an app that already
  /// exited on its own keeps its exit report; then the launch's partial
  /// state is released through [releaseLaunch].
  ///
  /// Called after the session's own [stop] when there is one, so it must be a
  /// no-op on anything that is already released.
  Future<void> abandonLaunch() async {
    _launchAbandoned = true;
    _launchCancel?.complete();
    await releaseLaunch();
  }

  /// Undo a launch that did not return: release its partial state.
  ///
  /// Runs at the end of [abandonLaunch], after the abandonment signal, and on
  /// a launch failure through [trackedLaunch]. A device whose launch may have
  /// started something — an app process, log helpers, a staged copy —
  /// overrides this to release it; the default is a no-op for devices with
  /// nothing to release. Must itself be a no-op when nothing is in flight,
  /// since abandonment also runs after a completed launch's [stop].
  Future<void> releaseLaunch() async {}

  /// Run [start] as a tracked launch, releasing its partial state on failure.
  ///
  /// Refuses when the run is already ending ([abandonLaunch] ran), else arms
  /// the abandonment signal for the launch in flight. When [start] returns,
  /// the launch ends with the instance; when it throws, the launch ends and
  /// what it started is released through [releaseLaunch] before the error is
  /// rethrown, so a failed launch leaves nothing running.
  Future<AppInstance> trackedLaunch(
    Future<AppInstance> Function() start,
  ) async {
    _beginLaunch();
    try {
      final instance = await start();
      _endLaunch();
      return instance;
    } catch (_) {
      _endLaunch();
      await releaseLaunch();
      rethrow;
    }
  }

  /// Whether [abandonLaunch] has run on this device since the last launch.
  ///
  /// Sticky across the launch: once the run is ending, nothing on this device
  /// starts anything more, including a relaunch the shutdown arrived in the
  /// middle of.
  bool _launchAbandoned = false;

  /// Whether [abandonLaunch] has run since the last launch began.
  ///
  /// True once the run is ending: nothing on this device starts anything more.
  /// Reads the same flag [throwIfLaunchAbandoned] throws on, for launches
  /// that report the abandonment another way.
  bool get launchAbandoned => _launchAbandoned;

  /// Completed by [abandonLaunch] while a launch is in flight.
  ///
  /// Null between launches, so the signal each discovery wait races belongs
  /// to its own launch: a stale completion must never end a later wait.
  Completer<void>? _launchCancel;

  /// The signal to end every discovery wait of the launch in flight.
  ///
  /// Null between launches; the wait then has no abandonment to observe.
  Future<void>? get launchAbortSignal => _launchCancel?.future;

  /// Start a launch: refuse when the run is already ending, else arm the
  /// abandonment signal for the launch in flight.
  ///
  /// A launch still in flight must fail rather than start anything more, and
  /// so must a launch that starts after the abandonment: without the refusal
  /// a relaunch racing the shutdown would go on to leave an app running after
  /// the shutdown released the apps.
  void _beginLaunch() {
    throwIfLaunchAbandoned();
    _launchCancel = Completer<void>();
  }

  /// End a launch: disarm the abandonment signal, keeping the refusal.
  ///
  /// The flag stays set after a launch that [abandonLaunch] interrupted — the
  /// device is done launching — while the completer goes, so a cancelled wait
  /// cannot resolve a later one.
  void _endLaunch() {
    _launchCancel = null;
  }

  /// Fail now when [abandonLaunch] has run since the last launch began.
  ///
  /// A [VmDiscoveryCancelled] naming this device: an abandoned launch reports
  /// the cancellation, whatever step it had reached, including the relaunch of
  /// a restart's native libraries.
  void throwIfLaunchAbandoned() {
    if (launchAbandoned) throw VmDiscoveryCancelled(name);
  }

  /// The external programs a launch on this device will drive.
  ///
  /// Declared rather than discovered at each call site so [preflight] can check
  /// them all before a run does any work, and declared *per device* so an iOS,
  /// macOS or Chrome run is never made to install the Android SDK. Async
  /// because the answer can depend on the device itself: a cabled iOS device is
  /// reached through an `iproxy` forward and a wireless one is not.
  Future<List<HostTool>> requiredHostTools() async => const [];

  /// Fail now, by name, if the host is missing anything this device needs.
  ///
  /// Called before the build, so a missing `aapt2` or an unattached phone is
  /// reported in seconds. Without it the shortfall surfaces mid-launch as a
  /// symptom instead of a cause.
  Future<void> preflight() async {
    for (final tool in await requiredHostTools()) {
      tool.require();
    }
  }

  /// Capture a screenshot of the running app.
  ///
  /// For native platforms, uses the VM service `_flutter.screenshot` extension
  /// (pass [vmClient]). For web, subclasses override with CDP.
  /// Throws [UnsupportedError] if no VM client is available.
  ///
  /// [window] is an optional, platform-specific selector for which window to
  /// capture (e.g. on macOS, the exact window title). Devices that don't
  /// support window selection ignore it.
  Future<void> screenshot(
    AppInstance instance,
    String outputPath, {
    VmServiceClient? vmClient,
    String? window,
  }) {
    if (vmClient != null) {
      return vmClient.screenshot(outputPath);
    }
    throw UnsupportedError(
      'Screenshot not supported on $name without VM service',
    );
  }

  /// Whether `_flutter.screenshot` — the VM-service capture of just the
  /// widget tree — can ever succeed on this device.
  ///
  /// The engine cannot encode a compressed screenshot under Impeller, so the
  /// RPC fails with a bare "Could not capture image screenshot" wherever
  /// Impeller renders, and there is no engine screenshot on web at all.
  /// Declared rather than inferred from a failure, so a caller is told the
  /// request can never work — and which endpoint does — instead of getting a
  /// 500 that reads as transient and invites a retry.
  ///
  /// False for every device at the pinned Flutter, because every platform
  /// renders with Impeller by default there.
  ///
  /// An app that opts out of Impeller — the desktop embedders and Android
  /// still allow it — *could* serve the RPC, and this gives up on it. That is
  /// deliberate: the renderer is a runtime property of the app, so nothing
  /// here can tell the two apart without asking it, and the `native` endpoint
  /// captures both. Kept a getter rather than made a constant so a device that
  /// can serve the RPC has somewhere to say so.
  bool get supportsFlutterScreenshot => false;

  /// Whether to hold the app's root isolate at the start of `main()`.
  ///
  /// Set before [launch]: every platform delivers it as a launch-time engine
  /// argument, so it cannot be turned on afterwards. The app then sits at
  /// `PauseStart` until a debugger resumes it — which is the point, and also
  /// why nothing that needs a running framework (a first frame, a service
  /// extension, an `app.*` command) will answer until it does.
  bool startPaused = false;

  /// The build mode of the app this device will launch.
  ///
  /// Set before [preflight], because it changes which host tools a launch
  /// needs as well as how it launches. Debug until told otherwise, which is
  /// what every launch did before any device needed to know.
  BuildMode buildMode = BuildMode.debug;

  /// Whether filesystem paths on this device are Windows-shaped.
  ///
  /// The device answers, not the host: a devFS path comes back from the target
  /// VM, and converting it with `Platform.isWindows` is right only while the
  /// two happen to agree. Driving an Android phone from a Windows desktop is
  /// where they do not.
  bool get usesWindowsPaths => false;

  /// Display name for this device.
  String get name;

  /// How long a single hot reload or hot restart RPC may take here.
  ///
  /// A latency budget, not a correctness knob: the call is abandoned and the
  /// VM-service connection force-closed when it expires, so it has to be
  /// longer than the slowest legitimate apply on this platform. The default
  /// suits a host process, where the VM is local and a restart is
  /// milliseconds of work.
  Duration get applyTimeout => const Duration(seconds: 30);

  /// Pick the runnable artifact from a target's cquery outputs.
  ///
  /// Default returns the first output. Subclasses override when the
  /// rule emits multiple outputs in an order that doesn't put the
  /// runnable artifact first — `android_binary`, for example, lists
  /// `<name>_deploy.jar` before `<name>.apk`, and the deploy jar is
  /// not installable.
  String pickArtifact(List<String> outputs) => outputs.first;

  /// Platform-specific arguments for `bazel build`.
  ///
  /// These are injected into `bazel build` and `bazel cquery` to ensure
  /// correct cross-compilation and output resolution.
  List<String> get buildArgs => const [];

  /// Create the compiler config for hot reload on this platform.
  ///
  /// Returns null if this device does not support hot reload.
  CompilerConfig? createCompilerConfig(
    ToolchainPaths toolchain, [
    CompilerConfigInputs? inputs,
  ]) => NativeCompilerConfig(
    patchedSdkRoot: toolchain.patchedSdkRoot,
    fileSystemRoots: inputs?.fileSystemRoots ?? const [],
    fileSystemScheme: inputs?.fileSystemScheme ?? '',
    dartDefines: inputs?.dartDefines ?? const [],
    dartPluginRegistrantUri: inputs?.dartPluginRegistrantUri ?? '',
    enableExperiments: inputs?.enableExperiments ?? const [],
  );

  /// Create the reload strategy for this platform.
  ///
  /// Every device that gets here has one: a device this cannot answer for
  /// refuses by name (see [WebDevice.createReloadStrategy]) rather than
  /// returning null.
  ReloadStrategy createReloadStrategy() => VmServiceReloadStrategy();

  /// How a native hot patch reaches the app this device launched, or null where
  /// none can: a device no delivery has been written for, or one that has not
  /// launched the app it would need to know about.
  NativePatchDelivery? get nativePatchDelivery => null;
}

/// Signature for running a process and returning its result (allows test injection).
typedef ProcessRunSync = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// Signature for starting a streaming process (allows test injection).
typedef ProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments,
);

/// [ProcessStarter] for a helper whose environment the caller assembles.
///
/// The bundled screenshot helpers need `RUNFILES_MANIFEST_FILE` forwarded to
/// find their own runfiles, and that path is only known at the call site.
typedef ProcessStarterWithEnvironment = Future<Process> Function(
  String executable,
  List<String> arguments,
  Map<String, String> environment,
);

/// Wait until a local TCP listener on 127.0.0.1:[port] accepts connections.
///
/// Port forwarders (iproxy, adb forward) bind their local listener
/// asynchronously after `Process.start` returns; dialing the forward before
/// it is bound gets ECONNREFUSED. Polls `Socket.connect` with exponential
/// backoff and destroys each probe socket. Throws [StateError] naming [what]
/// if the listener never accepts within [budget].
Future<void> waitForLocalTcpPort(
  int port, {
  required String what,
  Duration budget = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(budget);
  var delay = const Duration(milliseconds: 50);
  while (true) {
    try {
      final probe = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(seconds: 1),
      );
      probe.destroy();
      return;
    } catch (_) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
          '$what on 127.0.0.1:$port did not accept connections within '
          '${budget.inSeconds}s of starting.',
        );
      }
      await Future<void>.delayed(delay);
      final doubled = delay * 2;
      delay = doubled > const Duration(milliseconds: 500)
          ? const Duration(milliseconds: 500)
          : doubled;
    }
  }
}

/// Create the log stream for a launch, attach [onLog], and start draining
/// [process] into it as its only source.
///
/// [onLog] is wired before the pump starts so no line can slip past it.
///
/// For every platform but a physical iOS device the app has exactly one log
/// source, so the stream's life is that source's life — see
/// [IOSDevice.launch] for the one place that owns two.
AppLogStream startProcessLogs(
  Process process,
  AppLogListener? onLog, {
  bool stderrIsError = true,
  String? Function(String line)? transform,
}) {
  final logs = _newAppLogs(onLog);
  final pump = pumpProcessLines(
    process,
    logs,
    stderrIsError: stderrIsError,
    transform: transform,
  );
  logs.closeWhen([pump.done]);
  return logs;
}

/// An empty log stream with [onLog] already attached.
///
/// Wiring the sink before any pump starts is what guarantees no line can slip
/// past it — including output printed during startup, before `launch()` has
/// returned.
AppLogStream _newAppLogs(AppLogListener? onLog) {
  final logs = AppLogStream();
  if (onLog != null) logs.lines.listen(onLog);
  return logs;
}

/// Reads the bundle identifier out of an extracted .app's Info.plist.
Future<String> extractBundleId(
  String appPath,
  ProcessRunSync runProcess,
) async {
  final result = await runProcess('defaults', [
    'read',
    '$appPath/Info.plist',
    'CFBundleIdentifier',
  ]);
  if (result.exitCode == 0) {
    return (result.stdout as String).trim();
  }
  throw StateError('Could not extract bundle ID from $appPath');
}

/// Extracts the .app directory from an .ipa archive, ready to install on an
/// iOS simulator or device.
///
/// Returns the directory alongside the bundle so the caller can hold it for
/// exactly as long as the launch needs it — see [AppInstance.scratchDirs].
Future<({String appPath, Directory dir})> extractAppFromIpa(
  String ipaPath,
  ProcessRunSync runProcess,
) async {
  final tempDir = await createTempDir('flutter_ipa_');
  try {
    final result = await runProcess('unzip', [
      '-oq',
      ipaPath,
      '-d',
      tempDir.path,
    ]);
    if (result.exitCode != 0) {
      throw StateError('Failed to extract IPA: ${result.stderr}');
    }
    final payloadDir = Directory(p.join(tempDir.path, 'Payload'));
    if (!payloadDir.existsSync()) {
      throw StateError('No Payload directory found in IPA');
    }
    final apps = payloadDir
        .listSync()
        .where((e) => e.path.endsWith('.app'))
        .toList();
    if (apps.isEmpty) {
      throw StateError('No .app found in IPA Payload directory');
    }
    // Bazel writes every archived file with the same fixed 1980 mtime, and
    // both `simctl install` and `devicectl device install app` keep an
    // installed file whose size and mtime both match the new one. A rebuilt
    // native library or AOT App.framework that kept its size would install as
    // the old machine code, so stamp everything now.
    final now = DateTime.now();
    await for (final entity in tempDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) await entity.setLastModified(now);
    }
    return (appPath: apps.first.path, dir: tempDir);
  } catch (_) {
    // Nothing usable came out of the archive; the half-unpacked copy is only
    // going to sit there.
    await deleteTempDir(tempDir);
    rethrow;
  }
}

/// How a paired physical device is currently reachable.
///
/// This decides two things that have to agree with each other: whether the app
/// is launched with its VM service bound to all interfaces, and whether that
/// service is dialed through a port forward or at the device's own address.
enum IOSDeviceTransport {
  /// Attached by cable. The VM service binds to the device's loopback — which
  /// is what `--vm-service-host` defaults to — so it is reached through an
  /// `iproxy` forward.
  wired,

  /// Reachable over the network. There is no cable to forward through, so the
  /// app must be launched with `--vm-service-host=0.0.0.0` and dialed at the
  /// device's own address.
  wireless,
}

/// What `devicectl list devices` reports about one paired physical device.
class IOSDeviceInfo {
  /// The hardware UDID.
  ///
  /// This is the identifier every tool here is addressed with. `devicectl`
  /// also answers to its own CoreDevice UUID ([coreDeviceId]) and reports that
  /// one first, but `lldb device select`, `iproxy -u` and the pymobiledevice3
  /// screenshot helper all go through usbmuxd, which has never heard of it —
  /// addressing them with it produces a port forward that binds locally and
  /// then resets every connection.
  final String udid;

  /// The CoreDevice UUID `devicectl` lists as `identifier`. Kept so that a
  /// UDID copied out of `devicectl list devices` still selects this device.
  final String coreDeviceId;

  final String name;
  final IOSDeviceTransport transport;

  /// The device's own mDNS hostnames, of the form
  /// `<device-name>.coredevice.local`.
  ///
  /// These are what tell this device's `_dartVmService._tcp` advertisement
  /// apart from every other advertiser on the network — including this Mac
  /// running the same bundle id in a simulator. See
  /// [MdnsVmServiceDiscovery.discover].
  final List<String> hostnames;

  IOSDeviceInfo({
    required this.udid,
    required this.coreDeviceId,
    required this.name,
    required this.transport,
    required this.hostnames,
  });

  /// Whether [identifier] names this device, in either identifier space.
  bool matches(String identifier) =>
      udid == identifier || coreDeviceId == identifier;

  @override
  String toString() => '$name ($udid, ${transport.name})';
}

/// The devices `devicectl list devices --json-output` reports as usable now.
///
/// Entries without a recognised `transportType` are dropped: a device that was
/// paired once but is not currently attached is still listed, with no
/// transport and `tunnelState: unavailable`. Picking one of those produces a
/// launch that installs nothing and then waits out every timeout, instead of
/// a "no device attached" error at the first step.
List<IOSDeviceInfo> parseDevicectlDevices(String jsonText) {
  final data = json.decode(jsonText) as Map<String, dynamic>;
  final devices = (data['result']?['devices'] as List?) ?? const [];
  final result = <IOSDeviceInfo>[];
  for (final entry in devices) {
    final device = entry as Map<String, dynamic>;
    final connection =
        (device['connectionProperties'] as Map?)?.cast<String, dynamic>() ??
        const {};
    final transport = switch ((connection['transportType'] as String?)
        ?.toLowerCase()) {
      'wired' => IOSDeviceTransport.wired,
      'localnetwork' => IOSDeviceTransport.wireless,
      _ => null,
    };
    if (transport == null) continue;
    final coreDeviceId = device['identifier'] as String?;
    final udid = ((device['hardwareProperties'] as Map?)?['udid']) as String?;
    if (coreDeviceId == null || udid == null) continue;
    final properties =
        (device['deviceProperties'] as Map?)?.cast<String, dynamic>() ??
        const {};
    result.add(
      IOSDeviceInfo(
        udid: udid,
        coreDeviceId: coreDeviceId,
        name: properties['name'] as String? ?? udid,
        transport: transport,
        hostnames:
            ((connection['localHostnames'] as List?) ??
                    (connection['potentialHostnames'] as List?) ??
                    const [])
                .cast<String>(),
      ),
    );
  }
  return result;
}

/// iOS physical device (via xcrun devicectl + lldb).
class IOSDevice extends Device {
  /// The UDID the user asked for, or null to use whichever device is attached.
  final String? requestedUdid;
  final String? _bundleId;

  /// Runs a process to completion and returns its result.
  ///
  /// [Process.run] unless a test injects a fake.
  final ProcessRunSync runProcess;
  final ProcessStarter _startProcess;
  final MdnsVmServiceDiscovery _mdns;

  /// Filled in by the first [_resolveInfo].
  IOSDeviceInfo? _info;

  /// iproxy process for port forwarding (killed on stop).
  Process? _iproxyProcess;

  /// devicectl --console process for stdout capture (killed on stop).
  Process? _consoleLauncherProcess;

  /// lldb process for debugger attachment (killed on stop).
  Process? lldbProcess;

  /// The launched app's pid on the device, once the launch has found it.
  ///
  /// Killing lldb does not end the app on a physical device — debugserver
  /// detaches and the app keeps running — so this is what [stop] terminates.
  int? _appPid;

  /// What the current launch's lldb does with a stop, once the app runs.
  LldbStops? lldbStops;

  IOSDevice({
    String? udid,
    String? bundleId,
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
    MdnsVmServiceDiscovery? mdns,
  }) : requestedUdid = udid,
       _bundleId = bundleId,
       runProcess = runProcess ?? Process.run,
       _startProcess = startProcess ?? Process.start,
       _mdns = mdns ?? MdnsVmServiceDiscovery();

  /// The UDID in play.
  ///
  /// The resolved hardware UDID wins over whatever was asked for: a user may
  /// legitimately pass the CoreDevice UUID (it is what `devicectl list
  /// devices` prints), but usbmuxd-backed tools cannot use it. Before a device
  /// is resolved there is nothing else to report, so the request stands in.
  String? get udid => _info?.udid ?? requestedUdid;

  /// The UDID of the device commands are addressed to.
  ///
  /// Throws rather than guessing: every caller runs after [launch] has
  /// resolved a device, or was handed an explicit UDID.
  String get addressedUdid {
    final resolved = udid;
    if (resolved == null) {
      throw StateError(
        'No iOS device has been resolved yet. This device was '
        'created without a UDID, so launch() must run first.',
      );
    }
    return resolved;
  }

  /// The bundle and the installed `.app` of the last launch, which a patch is
  /// signed and addressed by.
  String? _launchedBundleId;
  String? _launchedAppPath;

  @override
  NativePatchDelivery? get nativePatchDelivery {
    final bundleId = _launchedBundleId;
    final appPath = _launchedAppPath;
    final resolved = udid;
    if (bundleId == null || appPath == null || resolved == null) return null;
    return IOSDevicePatchDelivery(
      udid: resolved,
      bundleId: bundleId,
      appPath: appPath,
      run: runProcess,
    );
  }

  @override
  String get name => 'iOS (${udid ?? 'auto-detect'})';

  @override
  List<String> get buildArgs => const ['--ios_multi_cpus=arm64'];

  /// Resolves the device as a side effect, which is the point: an unattached
  /// or ambiguous phone is a launch-blocking condition too, and finding out
  /// here costs one `devicectl list` instead of a whole build.
  @override
  Future<List<HostTool>> requiredHostTools() async {
    final info = await _resolveInfo();
    return [
      // Only a debug app is run under the debugger.
      if (buildMode == BuildMode.debug) lldbTool(),
      // Only a cabled device is reached through a port forward; a wireless one
      // is dialed at its own address, so demanding iproxy there would refuse a
      // run that works. A release app has no VM service to forward to. `xcrun`
      // is not listed: it is part of macOS, and a missing or misconfigured
      // Xcode is already reported by [_resolveInfo], with devicectl's own
      // explanation attached.
      if (info.transport == IOSDeviceTransport.wired &&
          buildMode != BuildMode.release)
        iproxyTool(),
    ];
  }

  /// A hot restart re-runs `main()`, which re-JITs the app — and every new
  /// executable page traps into the `NOTIFY_DEBUGGER_ABOUT_RX_PAGES`
  /// breakpoint, whose handler writes to device memory over the debugserver
  /// link. That per-page round trip is what makes a cold start here cost far
  /// more than the under-a-second a desktop app takes; a restart is the same
  /// work. (Setting `--auto-continue` on the breakpoint does not help: the cost
  /// is the memory write, not the stop/resume handshake.) The host default
  /// would abandon the RPC and force-close the connection while the device was
  /// still working.
  ///
  /// The magnitude depends on the host as much as the link: a Mac whose Xcode
  /// symbol copy is stranded half-finished leaves lldb without the on-disk
  /// shared cache, and costs an order of magnitude more than a healthy one.
  /// These budgets are sized for that degraded host deliberately — they are
  /// backstops for a run that will never succeed, not estimates of a healthy
  /// one.
  @override
  Duration get applyTimeout => switch (_info?.transport) {
    IOSDeviceTransport.wireless => const Duration(minutes: 15),
    _ => const Duration(minutes: 5),
  };

  /// Ask `devicectl` which device this is, once per run.
  ///
  /// Resolves the UDID when none was given, and in every case picks up the
  /// transport and mDNS hostnames the rest of [launch] needs. Ambiguity is an
  /// error, not a first-match: two attached devices means the user has to say
  /// which one, and silently choosing would look like a working run against
  /// the wrong phone.
  Future<IOSDeviceInfo> _resolveInfo() async {
    final cached = _info;
    if (cached != null) return cached;

    final available = await withTempDir('flutter_devicectl_', (dir) async {
      final jsonPath = p.join(dir.path, 'devices.json');
      final result = await runProcess('xcrun', [
        'devicectl',
        'list',
        'devices',
        '--json-output',
        jsonPath,
      ]);
      if (result.exitCode != 0) {
        throw StateError('devicectl list devices failed: ${result.stderr}');
      }
      final jsonFile = File(jsonPath);
      if (!jsonFile.existsSync()) {
        throw StateError(
          'devicectl list devices reported success but wrote no '
          'device list to $jsonPath.',
        );
      }
      return parseDevicectlDevices(jsonFile.readAsStringSync());
    });

    final requested = requestedUdid;
    if (requested != null) {
      final match = available.where((d) => d.matches(requested));
      if (match.isEmpty) {
        throw StateError(
          'No attached iOS device with UDID $requested.'
          '${_availableSuffix(available)}',
        );
      }
      return _info = match.first;
    }
    if (available.isEmpty) {
      throw StateError(
        'No iOS device is attached. Connect one by cable, or '
        'pair it for network debugging in Xcode > Window > Devices and '
        'Simulators.',
      );
    }
    if (available.length > 1) {
      throw StateError(
        'More than one iOS device is attached; say which one '
        'with -d ios:<udid>.${_availableSuffix(available)}',
      );
    }
    return _info = available.single;
  }

  static String _availableSuffix(List<IOSDeviceInfo> available) =>
      available.isEmpty
      ? ''
      : '\nAttached devices:\n'
            '${available.map((d) => '  ${d.udid}  ${d.name} (${d.transport.name})').join('\n')}';

  /// Installs, launches, attaches the debugger, and finds the VM service —
  /// tearing down whatever it started if any of that fails.
  ///
  /// A launch on this platform starts three long-lived helpers before it can
  /// return: the `devicectl --console` launcher, `lldb`, and (over a cable)
  /// `iproxy`. [stop] reaps all three, but `stop` takes the [AppInstance] a
  /// successful launch produced, so a launch that throws never reaches it —
  /// leaving the app up on the phone behind lldb and iproxy holding its host
  /// port. There are five throw sites past the first helper: a missing pid,
  /// three lldb commands, mDNS discovery giving up, and a forward that never
  /// binds.
  ///
  /// Guarding here rather than at each site: the set to reap is "whatever this
  /// launch got as far as starting", which is exactly what the fields say, and
  /// a per-site version would have to be repeated at every future one.
  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    _beginLaunch();
    try {
      final instance = await _launchAndAttach(appPath, onLog: onLog);
      _endLaunch();
      return instance;
    } on MdnsDiscoveryException catch (e) {
      // A launch failure like any other, so the launcher reports it: its own
      // type escaped as an unhandled exception and took the tool down.
      _endLaunch();
      await _abandonLaunch();
      throw StateError(e.message);
    } on MdnsAbandoned {
      // The run ended inside the mDNS wait: report the launch as cancelled,
      // so a relaunch in flight at shutdown says so instead of going quiet.
      _endLaunch();
      await _abandonLaunch();
      throw VmDiscoveryCancelled(name);
    } catch (_) {
      _endLaunch();
      await _abandonLaunch();
      rethrow;
    }
  }

  @override
  Future<void> abandonLaunch() async {
    await super.abandonLaunch();
    await _abandonLaunch();
  }

  /// Start a launch helper, unless the launch has been abandoned; one started
  /// just as it was abandoned is killed rather than left to outlive the run.
  Future<Process> startHelper(String executable, List<String> args) async {
    throwIfLaunchAbandoned();
    final process = await _startProcess(executable, args);
    if (launchAbandoned) {
      process.kill(ProcessSignal.sigkill);
      throwIfLaunchAbandoned();
    }
    return process;
  }

  /// Undo a launch that did not complete: every helper it started, then the
  /// app it may have resumed.
  Future<void> _abandonLaunch() async {
    lldbStops?.stopping = true;
    // Helpers first: see [_terminateApp] for why the debugger must be gone.
    await _reapLaunchHelpers();
    await _terminateApp();
    // `devicectl install` copies the app, so nothing runs out of this.
    await _scratch.release();
  }

  final _scratch = LaunchScratch();

  Future<AppInstance> _launchAndAttach(
    String appPath, {
    AppLogListener? onLog,
  }) async {
    final info = await _resolveInfo();

    final installed = await _installAppOnDevice(appPath, info);
    final installPath = installed.path;

    // Extract bundle ID from .app/Info.plist if not provided.
    final bundleId =
        _bundleId ?? await extractBundleId(installPath, runProcess);
    _launchedBundleId = bundleId;
    _launchedAppPath = installPath;

    // An iOS debug app needs a debugger (ptrace) attached before the Flutter
    // engine will start, because its JIT has to be given executable pages.
    // An AOT app needs none, and flutter_tools attaches one only in debug
    // (`shouldAttachLLDBDebugger` in `ios/devices.dart`). So:
    //   1. Launch via devicectl --console; stopped, in debug
    //   2. Get PID from process list
    //   3. In debug only: attach lldb (which starts debugserver / ptrace), set
    //      the JIT page notification breakpoint, and resume
    //   4. Discover the VM service by its mDNS advertisement, if there is one
    final debug = buildMode == BuildMode.debug;

    final logs = _newAppLogs(onLog);

    // Step 1: Launch with --console to capture the app's output.
    //
    // flutter_tools wraps this in `script -t 0 /dev/null` "to convince
    // devicectl it has a terminal attached in order to redirect stdout"
    // (`ios/core_devices.dart`). That is unnecessary here: devicectl writes
    // the app's console output to these pipes without a pty.
    _consoleLauncherProcess = await _startConsoleLauncher(
      info,
      bundleId,
      debug: debug,
    );
    final consolePump = await _awaitLaunchBanner(logs);

    // Step 2: Get PID from running process list. [stop] terminates the app by
    // it, debugger or not.
    final processId = await findAppProcessId(installed.installationUrl);
    _appPid = processId;

    // Step 3: In debug, attach lldb. Otherwise devicectl, which runs until the
    // app exits, is both the log source and the process the run watches.
    final Process process;
    if (debug) {
      process = await attachDebugger(
        info: info,
        processId: processId,
        logs: logs,
        consoleDone: consolePump.done,
      );
    } else {
      logs.closeWhen([consolePump.done]);
      process = _consoleLauncherProcess!;
    }

    // Step 4: Find the VM service by its mDNS advertisement.
    final vmServiceUri = await _findVmService(
      info: info,
      bundleId: bundleId,
      installPath: installPath,
      logs: logs,
    );

    return AppInstance(
      process: process,
      vmServiceUri: vmServiceUri,
      logs: logs,
      scratchDirs: _scratch.handOver(),
    );
  }

  /// Installed app paths: where to install from and the install's handle.
  ///
  /// Installs with JSON output to capture installationURL — the only handle on
  /// the process this launch goes on to attach a debugger to.
  Future<({String path, String installationUrl})> _installAppOnDevice(
    String appPath,
    IOSDeviceInfo info,
  ) async {
    // Extract .app from .ipa if needed — devicectl install requires .app.
    String installPath = appPath;
    if (appPath.endsWith('.ipa')) {
      final extracted = await extractAppFromIpa(appPath, runProcess);
      installPath = extracted.appPath;
      _scratch.hold(extracted.dir);
    }

    final installationUrl = await withTempDir('flutter_install_', (
      installJsonDir,
    ) async {
      final installJsonPath = p.join(installJsonDir.path, 'install.json');

      final installResult = await runProcess('xcrun', [
        'devicectl',
        'device',
        'install',
        'app',
        '--device',
        info.udid,
        '--json-output',
        installJsonPath,
        installPath,
      ]);
      if (installResult.exitCode != 0) {
        throw StateError('devicectl install failed: ${installResult.stderr}');
      }

      return _readInstallationUrl(installJsonPath, installPath);
    });
    return (path: installPath, installationUrl: installationUrl);
  }

  /// Launch devicectl `--console` for [bundleId], capturing app output.
  Future<Process> _startConsoleLauncher(
    IOSDeviceInfo info,
    String bundleId, {
    required bool debug,
  }) => startHelper('xcrun', [
    'devicectl',
    'device',
    'process',
    'launch',
    '--device',
    info.udid,
    if (debug) '--start-stopped',
    '--console',
    '--environment-variables',
    '{"OS_ACTIVITY_DT_MODE": "enable"}',
    bundleId,
    '--enable-dart-profiling',
    // flutter_tools passes this whenever debugging is enabled, which is
    // debug and profile (`getIOSLaunchArguments`).
    if (buildMode != BuildMode.release) '--enable-checked-mode',
    if (startPaused) '--start-paused',
    // A wireless device is dialed at its own address, so the VM service must
    // not bind to the device's loopback the way it does by default. Matches
    // flutter_tools' `DebuggingOptions.buildLaunchArguments`, which adds this
    // exactly when the connection interface is wireless.
    if (info.transport == IOSDeviceTransport.wireless)
      '--vm-service-host=0.0.0.0',
  ]);

  /// Pump the console launcher into [logs] and wait for its launch banner.
  ///
  /// devicectl sends its own progress banners on one channel and the app's
  /// console output on the other, so both feed the app log stream.
  ///
  /// stderr is deliberately *not* flagged as an error channel: devicectl
  /// routes the app's ordinary console output there, so treating that channel
  /// as errors would mark every `print()` as one.
  Future<AppLogPump> _awaitLaunchBanner(AppLogStream logs) async {
    final consolePump = pumpProcessLines(
      _consoleLauncherProcess!,
      logs,
      stderrIsError: false,
    );

    final launchCompleter = Completer<void>();
    // Cancelled below once the launch resolves: an uncancelled 30s timer keeps
    // the isolate alive for its full duration after the work is done.
    final launchTimeout = Timer(const Duration(seconds: 30), () {
      if (!launchCompleter.isCompleted) launchCompleter.complete();
    });

    // devicectl's own launch banners are progress reporting, not app output.
    bool isDevicectlBanner(String line) =>
        line.contains('Waiting for the application to terminate') ||
        line.contains('Launched application with');

    // Another reader of the same stream, like discovery below.
    final bannerSub = logs.lines.listen((line) {
      if (!launchCompleter.isCompleted && isDevicectlBanner(line.text)) {
        launchCompleter.complete();
      }
    });
    // A launch that dies before ever printing a banner stops the wait
    // immediately rather than sitting out the timeout. This watches devicectl
    // itself rather than the shared log stream, which outlives it.
    unawaited(
      consolePump.done.then((_) {
        if (!launchCompleter.isCompleted) launchCompleter.complete();
      }),
    );

    await launchCompleter.future;
    launchTimeout.cancel();
    await bannerSub.cancel();
    return consolePump;
  }

  /// The app's VM service, found by its mDNS advertisement and made reachable
  /// from here; or null for an AOT app that has none.
  ///
  /// A release app never has one, and flutter_tools does not look. A profile
  /// app has one only if it was built on the profile engine, and then its
  /// Info.plist declares `_dartVmService._tcp`: iOS lets an app advertise only
  /// the Bonjour services it declares, so an app that does not declare it has
  /// nothing this could find. A `-c opt` build without the profile flag is on
  /// the release engine and leaves the declaration out
  /// (`flutter_ios_info_plist`), so without this check a run built that way
  /// would wait out the whole discovery budget.
  Future<Uri?> _findVmService({
    required IOSDeviceInfo info,
    required String bundleId,
    required String installPath,
    required AppLogStream logs,
  }) async {
    switch (buildMode) {
      case BuildMode.debug:
        break;
      case BuildMode.release:
        return null;
      case BuildMode.profile:
        if (!await _declaresVmService(installPath)) {
          logs.add(
            'This build declares no Dart VM service (its Info.plist has no '
            '$_vmServiceBonjourType in NSBonjourServices), so the run has '
            'nothing to attach to. A -c opt build without '
            '--@rules_flutter//flutter:profile runs the release engine, which '
            'serves none.',
          );
          return null;
        }
    }

    // Not by reading the log stream, the way every other platform does. A
    // wirelessly attached device has no console channel at all, and the one a
    // wired device has is `devicectl --console`, which dies with the launch it
    // reports on. The advertisement is the one channel both connections share,
    // and it is already provisioned: the debug/profile Info.plist declares
    // `_dartVmService._tcp` under NSBonjourServices
    // (`flutter/private/runners/ios/DartVmServiceMdns.plist`).
    //
    // Minutes, not seconds — see [applyTimeout] for why a debug launch here is
    // this slow. The budget is a backstop for a run that will never succeed,
    // not an estimate; [onSlow] is what tells the user a long wait is expected
    // rather than a hang. flutter_tools splits the same two concerns, warning
    // at 60s/75s while its mDNS query runs for ten minutes
    // (`ios/devices.dart`).
    final record = await _discoverAdvertisedRecord(info, bundleId, logs);

    switch (info.transport) {
      case IOSDeviceTransport.wired:
        // The advertised port is a device-side port on the device's loopback.
        final iproxy = await startHelper('iproxy', [
          '${record.port}:${record.port}',
          '-u',
          info.udid,
        ]);
        _iproxyProcess = iproxy;

        // iproxy runs for the whole session and reports what it is doing on
        // both channels, so both have to be drained — an unread pipe blocks
        // the writer, and here the writer is the only route to the device.
        final iproxyOutput = AppLogStream();
        iproxyOutput.closeWhen([pumpProcessLines(iproxy, iproxyOutput).done]);

        // Process.start returns at spawn time, before iproxy has bound its
        // local listener. DDS dials this forward immediately after launch()
        // returns; an unbound listener means ECONNREFUSED and the session
        // loses its VM service. Return only once the forward actually accepts.
        try {
          await waitForLocalTcpPort(
            record.port,
            what: 'iproxy forward for the iOS VM service',
          );
        } on StateError catch (e) {
          final said = iproxyOutput
              .read(0)
              .lines
              .map((l) => l.text)
              .where((t) => t.trim().isNotEmpty);
          throw StateError(
            '${e.message}\n'
            'iproxy said: ${said.isEmpty ? '(nothing)' : said.join('; ')}',
          );
        }
        return record.uriFor(host: '127.0.0.1', port: record.port);
      case IOSDeviceTransport.wireless:
        // No cable to forward through. `discover(resolveAddress: true)` throws
        // rather than returning a record without an address, so this is set.
        return record.uriFor(
          host: record.address!.address,
          port: record.port,
        );
    }
  }

  /// Find the app's mDNS advertisement, ending at once when abandoned.
  ///
  /// The minutes-long budget is for an app that never advertises; the run
  /// ending is not that, so the launch-abandonment signal cuts the wait short
  /// with a [VmDiscoveryCancelled] instead of sitting out the budget and
  /// holding the process open past shutdown.
  Future<MdnsVmServiceRecord> _discoverAdvertisedRecord(
    IOSDeviceInfo info,
    String bundleId,
    AppLogStream logs,
  ) async {
    _mdns.abandoned = launchAbortSignal;
    try {
      return await _mdns.discover(
        bundleId: bundleId,
        hostnames: info.hostnames,
        resolveAddress: info.transport == IOSDeviceTransport.wireless,
        timeout: switch (info.transport) {
          IOSDeviceTransport.wired => const Duration(minutes: 5),
          IOSDeviceTransport.wireless => const Duration(minutes: 15),
        },
        // Sized well above a healthy host's launch: the trigger exists to
        // reassure someone on a slow host that the wait is expected, and one
        // sized for a fast host would fire on every ordinary launch. The
        // message says what is outstanding and what is worth checking, and
        // quotes no duration — the cost varies by host by more than an order
        // of magnitude, so any figure here would be wrong for most readers.
        slowAfter: const Duration(seconds: 45),
        onSlow: (elapsed) => logs.add(
          'Still waiting (${elapsed.inSeconds}s) for the app to advertise its '
          'Dart VM service over mDNS — the only channel an iOS device has for '
          'it.${buildMode == BuildMode.debug ? _slowJitStart : ''}\n'
          'If this is the first launch of $bundleId on this device, look at '
          'the phone instead. iOS asks once, per app, before it lets one onto '
          'the local network, and the prompt appears over the app: until it '
          'is answered the advertisement never goes out, and no amount of '
          'waiting here will change that. Settings > Privacy & Security > '
          'Local Network lists the app once it has been asked.',
        ),
      );
    } on MdnsAbandoned {
      throw VmDiscoveryCancelled(name);
    } finally {
      _mdns.abandoned = null;
    }
  }

  /// Why a debug launch can be slow to advertise, for the "still waiting"
  /// note. An AOT app has no JIT trapping to the debugger.
  static const _slowJitStart =
      ' Until then the JIT is still trapping to the debugger for every '
      'executable page it allocates, which is the bulk of an iOS debug '
      'start. If this is taking far longer than your other launches on '
      'this host, check that Xcode has finished copying symbols for this '
      'device: a copy stranded part-way leaves lldb without the on-disk '
      'shared cache, and every one of those traps then costs a read off '
      'the device.';

  /// The Bonjour service type the engine advertises its VM service as.
  static const _vmServiceBonjourType = '_dartVmService._tcp';

  /// Whether the app at [appPath] declares [_vmServiceBonjourType] in its
  /// Info.plist's NSBonjourServices.
  Future<bool> _declaresVmService(String appPath) async {
    final result = await runProcess('plutil', [
      '-extract',
      'NSBonjourServices',
      'json',
      '-o',
      '-',
      p.join(appPath, 'Info.plist'),
    ]);
    // plutil exits 1 when the key is not there: an app with no Bonjour
    // services at all.
    if (result.exitCode != 0) return false;
    final Object? services;
    try {
      services = json.decode('${result.stdout}');
    } on FormatException catch (e) {
      throw StateError(
        'plutil printed NSBonjourServices from $appPath/Info.plist as JSON '
        'this could not read ($e): ${result.stdout}',
      );
    }
    return services is List && services.contains(_vmServiceBonjourType);
  }

  /// Every line lldb has written, live and replayable.
  ///
  /// lldb outlives `launch()` — it holds the debugserver that keeps the app's
  /// JIT alive — so **something must keep reading its pipes for as long as it
  /// runs**. It is also chatty: it forwards the app's own logs and any crash
  /// report. Left unread, its stdout pipe fills, lldb blocks on write, and a
  /// blocked lldb never services the process it is controlling — the app hangs
  /// on device and only springs to life when the dev tool is killed and the
  /// pipes are closed.
  ///
  /// Backed by an [AppLogStream] rather than an ad-hoc broadcast stream: a
  /// broadcast stream drops events while nobody is listening, so lldb output
  /// arriving between two commands — including the pattern the *next* command
  /// is about to wait for — would be discarded. Replay makes the wait
  /// race-free.
  ///
  /// Mirrors flutter_tools' `LLDBLogForwarder`, which exists for these reasons.
  AppLogStream? lldbOutput;

  /// The `installationURL` `devicectl install` reported, from its JSON output.
  ///
  /// Fatal when it is not there, because it is the *only* thing that can name
  /// the launched process afterwards. It is a `file://` URL of the installed
  /// bundle — `file:///private/var/containers/Bundle/Application/<uuid>/
  /// Runner.app/` — and every running process's `executable` under that bundle
  /// is that string plus a suffix. The bundle id appears in neither, so there
  /// is nothing else to match on.
  String _readInstallationUrl(String installJsonPath, String installedPath) {
    final file = File(installJsonPath);
    if (!file.existsSync()) {
      throw StateError(
        'devicectl install reported success for $installedPath on $name but '
        'wrote no JSON to $installJsonPath, so there is no installationURL '
        'to find the launched process by.',
      );
    }
    final contents = file.readAsStringSync();
    final Object? decoded;
    try {
      decoded = json.decode(contents);
    } on FormatException catch (e) {
      throw StateError(
        'devicectl install wrote JSON this could not read ($e), so there is '
        'no installationURL to find the launched process by. It wrote:\n'
        '$contents',
      );
    }
    String? url;
    if (decoded is Map<String, dynamic>) {
      final apps = decoded['result']?['installedApplications'] as List?;
      final first = (apps == null || apps.isEmpty) ? null : apps.first;
      if (first is Map) url = first['installationURL'] as String?;
    }
    if (url == null || url.isEmpty) {
      throw StateError(
        'devicectl install named no installationURL for $installedPath on '
        '$name, so there is nothing to find the launched process by. It '
        'wrote:\n$contents',
      );
    }
    return url;
  }

  /// Kill every helper [launch] started, and forget them.
  ///
  /// Its own method because a launch has two ends, not one: [stop] when it
  /// succeeded, and the rethrow path in [launch] when it did not. A helper a
  /// failed launch leaves running keeps forwarding to a phone nobody is using
  /// and holds its TCP ports, with nothing holding a handle to it.
  ///
  /// Each is killed by the handle this launch holds, never by matching a
  /// command line: `pkill -f iproxy` matches the caller's own arguments as
  /// readily as its target, and would in any case take out a concurrent
  /// session's forward.
  Future<void> _reapLaunchHelpers() async {
    final iproxy = _iproxyProcess;
    if (iproxy != null) {
      await stopProcess('iproxy', iproxy, teardownBound);
      _iproxyProcess = null;
    }
    final consoleLauncher = _consoleLauncherProcess;
    if (consoleLauncher != null) {
      await stopProcess(
        'iOS console launcher',
        consoleLauncher,
        teardownBound,
      );
      _consoleLauncherProcess = null;
    }
    // Killing lldb terminates the debugserver, which kills the app.
    final lldb = lldbProcess;
    if (lldb != null) {
      await stopProcess('lldb', lldb, teardownBound);
      lldbProcess = null;
    }
    await lldbOutput?.close();
    lldbOutput = null;
  }

  @override
  Future<void> stop(AppInstance instance) async {
    lldbStops?.stopping = true;
    // Helpers first: see [_terminateApp] for why the debugger must be gone.
    await _reapLaunchHelpers();
    await _terminateApp();
    await stopProcess('iOS app', instance.process, teardownBound);
    await instance.logs.close();
    await instance.disposeScratchDirs();
  }

  /// End the launched app on the device, if this launch got as far as
  /// finding it.
  ///
  /// Its own step because nothing else ends it: killing lldb detaches
  /// debugserver and the app keeps running, holding its VM service port.
  ///
  /// Only once lldb is gone. While it is attached, debugserver intercepts the
  /// SIGTERM `devicectl` sends and holds the app stopped instead; killing lldb
  /// then resumes it with the signal swallowed. Measured on an iOS 27 iPhone:
  /// terminate-then-detach left the app running every time.
  Future<void> _terminateApp() async {
    final pid = _appPid;
    if (pid == null) return;
    _appPid = null;
    final ProcessResult result;
    try {
      result = await runProcess('xcrun', [
        'devicectl',
        'device',
        'process',
        'terminate',
        '--device',
        addressedUdid,
        '--pid',
        '$pid',
      ]).timeout(teardownBound);
    } on TimeoutException {
      _logger.warning({
        'message': 'ios_app_terminate_timed_out',
        'text':
            'devicectl did not terminate the app (pid $pid) on $name within '
            '${teardownBound.inSeconds}s. It may still be running on the '
            'device.',
        'device': name,
        'pid': pid,
      });
      return;
    }
    // An app that already exited — it crashed, or the user closed it — is
    // the outcome this was after, not a failure.
    if (result.exitCode != 0 &&
        !'${result.stderr}'.contains('No such process')) {
      _logger.warning({
        'message': 'ios_app_terminate_failed',
        'text':
            'devicectl could not terminate the app (pid $pid) on $name, so it '
            'may still be running: ${result.stderr}',
        'device': name,
        'pid': pid,
        'error': '${result.stderr}',
      });
    }
  }

  /// iOS physical device screenshot via pymobiledevice3 DVT service.
  ///
  /// `_flutter.screenshot` does not work on iOS because the Impeller renderer
  /// (always enabled on iOS) does not implement compressed image capture.
  /// Instead, we use pymobiledevice3's DVT screenshot, which captures via
  /// Apple's Developer Tools service (same mechanism as Xcode).
  ///
  /// The screenshot helper is bundled as a Bazel dart_binary driver (it runs
  /// its pymobiledevice3 program through a host python3) and resolved from
  /// runfiles. Requires building via `bazel build //tools/dev_tool:flutter_bazel`.
  ///
  /// Prerequisites: the tunnel daemon, running as root in another terminal.
  /// It is `ios-tunnel` on this same binary — run the built binary itself
  /// under sudo, never `sudo bazel run`, which runs bazel as root and leaves
  /// root-owned files in the output base.
  @override
  Future<void> screenshot(
    AppInstance instance,
    String outputPath, {
    VmServiceClient? vmClient,
    String? window,
  }) async {
    if (vmClient != null) {
      await vmClient.waitForFirstFrame();
    }

    final resolved = resolveRunfileWithManifest(
      'rules_flutter/tools/ios_screenshot/screenshot',
    );
    if (resolved == null) {
      throw StateError(
        'iOS device screenshot requires the bundled screenshot tool.\n'
        'Build via: bazel build //tools/dev_tool:flutter_bazel',
      );
    }

    // The driver reads no runfiles (its program is embedded, its Python is
    // the host's), so unlike the old py_binary it needs no
    // RUNFILES_MANIFEST_FILE forwarded.
    final result = await Process.run(
      resolved.path,
      [
        outputPath,
        '--udid',
        addressedUdid,
      ],
    );
    if (result.exitCode != 0) {
      final err = result.stderr as String;
      if (err.contains('Unable to connect to Tunneld') ||
          err.contains('no devices found')) {
        throw StateError(
          'iOS device screenshot requires a running tunnel daemon.\n'
          'Start it in a separate terminal, as root — it creates a TUN '
          'interface:\n'
          '  sudo ${Platform.resolvedExecutable} ios-tunnel\n'
          'Not `sudo bazel run`: that runs bazel as root and leaves '
          'root-owned files in the output base, which break the builds that '
          'follow.',
        );
      }
      throw StateError('iOS screenshot failed: $err');
    }
  }
}

/// Chrome launch flags matching Flutter's defaults for web dev mode.
///
/// These ensure predictable behavior during development:
/// - No extensions/popups that could interfere with the app
/// - Background timer throttling disabled for accurate async behavior
/// - No first-run/default-browser prompts
const chromeDebugFlags = [
  '--disable-extensions',
  '--disable-popup-blocking',
  '--bwsi',
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-default-apps',
  '--disable-translate',
  '--disable-search-engine-choice-screen',
  '--disable-background-timer-throttling',
  // The rest cut startup work that varies with machine load and buys nothing
  // the run tests. The window, the sandbox and rendering stay exactly as the
  // user runs them: a headed browser that still paints the app.
  //
  // `--disable-dev-shm-usage`: /dev/shm is tiny on many CI and container
  // runners, and a renderer that cannot get shared memory stalls or crashes
  // around the time the browser would announce its debugging port. Backing it
  // with disk under the profile directory instead removes that shape.
  '--disable-dev-shm-usage',
  // `--disable-background-networking`: no component-update, variations-seed
  // or safebrowsing fetches at startup — the cold-start network variance on a
  // shared runner. The app itself is served from localhost, which this does
  // not touch.
  '--disable-background-networking',
  // `--password-store=basic`: no D-Bus secret-service negotiation for a
  // keyring that does not exist under xvfb/CI, which otherwise blocks startup
  // before falling back.
  '--password-store=basic',
];

/// One launched Chrome, owned end to end: the process, the throwaway profile
/// it runs against, its diagnostics, and the choice of which page target the
/// dev tool drives.
///
/// Both web launch paths (DDC module server and static/WASM) go through here,
/// so a flag, a profile cleanup or a timeout is fixed in one place rather than
/// in two copies where a change to one silently misses the other.
class ChromeSession {
  final Process process;

  /// The fresh, empty Chrome profile this launch runs against.
  ///
  /// A throwaway profile is what makes a run reproducible — no extensions, no
  /// restored tabs, no saved sign-ins. The cost is a real directory Chrome
  /// fills with caches, so on success it goes into the instance's
  /// [AppInstance.scratchDirs] and dies with the launch, and a failed launch
  /// deletes it before rethrowing. Left behind they are not inert: a stale
  /// profile belongs to a browser a `--user-data-dir` scan can still find, and
  /// an orphaned window can serve a screenshot that makes a broken run look
  /// fine.
  final Directory userDataDir;

  /// The CDP debugging port announced on Chrome's stderr.
  final int cdpPort;

  /// The localhost URL the launched tab serves the app from — the URL every
  /// page-target lookup matches against.
  final String appUrl;

  /// The app page's CDP WebSocket URL as it was listed when the launch
  /// finished — what the run announces so a client can drive the page itself.
  ///
  /// A snapshot, not a handle anything here keeps using: every consumer in
  /// this tool re-resolves the target per use, because the listing is not a
  /// settled fact (see [resolveCdpPageTarget]).
  final String pageWebSocketDebuggerUrl;

  ChromeSession._({
    required this.process,
    required this.userDataDir,
    required this.cdpPort,
    required this.appUrl,
    required this.pageWebSocketDebuggerUrl,
  });

  /// The command line a launch on [url] with [options] runs.
  ///
  /// Pulled out so the argument order can be asserted without a browser: the
  /// user's own switches go last, immediately before the URL, which is where
  /// upstream puts them and therefore how a switch Chrome resolves by position
  /// behaves. The switches this tool owns are refused at flag-resolution time
  /// rather than being allowed to collide here.
  static List<String> launchArgs(
    String url,
    BrowserLaunchOptions options, {
    required String userDataDir,
  }) => [
    // 0 means "any free port"; either way the port is learned from the
    // browser's own announcement, never assumed.
    '--remote-debugging-port=${options.debugPort ?? 0}',
    ...chromeDebugFlags,
    '--user-data-dir=$userDataDir',
    if (options.headless) ...BrowserLaunchOptions.headlessFlags,
    ...options.scaleFlags,
    ...options.browserFlags,
    url,
  ];

  /// Launch Chrome on [url] and wait until it is observably up: debugging
  /// port announced *and* the tab navigated to the app. A failed launch
  /// leaves nothing behind — no browser, no profile directory.
  ///
  /// [portTimeout] is generous on purpose: a headed first run with a virgin
  /// profile does real initialization work before it announces anything, and
  /// on a loaded shared runner that sometimes takes far longer than the
  /// second-or-two a warm browser needs. A browser that refuses to start
  /// still fails fast — its output ending fails the wait before the timeout.
  static Future<ChromeSession> launch({
    required String url,
    required ProcessStarter startProcess,
    BrowserLaunchOptions options = const BrowserLaunchOptions(),
    String? chromePath,
    ChromeLaunchWaits waits = const (
      portTimeout: Duration(seconds: 60),
      pageTimeout: Duration(seconds: 15),
      pollInterval: Duration(milliseconds: 50),
    ),
  }) async {
    final exe = chromePath ?? findChrome();
    if (exe == null) {
      throw StateError(
        'Chrome not found. Install Chrome or use -d macos for desktop.',
      );
    }
    final userDataDir = await createTempDir('flutter_chrome_');
    // How long a healthy browser takes to announce is the number the port
    // timeout has to clear, so every launch reports it: the next slow start
    // then arrives with measurements instead of a bare "within Ns".
    final launchClock = Stopwatch()..start();
    final Process chrome;
    try {
      chrome = await startProcess(
        exe,
        launchArgs(url, options, userDataDir: userDataDir.path),
      );
    } catch (_) {
      await deleteTempDir(userDataDir);
      rethrow;
    }

    // Chrome's own process output — browser diagnostics, not app output.
    // Kept drained for the browser's lifetime so its pipes can never fill
    // (an unread stderr on a browser this chatty is the likeliest place for
    // a full-pipe stall), and read once for the CDP port announcement.
    // Deliberately *not* surfaced as app output: the app's console lives
    // inside the page, and Chrome's own chatter would bury it.
    final diagnostics = AppLogStream(capacity: 200);
    diagnostics.closeWhen([pumpProcessLines(chrome, diagnostics).done]);

    try {
      final cdpPort = await _discoverCdpPort(
        diagnostics,
        timeout: waits.portTimeout,
        requestedPort: options.debugPort,
      );
      _logger.info({
        'message': 'chrome_port_announced',
        'text':
            'Chrome announced its DevTools debugging port after '
            '${_secondsText(launchClock.elapsed)}.',
        'elapsed_ms': launchClock.elapsedMilliseconds,
        'port': cdpPort,
      });
      // The announcement is the readiness signal, not merely the number, so
      // it is awaited even when the port was dictated. A browser that takes a
      // different one than it was given is a state nothing here can drive:
      // every CDP consumer would dial the port that was asked for.
      if (options.debugPort != null && cdpPort != options.debugPort) {
        chrome.kill();
        await chrome.exitCode;
        await deleteTempDir(userDataDir);
        throw StateError(
          'Chrome was asked for --web-browser-debug-port '
          '${options.debugPort} and announced $cdpPort instead.',
        );
      }
      // The same wait [resolveAppPage] does, done before the session exists
      // so the page it found can be part of it.
      final page = await resolveCdpPageTarget(
        cdpPort,
        appUrl: url,
        timeout: waits.pageTimeout,
        pollInterval: waits.pollInterval,
      );
      final session = ChromeSession._(
        process: chrome,
        userDataDir: userDataDir,
        cdpPort: cdpPort,
        appUrl: url,
        pageWebSocketDebuggerUrl: page,
      );
      final viewport = options.viewport;
      if (viewport != null) await session.applyViewport(viewport);
      return session;
    } catch (_) {
      // A launch with no debugging port or no app page produced nothing
      // usable; don't leave the browser and its throwaway profile running
      // behind the error.
      chrome.kill();
      await chrome.exitCode;
      await deleteTempDir(userDataDir);
      rethrow;
    }
  }

  /// Wait until the launched tab is serving [appUrl] and return its CDP
  /// WebSocket debugger URL.
  ///
  /// Right after launch the tab is still an `about:blank` that has not
  /// navigated, and `/json` can list nothing at all, so this waits rather than
  /// failing on the first look — see [pickCdpPageTarget] for why nothing less
  /// than the app's own page will do. [launch] awaits it before declaring the
  /// browser up: a session whose app page never appeared is a failed launch,
  /// not a running one that every CDP consumer — screenshots, page reloads,
  /// the console — then mis-drives.
  ///
  /// The waiting itself is [resolveCdpPageTarget]'s, not a second copy of it:
  /// the states this rides out at launch are the same ones those consumers hit
  /// mid-session.
  Future<String> resolveAppPage({
    Duration timeout = const Duration(seconds: 15),
    Duration pollInterval = const Duration(milliseconds: 50),
  }) => resolveCdpPageTarget(
    cdpPort,
    appUrl: appUrl,
    timeout: timeout,
    pollInterval: pollInterval,
  );

  /// Lay the app out at [viewport], and prove that it did.
  ///
  /// `Emulation.setDeviceMetricsOverride` is sent once, right after the page
  /// is first resolved, on a connection that then stays open in
  /// [viewportHold] for as long as the browser runs: Chrome 154 scopes the
  /// override to the CDP session that set it and clears it the moment that
  /// socket closes. It does survive the `Page.reload` a web hot restart
  /// performs, so nothing has to be re-applied while the connection lives.
  ///
  /// **Read the result back on a *fresh* connection.** While the setting
  /// client is still attached the page reports metrics it has not settled at,
  /// so a verification folded into that socket to save a round trip would fail
  /// against a browser that is behaving correctly.
  ///
  /// Verified rather than assumed because the failure it guards is invisible:
  /// an override that did not take leaves every later screenshot and layout
  /// measurement quietly describing the wrong viewport.
  Future<void> applyViewport(WebViewport viewport) async {
    viewportHold = await applyViewportOverCdp(
      page: (cdpPort: cdpPort, appUrl: appUrl),
      viewport: viewport,
      asked: '--web-viewport',
      hold: viewportHold,
    );
  }

  /// The CDP connection that set this launch's viewport, kept open for as long
  /// as the browser runs, or null when no viewport was asked for. The caller
  /// that takes over the session owns closing it. See [applyViewportOverCdp]
  /// for why it cannot be closed early.
  CdpPageConnection? viewportHold;
}

/// Web device — serves build output via HTTP and launches Chrome.
class WebDevice extends Device {
  final ProcessStarter _startProcess;

  /// CDP debugging port discovered from Chrome stderr.
  int? _cdpPort;

  /// The localhost URL serving the app (used to find the correct CDP tab).
  String? _appUrl;

  /// The app page's CDP WebSocket URL as listed at launch. See
  /// [ChromeSession.pageWebSocketDebuggerUrl].
  String? _pageWebSocketDebuggerUrl;

  /// The CDP connection holding this run's viewport override open — see
  /// [applyViewportOverCdp]. Null until a viewport is set, and again after
  /// [stop], which closes it.
  CdpPageConnection? _viewportHold;

  /// Takes over [hold], watching it so that losing the viewport is loud: the
  /// override goes with the connection, and nothing else would say so.
  void _holdViewport(CdpPageConnection? hold) {
    // The same connection again, as `app.setViewport` reuses it: already
    // watched.
    if (identical(_viewportHold, hold)) return;
    _viewportHold = hold;
    if (hold == null) return;
    hold.done.then((_) {
      if (_viewportHold != hold) return;
      _viewportHold = null;
      _logger.severe({
        'message': 'web_viewport_lost',
        'text':
            'The browser closed the CDP connection that held the viewport, '
            'and the viewport went with it: screenshots from here on show the '
            'browser window\'s own size. Call app.setViewport to set it '
            'again, or relaunch.',
      });
    });
  }

  /// Module server for DDC dev mode. Set by RunCommand before launch.
  WebModuleServer? _moduleServer;

  /// What this run's web flags resolved to. Set by [RunPlan.resolve], which is
  /// where the flags are read — the device itself is built from a `-d` string,
  /// before there are any.
  ///
  /// The DDC path reads only the browser half here: its server is the module
  /// server, which the assembler builds from `server` of this same value.
  /// Both paths are therefore configured by one object, which is what stops a
  /// web flag from meaning something on one and nothing on the other.
  WebOptions? webOptions;

  /// Forwards the page's console when there is no DWDS to do it (WASM and
  /// production JS builds). Null in DDC dev mode, where `run_command` wires
  /// the DWDS VM service instead — see the one-source-per-platform note in the
  /// library docs.
  CdpConsoleClient? _consoleClient;

  WebDevice({ProcessStarter? startProcess})
    : _startProcess = startProcess ?? Process.start;

  @override
  String get name => 'Chrome';

  @override
  Future<List<HostTool>> requiredHostTools() async => [chromeTool()];

  /// Set the DDC module server for dev mode (hot restart support).
  void setModuleServer(WebModuleServer server) => _moduleServer = server;

  /// The CDP debugging port, if discovered.
  int? get cdpPort => _cdpPort;

  /// The localhost URL serving the app, if launched.
  String? get appUrl => _appUrl;

  /// The app page's CDP WebSocket URL as it was listed when the browser came
  /// up, if launched. Announced for clients that drive Chrome themselves;
  /// nothing in this tool dials it, since every consumer here re-resolves the
  /// page per use.
  String? get pageWebSocketDebuggerUrl => _pageWebSocketDebuggerUrl;

  @override
  CompilerConfig? createCompilerConfig(
    ToolchainPaths toolchain, [
    CompilerConfigInputs? inputs,
  ]) {
    // Web builds its own filesystem roots (synthetic entrypoint dir + workspace)
    // in run_command; the native roots/scheme args are not used here. The
    // registrant URI is ignored too — the web synthetic main calls
    // registerPlugins() directly and re-runs on page-reload restart.
    final webToolchain = inputs?.webToolchain;
    if (webToolchain == null) return null;
    return WebCompilerConfig(
      webToolchain: webToolchain,
      dartDefines: inputs?.dartDefines ?? const [],
      enableExperiments: inputs?.enableExperiments ?? const [],
    );
  }

  /// Refused, rather than answered.
  ///
  /// [Device.createReloadStrategy] is asked by `NativePipelineAssembler` and
  /// by nothing else, and that assembler is only built for a native run — so
  /// this is unreachable. What it must not do is *inherit*: the base answer is
  /// [VmServiceReloadStrategy], and a browser run given the native strategy
  /// would send every reload looking for a VM service the browser does not
  /// have and report its absence as the fault. That is what
  /// `ReloadPipeline.strategy` is non-defaulting to prevent.
  ///
  /// A browser's strategy is built by the assembler that owns the run's shape:
  /// `WebPipelineAssembler` (DWDS, from the module server it just started) or
  /// `WasmPipelineAssembler` (CDP, from the port Chrome announced). Neither is
  /// derivable from a device that has not been told which run it is in.
  @override
  ReloadStrategy createReloadStrategy() {
    throw StateError(
      'A Chrome run does not get its reload strategy from the device: '
      'WebPipelineAssembler builds the DWDS one from the module server, and '
      'WasmPipelineAssembler the CDP one from the browser\'s debugging '
      'port. Reaching here means a native assembler was pointed at a web '
      'device.',
    );
  }

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    if (_moduleServer != null) {
      return _launchWithModuleServer(onLog);
    }
    return _launchStaticServer(appPath, onLog);
  }

  /// What this run's web flags resolved to, or a failure naming what was
  /// never wired.
  ///
  /// Not a default: a `WebDevice` launching without them would run the browser
  /// with none of the flags the user typed, which is the exact silence these
  /// options exist to prevent.
  WebOptions get _webOptions {
    final options = webOptions;
    if (options == null) {
      throw StateError(
        'This WebDevice was never told how to serve or how to launch a '
        'browser (RunPlan.resolve sets webOptions). Without it none of the '
        'web flags would apply to this run.',
      );
    }
    return options;
  }

  /// Launch using DDC module server (dev mode with hot restart).
  Future<AppInstance> _launchWithModuleServer(AppLogListener? onLog) async {
    final options = _webOptions;
    // `--web-launch-url` if given, the server's own URL otherwise — and
    // checked against the server that actually bound, which is the first
    // moment its port is known.
    final url = options.launchUrlFor(_moduleServer!.uri!).toString();
    _appUrl = url;

    final session = await ChromeSession.launch(
      url: url,
      startProcess: _startProcess,
      options: options.browser,
    );
    _cdpPort = session.cdpPort;
    _holdViewport(session.viewportHold);
    _pageWebSocketDebuggerUrl = session.pageWebSocketDebuggerUrl;

    // No CDP console client here: DDC mode gets the app's output from the DWDS
    // VM service, and running both would print every line twice.
    return AppInstance(
      process: session.process,
      vmServiceUri: null,
      // The app's own output has its own source — DWDS, wired by the caller —
      // so it does not close with the browser process.
      logs: _newAppLogs(onLog),
      scratchDirs: [session.userDataDir],
    );
  }

  /// Launch using static file server (production/WASM mode).
  Future<AppInstance> _launchStaticServer(
    String appPath,
    AppLogListener? onLog,
  ) async {
    final options = _webOptions;
    final staticServer = StaticWebServer(
      rootPath: appPath,
      options: options.server,
    );
    final serverBase = await staticServer.start();

    final String url;
    final ChromeSession session;
    try {
      url = _appUrl = options.launchUrlFor(serverBase).toString();
      session = await ChromeSession.launch(
        url: url,
        startProcess: _startProcess,
        options: options.browser,
      );
    } catch (_) {
      // The session cleans up after its own failures; this path additionally
      // owns the static file server.
      await staticServer.stop();
      rethrow;
    }
    _cdpPort = session.cdpPort;
    _holdViewport(session.viewportHold);
    _pageWebSocketDebuggerUrl = session.pageWebSocketDebuggerUrl;
    final logs = _newAppLogs(onLog);

    // No DWDS on this path (WASM / production JS), so CDP is the only source
    // of the app's console output.
    _consoleClient = CdpConsoleClient(
      cdpPort: _cdpPort!,
      appUrl: _appUrl,
      logs: logs,
      // Its own default sink writes straight to stderr, which a `--machine`
      // client reading JSON lines cannot parse. The give-up warning already
      // says what is lost; this only gives it a level and an envelope.
      warn: (message) => _logger.warning({
        'message': 'browser_console_forwarding_stopped',
        'text': message,
      }),
    );
    try {
      await _consoleClient!.start();
    } catch (e) {
      // Console forwarding is not worth failing a launch over, but a silent
      // loss of all app output would be worse than the noise.
      _logger.warning({
        'message': 'browser_console_attach_failed',
        'text':
            'Could not attach to the browser console ($e). The app runs, '
            'but nothing it prints will appear in this run.',
        'error': '$e',
      });
      _consoleClient = null;
    }

    return AppInstance(
      process: session.process,
      vmServiceUri: null,
      server: staticServer.server,
      logs: logs,
      scratchDirs: [session.userDataDir],
    );
  }

  @override
  Future<void> stop(AppInstance instance) async {
    // Unbounded on purpose. A client-side `WebSocket.close()` returns the
    // *outbound* sink's future and never waits for the peer's answering close
    // frame, so neither a peer that never answers nor one wedged so hard it
    // reads nothing can hold it. The one shape that does hang is a wedged peer
    // with a full send buffer, and this client writes a single small
    // `Runtime.enable` per connection, so it cannot build that backlog. The
    // SDK's own 5s close timer does NOT rescue that shape, so this decision
    // expires if the client ever grows chatty outbound traffic.
    await _consoleClient?.close();
    _consoleClient = null;
    // Taken off first, so closing it is not reported as the viewport lost.
    final viewportHold = _viewportHold;
    _viewportHold = null;
    await viewportHold?.close();
    final moduleServer = _moduleServer;
    if (moduleServer != null) {
      // dwds is third-party and its `stop()` reaches peer-dependent awaits —
      // `DebugService.close()` waits on a DDS shutdown, `DwdsVmClient.close()`
      // on a VM-service client dispose. This sits *before* the kill, so an
      // unbounded wait here means the browser is never even asked to exit.
      await boundedTeardownStep(
        'the web module server to shut down',
        moduleServer.stop(),
        teardownBound,
      );
    }
    // Unbounded: `HttpServer.close(force: false)` returns promptly against an
    // idle keep-alive connection, a held streaming response and an open
    // WebSocket upgrade alike.
    await instance.server?.close();
    // Before the profile goes: a browser that is still shutting down is still
    // writing its caches, and deleting the tree under it leaves a half-removed
    // directory and an error naming a file nobody asked about.
    await stopProcess('browser', instance.process, teardownBound);
    await instance.logs.close();
    await instance.disposeScratchDirs();
  }

  @override
  Future<void> screenshot(
    AppInstance instance,
    String outputPath, {
    VmServiceClient? vmClient,
    String? window,
  }) async {
    if (_cdpPort == null) {
      throw StateError('CDP port not discovered — cannot capture screenshot');
    }
    await _cdpScreenshot(_cdpPort!, outputPath, appUrl: _appUrl);
  }

  /// Press [chord] in the app's page — `app.pressKey`'s browser route. See
  /// [pressKeyOverCdp].
  Future<BrowserKeyPress> pressKey(
    KeyChord chord, {
    required bool macCommands,
  }) async {
    final port = _cdpPort;
    final url = _appUrl;
    if (port == null || url == null) {
      throw StateError(
        'This web run has no browser to press keys in yet: its DevTools '
        'port has not been discovered, so the page cannot be reached.',
      );
    }
    return pressKeyOverCdp(
      cdpPort: port,
      appUrl: url,
      chord: chord,
      macCommands: macCommands,
    );
  }

  /// Re-lay the running app out at [viewport] — what `app.setViewport` does.
  ///
  /// The same override `--web-viewport` applies at launch, sent again to the
  /// page that is already up, so a caller sweeping form factors does not have
  /// to relaunch between them.
  Future<void> setViewport(WebViewport viewport) async {
    final port = _cdpPort;
    final url = _appUrl;
    if (port == null || url == null) {
      throw StateError(
        'This web run has no browser to resize yet: its CDP port has not been '
        'discovered, so the page cannot be reached.',
      );
    }
    _holdViewport(
      await applyViewportOverCdp(
        page: (cdpPort: port, appUrl: url),
        viewport: viewport,
        asked: 'app.setViewport',
        hold: _viewportHold,
      ),
    );
  }
}

/// Chrome's announcement of its debugging port, printed to stderr when
/// launched with `--remote-debugging-port=0`:
/// `DevTools listening on ws://127.0.0.1:PORT/devtools/browser/...`
final cdpPortPattern = RegExp(r'DevTools listening on ws://\S+?:(\d+)/');

/// Discover the CDP debugging port from Chrome's own diagnostic output.
///
/// Reads [browserDiagnostics] rather than subscribing to Chrome's pipes
/// directly, so finding the port doesn't stop those pipes being drained — an
/// unread stderr on a browser as chatty as Chrome is the likeliest place for a
/// full-pipe stall.
///
/// Throws a [StateError] rather than returning null when the port never
/// arrives. It is not optional equipment: DDC dev mode dials CDP to give DWDS
/// its Chrome connection, and every web path uses it for screenshots and page
/// reloads, so accepting null here would buy a run with none of that and no
/// message. Upstream tool-exits in the same situation (`chrome.dart`'s "Unable to
/// connect to Chrome debug port"). The two causes are reported separately
/// because they call for different fixes.
///
/// The timeout error quotes how long the wait ran and what the browser
/// printed: a browser still working through a slow first run is otherwise
/// indistinguishable from one that was never going to announce.
Future<int> _discoverCdpPort(
  AppLogStream browserDiagnostics, {
  Duration timeout = const Duration(seconds: 60),
  int? requestedPort,
}) async {
  // Measured, not assumed: the timeout error below quotes how long the wait
  // actually ran, so a failure says whether the browser was moments or an
  // eternity from announcing.
  final waited = Stopwatch()..start();
  final completer = Completer<int>();
  final timer = Timer(timeout, () {
    if (!completer.isCompleted) {
      completer.completeError(
        StateError(
          'Chrome did not announce a DevTools debugging port within '
          '${timeout.inSeconds}s of launch '
          '(waited ${_secondsText(waited.elapsed)}). '
          'Without it there is no debugging '
          'connection: no DWDS VM service, no hot restart, no screenshots.'
          // A dictated port is the one thing about this launch that can be
          // wrong before Chrome even starts, and Chrome says nothing when it
          // cannot take one.
          '${requestedPort == null ? '' : ' --web-browser-debug-port '
                    '$requestedPort may already be in use.'}'
          // Reaching the timeout means the browser's output never ended: had
          // it exited, the stream closing would have failed this wait first.
          // So the browser was still starting up, and what it printed is
          // where the reason lives.
          ' Its output had not ended; the browser was still starting up. '
          '${_browserLastWords(browserDiagnostics, ended: false)}',
        ),
      );
    }
  });

  final sub = browserDiagnostics.lines.listen(
    (line) {
      if (completer.isCompleted) return;
      final match = cdpPortPattern.firstMatch(line.text);
      if (match != null) completer.complete(int.parse(match.group(1)!));
    },
    onDone: () {
      // Chrome's output is this stream's only source, so it ending means the
      // browser is gone — a different failure from a browser that is up and
      // silent, and worth saying so.
      //
      // With Chrome's own last words attached, because on its own that
      // sentence names a symptom and no cause. The causes that actually occur
      // are all things Chrome says on the way out — a sandbox it will not run
      // under, a profile directory it cannot write, a missing shared library —
      // and on a CI runner the alternative to quoting them here is reproducing
      // the failure somewhere the log can be reached.
      if (!completer.isCompleted) {
        completer.completeError(
          StateError(
            'Chrome exited before announcing a DevTools debugging port. '
            '${_browserLastWords(browserDiagnostics)}',
          ),
        );
      }
    },
  );

  try {
    return await completer.future;
  } finally {
    timer.cancel();
    await sub.cancel();
  }
}

/// The tail of what the browser printed, phrased for the end of an error.
///
/// Read back off [AppLogStream] rather than accumulated by the listener above:
/// the buffer survives the stream closing, so the lines are still there at the
/// moment the launch is known to have failed, and there is no second copy of
/// the same output to keep in step with the first.
///
/// Says so explicitly when there is nothing to quote. "Chrome exited and
/// printed nothing" is a real and different diagnosis from "Chrome exited" —
/// it rules out every cause that announces itself, and says the search belongs
/// somewhere other than the browser's output. An empty tail rendered as
/// nothing at all would instead read as if the quoting had been forgotten.
///
/// [ended] selects the phrasing: the browser that exited printed "on the way
/// out", while one still starting up when the wait ran out has printed
/// "so far".
String _browserLastWords(
  AppLogStream browserDiagnostics, {
  int lines = 20,
  bool ended = true,
}) {
  final tail = browserDiagnostics.read(-lines).lines;
  if (tail.isEmpty) {
    return ended
        ? 'It printed nothing at all on the way out, so its own output does '
              'not hold the reason.'
        : 'It had printed nothing at all so far, so its own output does not '
              'yet hold a reason.';
  }
  return 'It last said:\n${tail.map((l) => '  ${l.text}').join('\n')}';
}

/// Seconds with one decimal, for launch timings in errors and logs.
String _secondsText(Duration d) =>
    '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';

/// Lay the app's page out at [viewport], and prove that it did.
///
/// Shared by the two things that set a viewport: `--web-viewport` at launch
/// ([ChromeSession.applyViewport]) and the `app.setViewport` command
/// mid-session ([WebDevice.setViewport]). [asked] names whichever one it was,
/// so the failure says which input was not honoured.
///
/// `Emulation.setDeviceMetricsOverride` is sent on one connection and **that
/// connection is returned, still open, for the caller to keep for as long as
/// the viewport should hold.** Chrome 154 ties the override to the CDP session
/// that set it: when the socket closes the page goes back to the window's own
/// size, and every screenshot and layout read after that describes a viewport
/// nobody asked for. (Earlier Chromes kept it after the socket closed, which is
/// what this used to rely on.) The override does survive the `Page.reload` a
/// web hot restart performs.
///
/// Pass the connection back as [hold] to change the viewport on it, so a
/// sweep across form factors replaces the override rather than stacking
/// sessions; a [hold] that has closed is replaced by a fresh one. On failure a
/// connection this call opened is closed again, and the caller's own is left
/// as it was.
///
/// **The read-back needs its own connection.** While the setting client is
/// still attached the page reports metrics it has not settled at, so folding
/// the check into that socket to save a round trip would fail against a
/// browser behaving correctly — the read below deliberately opens its own,
/// and it sees the override because the held one is still open. It is
/// repeated until the page reports the size or [settleTimeout] runs out.
///
/// Verified rather than assumed because the failure it guards is invisible: an
/// override that did not take leaves every later screenshot and layout
/// measurement quietly describing the wrong viewport.
Future<CdpPageConnection> applyViewportOverCdp({
  required CdpPageTarget page,
  required WebViewport viewport,
  required String asked,
  CdpPageConnection? hold,
  Duration settleTimeout = const Duration(seconds: 15),
  Duration pollInterval = const Duration(milliseconds: 200),
}) async {
  final reuse = hold != null && !hold.isClosed;
  final connection = reuse
      ? hold
      : await CdpPageConnection.open(page.cdpPort, appUrl: page.appUrl);
  try {
    await connection.send('Emulation.setDeviceMetricsOverride', {
      'width': viewport.width,
      'height': viewport.height,
      // 0 means "keep the browser's own ratio" — see WebViewport.
      'deviceScaleFactor': viewport.deviceScaleFactor ?? 0,
      // Not a mobile emulation: Chrome lays a mobile page out at its 980px
      // default until the page declares a viewport, and a Flutter app does
      // that only once its engine has started — after the launch that
      // verifies this. Without it the layout viewport is the size asked for
      // from the first read, whatever the page has or has not run.
      'mobile': false,
    });
    // Polled, because a read straight after the override can still describe
    // the page as it was laid out a moment ago.
    final stopwatch = Stopwatch()..start();
    Object? width;
    Object? height;
    Object? ratio;
    while (true) {
      final got = await _sendCdpToPage(
        page.cdpPort,
        page.appUrl,
        'Runtime.evaluate',
        {
          'expression':
              '({w: window.innerWidth, h: window.innerHeight, '
              'r: window.devicePixelRatio})',
          'returnByValue': true,
        },
      );
      final value = got['result']?['result']?['value'];
      width = value is Map ? value['w'] : null;
      height = value is Map ? value['h'] : null;
      ratio = value is Map ? value['r'] : '?';
      if (width == viewport.width && height == viewport.height) break;
      if (stopwatch.elapsed >= settleTimeout) {
        throw StateError(
          'The browser did not take the viewport $asked asked for. Wanted '
          '${viewport.width}x${viewport.height}, and after '
          '${settleTimeout.inSeconds}s the page still reports '
          '${width}x$height (devicePixelRatio $ratio).\n'
          'Every screenshot and every layout measurement taken from here on '
          'would describe a viewport nobody asked for.',
        );
      }
      await Future<void>.delayed(pollInterval);
    }
  } catch (_) {
    if (!reuse) await connection.close();
    rethrow;
  }
  return connection;
}

/// Send one CDP command to the page serving [appUrl] and return its reply.
///
/// A connection per command, and the page target re-resolved each time rather
/// than cached, because the target listing is not a settled fact — see
/// [pickCdpPageTarget].
Future<Map<String, dynamic>> _sendCdpToPage(
  int cdpPort,
  String appUrl,
  String method,
  Map<String, dynamic> params,
) async {
  final page = await CdpPageConnection.open(cdpPort, appUrl: appUrl);
  try {
    return await page.send(method, params);
  } finally {
    await page.close();
  }
}

/// One connection to the app page's CDP endpoint, for commands that have to
/// arrive in order on the same session — a key chord's downs and ups.
///
/// The target is resolved when the connection opens and not after, so hold
/// one only for a single operation: see [pickCdpPageTarget].
class CdpPageConnection {
  final WebSocket _ws;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  var _nextId = 1;
  Object? _closedBy;
  final _done = Completer<void>();

  /// Whether the socket has closed, from either end.
  bool get isClosed => _closedBy != null;

  /// Completes when the socket closes, from either end — what a holder of a
  /// long-lived connection waits on to learn it lost the session.
  Future<void> get done => _done.future;

  CdpPageConnection._(this._ws) {
    _ws.listen(
      (data) {
        final msg = json.decode(data as String) as Map<String, dynamic>;
        final id = msg['id'];
        if (id is int) _pending.remove(id)?.complete(msg);
      },
      // A page that navigates away or a browser that exits closes the socket;
      // every command still waiting would otherwise spend its whole timeout
      // to report the same thing.
      onDone: () => _fail(StateError('the page\'s CDP connection closed')),
      onError: _fail,
    );
  }

  void _fail(Object error) {
    _closedBy ??= error;
    for (final c in _pending.values) {
      c.completeError(error);
    }
    _pending.clear();
    if (!_done.isCompleted) _done.complete();
  }

  /// Connect to the page serving [appUrl] on [cdpPort].
  static Future<CdpPageConnection> open(
    int cdpPort, {
    required String appUrl,
  }) async => CdpPageConnection._(
    await WebSocket.connect(
      await resolveCdpPageTarget(cdpPort, appUrl: appUrl),
    ),
  );

  /// Send [method] and return the whole reply; a CDP error is a [StateError]
  /// naming the method.
  ///
  /// Bounded: a browser that stops answering would otherwise hold the
  /// command pool's only slot for the rest of the run.
  Future<Map<String, dynamic>> send(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_closedBy case final error?) throw error;
    final id = _nextId++;
    final reply = _pending[id] = Completer<Map<String, dynamic>>();
    _ws.add(json.encode({'id': id, 'method': method, 'params': params}));
    final response = await reply.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw StateError(
          'CDP $method did not answer within ${timeout.inSeconds}s',
        );
      },
    );
    final error = response['error'];
    if (error != null) throw StateError('CDP $method failed: $error');
    return response;
  }

  Future<void> close() {
    _fail(StateError('the page\'s CDP connection was closed here'));
    return _ws.close();
  }
}

/// What pressing a key chord in the browser did: the events it sent, and the
/// two facts about the page that decide what they could reach.
class BrowserKeyPress {
  /// The `Input.dispatchKeyEvent` parameters, in the order sent.
  final List<Map<String, Object>> sent;

  /// What had the browser's focus when the keys went in, as the path of tag
  /// names through any shadow roots, e.g. `flutter-view > input`.
  final String focus;

  /// Whether that element takes typed text: an `<input>`, a `<textarea>` or
  /// an editable element. Flutter's web engine gives its focused text field
  /// a real one, so this is what says typing will land.
  final bool focusIsEditable;

  /// Whether the page was visible. A hidden page draws no frames, so what the
  /// keys changed does not repaint until it is shown.
  final bool pageVisible;

  const BrowserKeyPress({
    required this.sent,
    required this.focus,
    required this.focusIsEditable,
    required this.pageVisible,
  });
}

/// Page state [pressKeyOverCdp] reads before dispatching: the focused element
/// through shadow roots, whether it is editable, and the page's visibility.
const _focusProbe = '''
(() => {
  let e = document.activeElement;
  const path = [];
  let editable = false;
  while (e) {
    path.push(e.tagName.toLowerCase());
    editable = e.tagName === 'INPUT' || e.tagName === 'TEXTAREA' ||
        e.isContentEditable;
    e = e.shadowRoot ? e.shadowRoot.activeElement : null;
  }
  return {
    focus: path.join(' > ') || 'nothing',
    editable,
    visible: document.visibilityState === 'visible',
  };
})()''';

/// Press [chord] in the page serving [appUrl]: real, trusted key events,
/// dispatched by the browser to whatever has its focus.
///
/// [macCommands] attaches the Cocoa editing commands a Mac browser would —
/// see [macEditingCommandsFor], and the measurement there: without them
/// Control+K deletes nothing.
///
/// Everything goes over one connection, in order, and the focus and
/// visibility are read on it first. Coordinates are never involved: the
/// browser routes a key to the focused element, which is what makes this safe
/// to run against a page whose size changed since launch.
Future<BrowserKeyPress> pressKeyOverCdp({
  required int cdpPort,
  required String appUrl,
  required KeyChord chord,
  required bool macCommands,
}) async {
  final page = await CdpPageConnection.open(cdpPort, appUrl: appUrl);
  try {
    final probe = await page.send('Runtime.evaluate', {
      'expression': _focusProbe,
      'returnByValue': true,
    });
    final state = probe['result']?['result']?['value'];
    final sent = <Map<String, Object>>[];
    for (final stroke in chord.strokes) {
      final params = stroke.cdpParams(
        macCommands: macCommands ? macEditingCommandsFor(stroke) : const [],
      );
      await page.send('Input.dispatchKeyEvent', params);
      sent.add(params);
    }
    return BrowserKeyPress(
      sent: sent,
      focus: state is Map ? '${state['focus']}' : 'unknown',
      focusIsEditable: state is Map && state['editable'] == true,
      pageVisible: state is! Map || state['visible'] != false,
    );
  } finally {
    await page.close();
  }
}

/// Capture a screenshot via Chrome DevTools Protocol.
///
/// Connects to `http://127.0.0.1:<port>/json` to discover the app tab's
/// WebSocket URL, then sends `Page.captureScreenshot` over CDP.
/// If [appUrl] is provided, selects the tab matching that URL.
Future<void> _cdpScreenshot(
  int cdpPort,
  String outputPath, {
  String? appUrl,
}) async {
  // Same target selection every CDP consumer uses — see `cdp_console.dart`.
  final wsUrl = await resolveCdpPageTarget(cdpPort, appUrl: appUrl);

  // Connect WebSocket and send Page.captureScreenshot.
  final ws = await WebSocket.connect(wsUrl);
  try {
    final responseCompleter = Completer<Map<String, dynamic>>();

    ws.listen((data) {
      final msg = json.decode(data as String) as Map<String, dynamic>;
      if (msg['id'] == 1 && !responseCompleter.isCompleted) {
        responseCompleter.complete(msg);
      }
    });

    ws.add(
      json.encode({
        'id': 1,
        'method': 'Page.captureScreenshot',
        'params': {'format': 'png'},
      }),
    );

    final response = await responseCompleter.future.timeout(
      const Duration(seconds: 10),
    );

    final result = response['result'] as Map<String, dynamic>?;
    if (result == null || result['data'] == null) {
      throw StateError('CDP screenshot returned no data');
    }

    // Decode base64 PNG and write to file.
    final bytes = base64.decode(result['data'] as String);
    await File(outputPath).writeAsBytes(bytes);
  } finally {
    await ws.close();
  }
}

/// Find the Chrome executable path, or null if not found.
///
/// One definition of where Chrome lives, shared with the preflight that reports
/// its absence — see [chromeTool].
String? findChrome() => chromeTool().find();
