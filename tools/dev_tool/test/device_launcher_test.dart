/// Launcher-decision tests for a launch without a VM service.
///
/// Discovery's own waits are covered in fake time by
/// `vm_service_discovery_test`; these tests start where discovery ends — an
/// [AppInstance] with no URI and the note discovery gave up with — and pin
/// the run's abort-or-continue decision: a [DevToolException] carrying the
/// note by default, a warning and a session under `--allow-no-vm-service`.
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/device_launcher.dart';
import 'package:flutter_bazel_dev_tool/dev_tool_exception.dart';
import 'package:flutter_bazel_dev_tool/logging.dart';
import 'package:flutter_bazel_dev_tool/run_plan.dart';
import 'package:flutter_bazel_dev_tool/session_host.dart';
import 'package:logging/logging.dart' show LogRecord;
import 'package:test/test.dart';

import 'fakes.dart';

/// The note a bound expiry on a living app carries: the bound, the option
/// that raises it, and the last log lines.
const _gaveUpNote =
    'Still no VM service on Canned after 65s (the --vm-service-timeout '
    'bound). To wait longer, pass --vm-service-timeout=<seconds> with a '
    'larger value. Last app output (2 lines):\n'
    'flutter: warming up\n'
    'flutter: still warming up';

/// A device whose launch is scripted: the instance discovery ended with.
class _CannedDevice extends Device {
  final AppInstance _instance;

  var stops = 0;

  _CannedDevice(this._instance);

  @override
  String get name => 'Canned';

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async =>
      _instance;

  @override
  Future<void> stop(AppInstance instance) async {
    stops++;
  }
}

/// Capture records on [loggerName] for the duration of the test.
List<LogRecord> captureLog(String loggerName) {
  final records = <LogRecord>[];
  final sub = Logger.root.onRecord.listen((record) {
    if (record.loggerName == loggerName) records.add(record);
  });
  addTearDown(sub.cancel);
  return records;
}

void main() {
  group('launch without a VM service', () {
    test(
      'aborts with the discovery note, naming the bound and the option',
      () async {
        final records = captureLog('test.device_launcher.abort');
        final device = _CannedDevice(
          AppInstance(
            process: FakeProcess(),
            vmServiceDiscoveryNote: _gaveUpNote,
          ),
        );
        final plan = RunPlan.forTest(
          target: '//app:app',
          devices: [device],
          logger: Logger('test.device_launcher.abort'),
          allowNoVmService: false,
        );
        final host = SessionHost(
          isMachine: false,
          logger: Logger('test.device_launcher.abort.host'),
        );
        addTearDown(host.teardown.run);
        final launcher = DeviceLauncher(
          plan: plan,
          host: host,
          appFile: 'app',
        );

        await expectLater(
          launcher.launch(device),
          throwsA(
            isA<DevToolException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('Canned'),
                contains('65s'),
                contains('--vm-service-timeout'),
                contains('flutter: still warming up'),
                contains('--allow-no-vm-service'),
              ),
            ),
          ),
        );
        // The broken session is stopped on the way out.
        expect(device.stops, 1);
        // The log line keeps the original sentence naming the device, with
        // the note appended.
        final notFounds = records
            .map((r) => r.object)
            .whereType<Map>()
            .where((o) => o['message'] == 'vm_service_uri_not_found')
            .toList();
        expect(notFounds, hasLength(1));
        expect(
          notFounds.single['text'],
          'No VM service URI was discovered on Canned. $_gaveUpNote. Hot '
          'reload, DevTools, and agent control will be unavailable.',
        );
      },
    );

    test(
      'without a discovery note the log line is the original sentence',
      () async {
        final records = captureLog('test.device_launcher.nonote');
        final device = _CannedDevice(AppInstance(process: FakeProcess()));
        final plan = RunPlan.forTest(
          target: '//app:app',
          devices: [device],
          logger: Logger('test.device_launcher.nonote'),
          allowNoVmService: false,
        );
        final host = SessionHost(
          isMachine: false,
          logger: Logger('test.device_launcher.nonote.host'),
        );
        addTearDown(host.teardown.run);
        final launcher = DeviceLauncher(
          plan: plan,
          host: host,
          appFile: 'app',
        );

        await expectLater(
          launcher.launch(device),
          throwsA(
            isA<DevToolException>().having(
              (e) => e.message,
              'message',
              contains('no VM service URI was discovered at launch'),
            ),
          ),
        );
        final notFounds = records
            .map((r) => r.object)
            .whereType<Map>()
            .where((o) => o['message'] == 'vm_service_uri_not_found')
            .toList();
        expect(notFounds, hasLength(1));
        expect(
          notFounds.single['text'],
          'No VM service URI was discovered on Canned. Hot reload, '
          'DevTools, and agent control will be unavailable.',
        );
      },
    );

    test(
      'continues with a warning carrying the note under '
      '--allow-no-vm-service',
      () async {
        final records = captureLog('test.device_launcher.continue');
        final device = _CannedDevice(
          AppInstance(
            process: FakeProcess(),
            vmServiceDiscoveryNote: _gaveUpNote,
          ),
        );
        final plan = RunPlan.forTest(
          target: '//app:app',
          devices: [device],
          logger: Logger('test.device_launcher.continue'),
          allowNoVmService: true,
        );
        final host = SessionHost(
          isMachine: false,
          logger: Logger('test.device_launcher.continue.host'),
        );
        addTearDown(host.teardown.run);
        final launcher = DeviceLauncher(
          plan: plan,
          host: host,
          appFile: 'app',
        );

        final session = await launcher.launch(device);

        expect(session.vmClient, isNull);
        final warnings = records
            .map((r) => r.object)
            .whereType<Map>()
            .where((o) => o['message'] == 'no_vm_service_continuing')
            .toList();
        expect(warnings, hasLength(1));
        expect(
          warnings.single['reason'],
          allOf(contains('65s'), contains('--vm-service-timeout')),
        );
        // Continuing means the app keeps running: nothing stopped it.
        expect(device.stops, 0);
      },
    );
  });
}
