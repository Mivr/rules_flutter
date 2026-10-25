import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_ios/main.dart';
import 'package:integration_test/integration_test.dart';

/// Red twin of `app_test.dart`: this expectation is wrong on purpose. The
/// full-matrix CI runs this target by name and asserts the run FAILS with
/// `RED_TWIN_MUST_FAIL` in the output (see the `### integration_test on the
/// iOS simulator` README section), proving the simulator harness reports
/// assertion failures loudly instead of passing silently. Never remove the
/// `manual` tag: `bazel test //...` must stay green.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('counter starts at zero (deliberately wrong)', (tester) async {
    await tester.pumpWidget(const CounterApp());
    await tester.pumpAndSettle();

    expect(find.text('0'), findsOneWidget);
    expect(
      find.text('1'),
      findsOneWidget,
      reason:
          'RED_TWIN_MUST_FAIL: the simulator harness must report this '
          'failing expectation',
    );
  });
}
