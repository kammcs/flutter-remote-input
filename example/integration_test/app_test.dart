// Smoke test: the example app starts on a real device. Injection tests join
// it from milestone M2 (docs/roadmap.md, Testing).
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:remote_input_example/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the example app starts', (tester) async {
    await tester.pumpWidget(const RemoteInputExampleApp());
    expect(find.text('One-machine demo'), findsOneWidget);
    expect(find.textContaining('Protocol version 1'), findsOneWidget);
  });
}
