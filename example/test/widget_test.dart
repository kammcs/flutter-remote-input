import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input_example/main.dart';

void main() {
  testWidgets('shows the protocol version', (tester) async {
    await tester.pumpWidget(const RemoteInputExampleApp());
    expect(find.text('Protocol version 1'), findsOneWidget);
  });
}
