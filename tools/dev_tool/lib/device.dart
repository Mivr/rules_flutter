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

import 'app_log.dart';
import 'build_mode.dart';
import 'compiler_config.dart';
import 'host_tools.dart';
import 'logging.dart';
import 'mdns_vm_service_discovery.dart';
import 'native_patch_delivery.dart';
import 'reload_strategy.dart';
import 'temp_dir.dart';
import 'toolchain_info.dart';
import 'vm_service_client.dart';
import 'vm_service_discovery.dart';

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

  /// Takes ownership of [dir] for the launch in flight: [handOver] passes it
  /// to the [AppInstance] being returned, [release] deletes it.
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
    beginLaunch();
    try {
      final instance = await start();
      endLaunch();
      return instance;
    } catch (_) {
      endLaunch();
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
  void beginLaunch() {
    throwIfLaunchAbandoned();
    _launchCancel = Completer<void>();
  }

  /// End a launch: disarm the abandonment signal, keeping the refusal.
  ///
  /// The flag stays set after a launch that [abandonLaunch] interrupted — the
  /// device is done launching — while the completer goes, so a cancelled wait
  /// cannot resolve a later one.
  void endLaunch() {
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
  final logs = newAppLogs(onLog);
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
AppLogStream newAppLogs(AppLogListener? onLog) {
  final logs = AppLogStream();
  if (onLog != null) logs.lines.listen(onLog);
  return logs;
}
