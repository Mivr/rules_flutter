/// Physical iOS device, over `xcrun devicectl` and lldb.
///
/// [IOSDevice] installs the app with `devicectl`, tails `devicectl --console`
/// as the wired log source, attaches lldb through [IOSDeviceLldb], and finds
/// the VM service by its mDNS advertisement. [IOSDeviceInfo] describes one
/// paired device, [parseDevicectlDevices] reads `devicectl list devices`
/// JSON, and [extractBundleId]/[extractAppFromIpa] unpack the installable.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_log.dart';
import 'device.dart';
import 'device_ios_lldb.dart';
import 'host_tools.dart';
import 'logging.dart';
import 'mdns_vm_service_discovery.dart';
import 'native_patch_delivery.dart';
import 'runfiles_helper.dart';
import 'temp_dir.dart';
import 'vm_service_client.dart';
import 'vm_service_discovery.dart';

final _logger = Logger('dev_tool.device');

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
    beginLaunch();
    try {
      final instance = await _launchAndAttach(appPath, onLog: onLog);
      endLaunch();
      return instance;
    } on MdnsDiscoveryException catch (e) {
      // A launch failure like any other, so the launcher reports it: its own
      // type escaped as an unhandled exception and took the tool down.
      endLaunch();
      await _abandonLaunch();
      throw StateError(e.message);
    } on MdnsAbandoned {
      // The run ended inside the mDNS wait: report the launch as cancelled,
      // so a relaunch in flight at shutdown says so instead of going quiet.
      endLaunch();
      await _abandonLaunch();
      throw VmDiscoveryCancelled(name);
    } catch (_) {
      endLaunch();
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

    final logs = newAppLogs(onLog);

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
