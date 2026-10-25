import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_ios/main.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ios_greeting_plugin/ios_greeting_plugin.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows the counter text and serves the bundled asset', (
    tester,
  ) async {
    await tester.pumpWidget(const CounterApp());
    await tester.pumpAndSettle();

    expect(find.text('0'), findsOneWidget);
    expect(
      find.text('You have pushed the button this many times:'),
      findsOneWidget,
    );

    final assetBytes = await rootBundle.load('assets/logo.png');
    final bytes = assetBytes.buffer.asUint8List();
    expect(bytes.lengthInBytes, 82);
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 16);
    expect(frame.image.height, 16);
    frame.image.dispose();
    codec.dispose();
  });

  testWidgets('reports the native bundle id over the plugin channel', (
    tester,
  ) async {
    await tester.pumpWidget(const CounterApp());

    // The rule-assigned `ios_bundle_id` default for this target.
    const expectedBundleId = 'com.example.integration-ios.app-test';
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.text(expectedBundleId).evaluate().isNotEmpty) {
        break;
      }
    }
    expect(find.text(expectedBundleId), findsOneWidget);
    expect(
      await const IosGreetingPlugin().getAppBundleId(),
      expectedBundleId,
    );
  });
}
