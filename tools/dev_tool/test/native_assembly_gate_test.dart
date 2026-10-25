/// Ordering tests: native hot-reload toolchain assembly starts only after the
/// first-frame wait of every launched session has settled.
///
/// The toolchain's `bazel build` must not run while the app it just launched
/// is still starting (the L-5 / COV-73 flake: the build starved the app until
/// the first-frame wait gave up). These tests drive the production gate
/// ([assembleNativeAfterFirstFrame]) with real [DeviceSession] first-frame
/// waits over [FakeVmService], and show the assembler held back while a wait
/// is pending, released by each of the wait's four outcomes, unheld by
/// `--start-paused`, and unblocked by a session with no VM client.
import 'dart:async';

import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/device_desktop.dart';
import 'package:flutter_bazel_dev_tool/device_launcher.dart';
import 'package:flutter_bazel_dev_tool/logging.dart';
import 'package:flutter_bazel_dev_tool/native_assembly_gate.dart';
import 'package:flutter_bazel_dev_tool/run_plan.dart';
import 'package:flutter_bazel_dev_tool/session.dart';
import 'package:flutter_bazel_dev_tool/session_host.dart';
import 'package:flutter_bazel_dev_tool/vm_service_client.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' show IsolateRef;

import 'fakes.dart';

/// A device whose budget for the app's first frame is short enough to test.
class _ImpatientDevice extends MacOSDevice {
  @override
  Duration get applyTimeout => const Duration(milliseconds: 100);
}

/// A device whose launch is scripted: the instance it always returns.
class _CannedDevice extends Device {
  final AppInstance _instance;

  _CannedDevice(this._instance);

  @override
  String get name => 'Canned';

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async =>
      _instance;

  @override
  Future<void> stop(AppInstance instance) async {}
}

/// A host whose teardown the test owns.
SessionHost _newHost(String name) {
  final host = SessionHost(isMachine: false, logger: Logger(name));
  addTearDown(host.teardown.run);
  return host;
}

FakeVmService _newFake() => FakeVmService(
  isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
);

Future<VmServiceClient> _connected(FakeVmService fake) async {
  final client = VmServiceClient(connector: (_) async => fake);
  await client.connect(
    Uri.parse('http://127.0.0.1:8181/'),
    createDevFS: false,
  );
  return client;
}

DeviceSession _sessionOn(
  Device device,
  VmServiceClient? client, {
  String appId = 'app_1',
}) => DeviceSession(
  device: device,
  appInstance: AppInstance(process: FakeProcess()),
  vmClient: client,
  appId: appId,
);

/// Runs the gate with a recording assembler, returning whether it ran.
Future<bool> _assemble(
  SessionHost host, {
  required bool startPaused,
}) async {
  var assembled = false;
  await assembleNativeAfterFirstFrame(
    host: host,
    startPaused: startPaused,
    assemble: () async {
      assembled = true;
    },
  ).timeout(const Duration(seconds: 5));
  return assembled;
}

/// Holds the first-frame wait open: the extension query the frame poll needs
/// never answers, so only a frame, the timeout, a failure, or the run ending
/// can settle the wait.
void _holdOpen(FakeVmService fake) {
  fake.callServiceExtensionGate = Completer<void>();
}

Future<void> _waitsForTheFirstFrame() async {
  final host = _newHost('test.native_assembly_gate.frame');
  final fake = _newFake();
  final session = _sessionOn(MacOSDevice(), await _connected(fake));
  _holdOpen(fake);
  host.firstFrameWaits.add(session.waitUntilDrivable(host.protocol));

  var assembled = false;
  final assembling = assembleNativeAfterFirstFrame(
    host: host,
    startPaused: false,
    assemble: () async {
      assembled = true;
    },
  );
  await pumpEventQueue();
  await pumpEventQueue();
  expect(
    assembled,
    isFalse,
    reason: 'assembly must not start while the first-frame wait is pending',
  );

  fake.emitFirstFrame();
  await assembling.timeout(const Duration(seconds: 5));
  expect(assembled, isTrue);
  expect(session.drivable.isReady, isTrue);
  fake.callServiceExtensionGate!.complete();
}

Future<void> _startsAfterTimeout() async {
  final host = _newHost('test.native_assembly_gate.timeout');
  final session = _sessionOn(_ImpatientDevice(), await _connected(_newFake()));
  host.firstFrameWaits.add(session.waitUntilDrivable(host.protocol));

  expect(await _assemble(host, startPaused: false), isTrue);
  expect(session.drivable.isSettled, isTrue);
  expect(session.drivable.isReady, isFalse);
  expect(session.drivable.unavailableReason, contains('had not rendered'));
}

Future<void> _startsAfterFailure() async {
  final host = _newHost('test.native_assembly_gate.failure');
  final fake = _newFake();
  // A fault that is not -32601: the poll keeps it as the wait's failure
  // instead of asking again.
  fake.extensionErrors['ext.flutter.didSendFirstFrameEvent'] = StateError(
    'connection reset',
  );
  final session = _sessionOn(_ImpatientDevice(), await _connected(fake));
  host.firstFrameWaits.add(session.waitUntilDrivable(host.protocol));

  expect(await _assemble(host, startPaused: false), isTrue);
  expect(session.drivable.isSettled, isTrue);
  expect(session.drivable.isReady, isFalse);
  expect(session.drivable.unavailableReason, contains('could not tell'));
}

Future<void> _startsAfterRunEnds() async {
  final host = _newHost('test.native_assembly_gate.run_ended');
  final fake = _newFake();
  final session = _sessionOn(MacOSDevice(), await _connected(fake));
  _holdOpen(fake);
  host.firstFrameWaits.add(session.waitUntilDrivable(host.protocol));

  var assembled = false;
  final assembling = assembleNativeAfterFirstFrame(
    host: host,
    startPaused: false,
    assemble: () async {
      assembled = true;
    },
  );
  await pumpEventQueue();
  await pumpEventQueue();
  expect(
    assembled,
    isFalse,
    reason: 'assembly must not start while the first-frame wait is pending',
  );

  session.stopWaitingForFirstFrame();
  await assembling.timeout(const Duration(seconds: 5));
  expect(assembled, isTrue);
  expect(session.drivable.isSettled, isTrue);
  expect(session.drivable.isReady, isFalse);
  expect(session.drivable.unavailableReason, contains('run ended'));
  fake.callServiceExtensionGate!.complete();
}

Future<void> _waitsForEverySession() async {
  final host = _newHost('test.native_assembly_gate.every_session');
  final firstFake = _newFake();
  final secondFake = _newFake();
  final first = _sessionOn(
    MacOSDevice(),
    await _connected(firstFake),
    appId: 'app_1',
  );
  final second = _sessionOn(
    MacOSDevice(),
    await _connected(secondFake),
    appId: 'app_2',
  );
  _holdOpen(firstFake);
  _holdOpen(secondFake);
  host.firstFrameWaits.add(first.waitUntilDrivable(host.protocol));
  host.firstFrameWaits.add(second.waitUntilDrivable(host.protocol));

  var assembled = false;
  final assembling = assembleNativeAfterFirstFrame(
    host: host,
    startPaused: false,
    assemble: () async {
      assembled = true;
    },
  );
  await pumpEventQueue();
  await pumpEventQueue();

  firstFake.emitFirstFrame();
  await pumpEventQueue();
  await pumpEventQueue();
  expect(
    assembled,
    isFalse,
    reason:
        'one settled session must not release assembly while another is '
        'still starting',
  );

  secondFake.emitFirstFrame();
  await assembling.timeout(const Duration(seconds: 5));
  expect(assembled, isTrue);
  firstFake.callServiceExtensionGate!.complete();
  secondFake.callServiceExtensionGate!.complete();
}

Future<void> _startsAtOnceWhenStartPaused() async {
  final host = _newHost('test.native_assembly_gate.start_paused');
  final fake = _newFake();
  final session = _sessionOn(MacOSDevice(), await _connected(fake));
  _holdOpen(fake);
  final firstFrame = session.waitUntilDrivable(host.protocol);
  host.firstFrameWaits.add(firstFrame);

  // A paused app renders nothing until a debugger resumes it, so there is no
  // frame to wait for: assembly starts at once.
  expect(await _assemble(host, startPaused: true), isTrue);

  session.stopWaitingForFirstFrame();
  await firstFrame.timeout(const Duration(seconds: 5));
  fake.callServiceExtensionGate!.complete();
}

Future<void> _noClientDoesNotBlock() async {
  final host = _newHost('test.native_assembly_gate.no_client');
  final session = _sessionOn(MacOSDevice(), null);
  host.firstFrameWaits.add(session.waitUntilDrivable(host.protocol));

  expect(await _assemble(host, startPaused: false), isTrue);
  expect(
    session.drivable.isSettled,
    isFalse,
    reason:
        'with no client there was never a wait: the gate stays open for the '
        'handover rather than refusing on a field that was always null',
  );
}

Future<void> _launchKeepsTheWait() async {
  final device = _CannedDevice(AppInstance(process: FakeProcess()));
  final host = _newHost('test.native_assembly_gate.launcher');
  final plan = RunPlan.forTest(
    target: '//app:app',
    devices: [device],
    logger: Logger('test.native_assembly_gate.launcher'),
    allowNoVmService: true,
  );

  final session = await DeviceLauncher(
    plan: plan,
    host: host,
    appFile: 'app',
  ).launch(device);

  expect(session.vmClient, isNull);
  // Kept instead of discarded: this is the future assembly waits on.
  expect(host.firstFrameWaits, hasLength(1));
  await host.settleFirstFrameWaits().timeout(const Duration(seconds: 5));
}

void main() {
  group('assembleNativeAfterFirstFrame', () {
    test(
      'waits for the first frame before starting assembly',
      _waitsForTheFirstFrame,
    );
    test('starts once the wait times out', _startsAfterTimeout);
    test('starts once the wait fails', _startsAfterFailure);
    test('starts once the run ends mid-wait', _startsAfterRunEnds);
    test('waits for every session, not just the first', _waitsForEverySession);
    test('starts at once under --start-paused', _startsAtOnceWhenStartPaused);
    test(
      'is not blocked by a session with no VM client',
      _noClientDoesNotBlock,
    );
  });

  group('launch keeps the first-frame wait', () {
    test(
      'the launched session contributes its wait to the host',
      _launchKeepsTheWait,
    );
  });
}
