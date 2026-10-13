import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input_cloudflare_realtime/cloudflare_realtime_input_link.dart';

Uint8List _message(int i) => Uint8List.fromList([i & 0xFF, i >> 8]);

int _id(Uint8List m) => m[0] | m[1] << 8;

void main() {
  test('keeps at most 256 messages before a listener, the oldest', () async {
    final buffer = PreListenBuffer();
    expect(buffer.capacity, maxMessagesBeforeListen);
    expect(maxMessagesBeforeListen, 256);
    for (var i = 0; i < 1000; i++) {
      buffer.add(_message(i));
    }
    expect(buffer.dropped, 1000 - 256);
    final got = <int>[];
    buffer.stream.listen((m) => got.add(_id(m)));
    await pumpEventQueue();
    expect(got, [for (var i = 0; i < 256; i++) i]);

    // Once listened to, nothing is dropped.
    for (var i = 1000; i < 2000; i++) {
      buffer.add(_message(i));
    }
    await pumpEventQueue();
    expect(got, hasLength(256 + 1000));
    expect(got.last, 1999);
    expect(buffer.dropped, 1000 - 256);
    await buffer.close();
  });

  test('a smaller capacity, and nothing after close', () async {
    final buffer = PreListenBuffer(capacity: 2);
    for (var i = 0; i < 5; i++) {
      buffer.add(_message(i));
    }
    expect(buffer.dropped, 3);
    final got = <int>[];
    buffer.stream.listen((m) => got.add(_id(m)));
    await buffer.close();
    expect(buffer.isClosed, isTrue);
    buffer.add(_message(9));
    await pumpEventQueue();
    expect(got, [0, 1]);
  });
}
