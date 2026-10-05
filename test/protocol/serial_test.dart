import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/src/protocol/serial.dart';

void main() {
  test('orders nearby numbers', () {
    expect(seqAfter(2, 1), isTrue);
    expect(seqAfter(1, 2), isFalse);
    expect(seqAfter(5, 5), isFalse);
  });

  test('wraps at 2^32', () {
    expect(seqAfter(0, 0xFFFFFFFF), isTrue);
    expect(seqAfter(3, 0xFFFFFFF0), isTrue);
    expect(seqAfter(0xFFFFFFFF, 0), isFalse);
    expect(seqNext(0xFFFFFFFF), 0);
  });

  test('is undefined (false both ways) half the space apart', () {
    expect(seqAfter(0x80000000, 0), isFalse);
    expect(seqAfter(0, 0x80000000), isFalse);
    expect(seqAfter(0x7FFFFFFF, 0), isTrue);
  });
}
