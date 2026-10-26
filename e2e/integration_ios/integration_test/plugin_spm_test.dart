import 'package:flutter_test/flutter_test.dart';
import 'package:integration_ios/main.dart';
import 'package:integration_test/integration_test.dart';
import 'package:spm_bigint_plugin/spm_bigint_plugin.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('links the plugin SwiftPM product and computes 2^100', (
    tester,
  ) async {
    await tester.pumpWidget(const CounterApp());
    await tester.pumpAndSettle();

    // Computed at run time by the BigInt product linked into the
    // plugin's Apple library: 2^100, then BigInt("-0").
    expect(
      await const SpmBigintPlugin().computeBig(),
      '1267650600228229401496703205376 0',
    );
  });
}
