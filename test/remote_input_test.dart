import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';

void main() {
  // Placeholder until the codec lands (roadmap M1).
  test('speaks protocol version 1', () {
    expect(remoteInputProtocolVersion, 1);
  });
}
