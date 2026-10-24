@Tags(['e2e'])
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

void main() {
  final workspace = e2eWorkspace('ios_example');

  group(
    'iOS Simulator e2e',
    () {
      test(
        'HTTP control channel screenshot captures Flutter UI',
        () async {
          final dt = await startDevTool(
            workspace: workspace,
            target: ':app',
            device: 'ios-simulator',
          );

          // The build and the launch wait separately. The dev tool builds the
          // workspace copy before launching, and on a cold CI runner that
          // build takes many minutes; `app.start` fires once the build is
          // done and the launch begins, `app.started` once the app answers.
          // One bound covering both would time out a healthy cold run.
          await dt.waitForEvent(
            'app.start',
            timeout: const Duration(minutes: 20),
          );
          await dt.waitForEvent(
            'app.started',
            timeout: const Duration(minutes: 10),
          );
          final http = await dt.waitForHttpControl();
          expect(http, isNotNull);
          await Future<void>.delayed(const Duration(seconds: 3));

          final outputPath =
              '${Directory.systemTemp.path}/ios_sim_http_e2e.png';
          await dt.httpScreenshotToFile(dt.appId!, outputPath);

          final file = File(outputPath);
          expect(file.existsSync(), isTrue);
          file.deleteSync();

          await dt.sendCommand(1, 'daemon.shutdown');
        },
        // Above the waits' sum (20 + 10 + 2 for the control channel).
        timeout: const Timeout(Duration(minutes: 35)),
      );
    },
    skip: !Platform.isMacOS ? 'macOS only (needs Xcode Simulator)' : null,
  );
}
