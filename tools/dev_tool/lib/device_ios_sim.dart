/// iOS Simulator device, over `xcrun simctl`.
///
/// [IOSSimulatorDevice] boots the simulator, installs the app and tails a
/// dedicated `simctl spawn log stream` as the app's only log source.
/// [iosSimulatorLogPredicate] selects the app's own lines out of the unified
/// log and [parseUnifiedLoggingLine] extracts the message from one JSON line.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_log.dart';
import 'device.dart';
import 'ios_sim_log_fallback.dart';
import 'native_patch_delivery.dart';
import 'vm_service_client.dart';
import 'vm_service_discovery.dart';

/// iOS Simulator device (via xcrun simctl).
class IOSSimulatorDevice extends Device {
  /// The simulator every `simctl` command of this device addresses.
  String get udid => _udid;
  final String _udid;

  final String? _bundleId;
  final ProcessRunSync _runProcess;
  final ProcessStarter _startProcess;

  /// The bundle the last launch started — [_bundleId] when one was named,
  /// otherwise the one read out of the app's Info.plist.
  ///
  /// [stop] terminates this. Reading [_bundleId] there instead skipped the
  /// terminate for the usual device, which names none, and the app outlived
  /// the run.
  String? _launchedBundleId;

  IOSSimulatorDevice({
    required String udid,
    String? bundleId,
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
  }) : _udid = udid,
       _bundleId = bundleId,
       _runProcess = runProcess ?? Process.run,
       _startProcess = startProcess ?? Process.start;

  /// Create a device targeting the first booted simulator.
  factory IOSSimulatorDevice.booted({
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
  }) {
    final run = runProcess ?? Process.run;
    return _IOSSimulatorDeviceBooted(
      runProcess: run,
      startProcess: startProcess ?? Process.start,
    );
  }

  @override
  NativePatchDelivery? get nativePatchDelivery =>
      IOSSimulatorPatchDelivery(run: _runProcess);

  @override
  String get name => 'iOS Simulator ($udid)';

  @override
  List<String> get buildArgs => const ['--ios_multi_cpus=sim_arm64'];

  final _scratch = LaunchScratch();

  /// The `log stream` helpers a launch in flight has started, until the launch
  /// hands them to its [AppInstance].
  final _launchHelpers = <Process>[];

  /// Whether a launch in flight has started the app: `simctl launch` answered
  /// success but the launch has not returned yet. A launch abandoned in that
  /// window terminates the app it started, so no shutdown leaves one running.
  bool _inFlightOwnsApp = false;

  /// How often the persisted-log fallback re-reads `log show` while discovery
  /// waits.
  ///
  /// Settable so tests can drive the fallback without real-time sleeps.
  Duration simLogFallbackPollInterval = defaultSimLogFallbackPollInterval;

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) =>
      trackedLaunch(() => _launch(appPath, onLog: onLog));

  /// Undo a launch that did not return: the app it started, if it started one,
  /// then its log helpers and its unpacked app.
  /// `simctl install` copies the app, so nothing runs out of the unpacked one.
  Future<void> releaseLaunch() async {
    // The launch may have put an app on the simulator and then been abandoned
    // before it returned: terminate what it started first.
    if (_inFlightOwnsApp) {
      _inFlightOwnsApp = false;
      final bundleId = _launchedBundleId ?? _bundleId;
      if (bundleId != null) {
        await _runProcess('xcrun', ['simctl', 'terminate', udid, bundleId]);
      }
    }
    final helpers = [..._launchHelpers];
    _launchHelpers.clear();
    await Future.wait(
      helpers.map((h) => stopProcess('iOS Simulator log', h, teardownBound)),
    );
    await _scratch.release();
  }

  Future<Process> _startHelper(String executable, List<String> args) async {
    final process = await _startProcess(executable, args);
    _launchHelpers.add(process);
    return process;
  }

  /// Whether the simulator app with host pid [pid] is still running.
  ///
  /// Simulator apps run as host processes, so `ps` sees them. The probe for
  /// [watchHostPid]: injected there rather than read inline so tests can
  /// stand in for it.
  Future<bool> _isSimPidAlive(int pid) async {
    final result = await _runProcess('ps', ['-p', '$pid']);
    return result.exitCode == 0;
  }

  /// Discover the VM-service URI from the simulator's discovery stream.
  ///
  /// The pid watch starts only here — never in a build mode that serves no VM
  /// service — and stops when the wait ends, whatever the outcome, so no `ps`
  /// probe outlives discovery ([watchHostPid]'s `stop`). The pid `simctl
  /// launch` reports is the liveness signal: while it lives, the wait keeps
  /// going. No pid (an unparsed format) means no signal, and the wait then
  /// relies on the bound alone, as on Android.
  ///
  /// The live stream is the fast path, but not the only one: it can attach
  /// after the app has already announced, so the persisted log is polled for
  /// this launch's pid beside it ([SimLogFallback]) and whichever source sees
  /// the announcement first wins. Both feed one [AppLogStream] read by one
  /// [waitForVmServiceUri], so the progress lines, the fail-at-once on app
  /// exit, and the bound note behave exactly as with the stream alone. No pid
  /// means no fallback — and a log line saying so — because there is nothing
  /// to hunt the persisted log for.
  Future<VmServiceDiscovery> _discoverSimVmService(
    Process discoveryLog,
    String launchStdout, {
    required DateTime launchStarted,
  }) async {
    final config = discoveryConfig();
    final stopWatch = Completer<void>();
    final logs = AppLogStream();
    final pump = pumpProcessLines(discoveryLog, logs);
    final simPid = parseSimctlLaunchPid(launchStdout);
    final fallback = simPid == null
        ? null
        : SimLogFallback(
            query: (udid: udid, pid: simPid, since: launchStarted),
            runProcess: _runProcess,
            pollInterval: simLogFallbackPollInterval,
            clock: config.clock,
            logger: activeDiscoveryLogger(),
          );
    if (fallback == null) {
      activeDiscoveryLogger().warning({
        'message': 'sim_log_fallback_off',
        'text':
            'The iOS simulator persisted-log fallback is off: `simctl '
            'launch` reported no pid, so discovery reads the live stream '
            'alone. Launch output was: "$launchStdout".',
        'launch_stdout': launchStdout,
      });
    }
    final feeding = fallback?.feedAnnouncements(logs, stop: stopWatch.future);
    // The helper is this stream's live source, so a helper that dies takes
    // the stream with it; the fallback ends with the wait either way, so it
    // joins the close set rather than holding the stream open past discovery.
    logs.closeWhen([pump.done, if (feeding != null) feeding]);
    try {
      return await waitForVmServiceUri(
        logs: logs,
        deviceName: name,
        appExit: simPid == null
            ? null
            : watchHostPid(
                pid: simPid,
                isAlive: _isSimPidAlive,
                config: config,
                stop: stopWatch.future,
              ),
        config: config,
        logger: activeDiscoveryLogger(),
        abandoned: launchAbortSignal,
      );
    } finally {
      // The wait is over, whatever it concluded: end the `ps` polling and the
      // fallback's `log show` polling, then release the stream.
      stopWatch.complete();
      if (feeding != null) await feeding;
      await pump.dispose();
      await logs.close();
    }
  }

  Future<AppInstance> _launch(String appPath, {AppLogListener? onLog}) async {
    // Extract .app from .ipa if needed — simctl install requires .app.
    String installPath = appPath;
    if (appPath.endsWith('.ipa')) {
      final extracted = await extractAppFromIpa(appPath, _runProcess);
      installPath = extracted.appPath;
      _scratch.hold(extracted.dir);
    }

    // Boot sim (idempotent — no-op if already booted).
    await _runProcess('xcrun', ['simctl', 'boot', udid]);

    // Install.
    final installResult = await _runProcess('xcrun', [
      'simctl',
      'install',
      udid,
      installPath,
    ]);
    if (installResult.exitCode != 0) {
      throw StateError('simctl install failed: ${installResult.stderr}');
    }
    // Installing took a while: the shutdown may have arrived meanwhile, and
    // no simctl step observes the abandonment.
    throwIfLaunchAbandoned();

    // Two log streams, deliberately.
    //
    // Discovery matches on message content and nothing else. App output needs
    // a process-scoped predicate with several NOT(...) noise filters
    // ([iosSimulatorLogPredicate]). Folding the two together would make
    // VM-service discovery — which hot reload, screenshots and agent control
    // all depend on — contingent on those exclusion clauses continuing to
    // spare the announcement. Two narrow streams fail independently and
    // visibly; one broad stream fails silently.
    final discoveryLog = await _startHelper('xcrun', [
      'simctl',
      'spawn',
      udid,
      'log',
      'stream',
      '--predicate',
      'eventMessage contains "Observatory" or eventMessage contains "Dart VM service"',
    ]);

    final appName = p.basename(installPath).replaceAll('.app', '');
    final outputLog = await _startHelper('xcrun', [
      'simctl',
      'spawn',
      udid,
      'log',
      'stream',
      '--style',
      'json',
      '--predicate',
      iosSimulatorLogPredicate(appName),
    ]);

    // Unified logging carries no stdout/stderr split, so nothing is flagged as
    // an error channel here.
    final logs = startProcessLogs(
      outputLog,
      onLog,
      stderrIsError: false,
      transform: parseUnifiedLoggingLine,
    );

    // Launch app.
    final bundleId = _launchedBundleId =
        _bundleId ?? await extractBundleId(installPath, _runProcess);
    // Refuse before `simctl launch` puts an app on the simulator that nobody
    // will stop, rather than starting one only to terminate it below.
    throwIfLaunchAbandoned();
    // The persisted-log fallback hunts only entries logged at or after this
    // instant, so it is captured before the launch it bounds.
    final launchStarted = DateTime.now();
    final launchResult = await _runProcess('xcrun', [
      'simctl', 'launch', udid, bundleId,
      // Anything after the bundle id is passed to the app as argv, which is
      // where the iOS embedder looks for engine switches.
      if (startPaused) '--start-paused',
    ]);
    if (launchResult.exitCode != 0) {
      throw StateError('simctl launch failed: ${launchResult.stderr}');
    }
    _inFlightOwnsApp = true;

    // Discover VM service URI from the dedicated discovery stream, with the
    // persisted log as fallback. A release build serves none, so there is
    // nothing to wait for — and no pid watch to start.
    final discovery = buildMode.servesVmService
        ? await _discoverSimVmService(
            discoveryLog,
            launchResult.stdout as String,
            launchStarted: launchStarted,
          )
        : (uri: null, gaveUpNote: null);

    // The shutdown may have arrived while discovery ran: refuse the launch
    // rather than hand back an app nobody will stop.
    throwIfLaunchAbandoned();
    _inFlightOwnsApp = false;
    _launchHelpers.clear();
    return AppInstance(
      process: discoveryLog,
      vmServiceUri: discovery.uri,
      vmServiceDiscoveryNote: discovery.gaveUpNote,
      logs: logs,
      auxiliaryProcesses: [outputLog],
      scratchDirs: _scratch.handOver(),
    );
  }

  @override
  Future<void> stop(AppInstance instance) async {
    // Read into a local rather than null-asserting the field: whether the
    // field promotes across the check depends on the language version the
    // analyzer is given, and a local is what every version accepts.
    final bundleId = _launchedBundleId ?? _bundleId;
    if (bundleId != null) {
      await _runProcess('xcrun', ['simctl', 'terminate', udid, bundleId]);
    }
    await stopProcess('iOS Simulator app', instance.process, teardownBound);
    await instance.disposeAuxiliaryProcesses(teardownBound);
    await instance.logs.close();
    await instance.disposeScratchDirs();
  }

  /// iOS Simulator uses `simctl io screenshot` because `_flutter.screenshot`
  /// returns "Could not capture image screenshot" on the Simulator rendering
  /// pipeline. Waits for the first frame via VM service before capturing.
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
    final result = await _runProcess('xcrun', [
      'simctl',
      'io',
      udid,
      'screenshot',
      outputPath,
    ]);
    if (result.exitCode != 0) {
      throw StateError('simctl screenshot failed: ${result.stderr}');
    }
  }
}

/// An [IOSSimulatorDevice] that resolves the UDID on first launch.
class _IOSSimulatorDeviceBooted extends IOSSimulatorDevice {
  String? _resolvedUdid;

  _IOSSimulatorDeviceBooted({
    required ProcessRunSync runProcess,
    required ProcessStarter startProcess,
  }) : super(
         udid: 'booted',
         runProcess: runProcess,
         startProcess: startProcess,
       );

  @override
  String get name => _resolvedUdid != null
      ? 'iOS Simulator ($_resolvedUdid)'
      : 'iOS Simulator (booted)';

  Future<String> _resolveBootedUdid() async {
    if (_resolvedUdid != null) return _resolvedUdid!;
    final result = await _runProcess('xcrun', [
      'simctl',
      'list',
      'devices',
      'booted',
      '-j',
    ]);
    if (result.exitCode == 0) {
      final output = result.stdout as String;
      final match = RegExp(r'"udid"\s*:\s*"([^"]+)"').firstMatch(output);
      if (match != null) {
        _resolvedUdid = match.group(1)!;
        return _resolvedUdid!;
      }
    }
    throw StateError(
      'No booted iOS simulator found. '
      'Boot one with: xcrun simctl boot <device-name>',
    );
  }

  /// The simulator this run launched on, once it has; `booted` before.
  ///
  /// A getter every `simctl` command reads, rather than a device made for the
  /// launch alone: `simctl`'s own `booted` means whichever booted simulator it
  /// finds first, so with two booted a screenshot or a stop addressed that way
  /// reached a different simulator from the one the app was running on —
  /// measured, a screenshot of another app on a booted iPad.
  @override
  String get udid => _resolvedUdid ?? super.udid;

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    await _resolveBootedUdid();
    return super.launch(appPath, onLog: onLog);
  }
}

/// NSPredicate selecting an app's own log output on the iOS Simulator.
///
/// Ported from flutter_tools' `launchDeviceUnifiedLogging`
/// (`ios/simulators.dart`). Scoped to the app's process, then narrowed to
/// messages from the Flutter engine, the Swift runtime, or the app image
/// itself, then stripped of known-irrelevant noise.
///
/// This is *only* an app-output predicate. VM-service discovery uses its own
/// stream with a content match — see [IOSSimulatorDevice.launch] for why the
/// two are not merged.
String iosSimulatorLogPredicate(String appName) {
  String orP(List<String> clauses) => '(${clauses.join(" OR ")})';
  String andP(List<String> clauses) => clauses.join(' AND ');
  String notP(String clause) => 'NOT($clause)';

  return andP(<String>[
    'eventType = logEvent',
    'processImagePath ENDSWITH "$appName"',
    // From Flutter, from Swift (assertions/fatal errors), or from the app.
    orP(<String>[
      'senderImagePath ENDSWITH "/Flutter"',
      'senderImagePath ENDSWITH "/libswiftCore.dylib"',
      'processImageUUID == senderImageUUID',
    ]),
    notP(
      'eventMessage CONTAINS ": could not find icon for representation -> com.apple."',
    ),
    notP('eventMessage BEGINSWITH "assertion failed: "'),
    notP('eventMessage CONTAINS " libxpc.dylib "'),
  ]);
}

/// `"eventMessage" : "flutter: 21",` — one field of `log stream --style json`.
final _unifiedLoggingEventMessage = RegExp(r'.*"eventMessage" : (".*")');

/// Extract the message from a `log stream --style json` output line, or null
/// if the line carries no message (the format is pretty-printed across many
/// lines, most of which are other fields).
///
/// The predicate does the filtering, so every message that reaches here is
/// meant to be shown. Mirrors flutter_tools'
/// `_IOSSimulatorLogReader._onUnifiedLoggingLine`.
String? parseUnifiedLoggingLine(String line) {
  final match = _unifiedLoggingEventMessage.firstMatch(line);
  if (match == null) return null;
  try {
    final decoded = json.decode(match.group(1)!);
    return decoded is String ? decoded : null;
  } on FormatException {
    return null;
  }
}
