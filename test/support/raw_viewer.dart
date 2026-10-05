import 'dart:typed_data';

import 'package:remote_input/remote_input.dart';
import 'package:remote_input/src/protocol/codec.dart';
import 'package:remote_input/src/protocol/messages.dart';
import 'package:remote_input/testing.dart';

/// A viewer that speaks the protocol by hand, so tests can send exactly the
/// messages they want, including bad ones.
class RawViewer {
  RawViewer(this.link) {
    link.reliable.messages.listen((bytes) {
      final r = decodeMessage(bytes);
      if (r is Decoded) {
        received.add(r.message);
        if (r.message is HostHello) hostHello = r.message as HostHello;
      }
    });
  }

  final MemoryInputLink link;
  final List<WireMessage> received = [];
  HostHello? hostHello;
  int seq = 0;

  int get tag => sessionTagOf(hostHello!.nonce);
  int get epoch => hostHello!.surfaceEpoch;

  /// The host states received, in order.
  List<HostState> get states => received.whereType<HostState>().toList();

  void hello({int version = 1, PeerPlatform platform = PeerPlatform.windows}) {
    send(
      Hello(
        version: version,
        nonce: hostHello!.nonce,
        viewerPlatform: platform,
        capabilities: 0,
      ),
    );
  }

  void send(WireMessage m, {bool unreliable = false, int? sessionTag}) {
    if (m is InputMessage && m is! PointerMove && !unreliable) {
      lastReliable = m.seq;
    }
    sendBytes(
      encodeMessage(m, sessionTag: sessionTag ?? tag),
      unreliable: unreliable,
    );
  }

  void sendBytes(Uint8List bytes, {bool unreliable = false}) =>
      (unreliable ? link.unreliable : link.reliable).send(bytes);

  /// The seq of the last reliable input sent, for [move]'s `reliableSeq`.
  int? lastReliable;

  int next() => seq++;

  void move(
    int x,
    int y, {
    int buttons = 0,
    int? epoch,
    int? seq,
    int? reliableSeq,
  }) {
    final s = seq ?? next();
    send(
      PointerMove(
        s,
        surfaceEpoch: epoch ?? this.epoch,
        x: x,
        y: y,
        buttons: buttons,
        reliableSeq: reliableSeq ?? lastReliable ?? s,
      ),
      unreliable: true,
    );
  }

  void button(
    int x,
    int y,
    PointerButton b, {
    required bool down,
    int clickCount = 1,
    int? epoch,
  }) => send(
    PointerButtonMessage(
      next(),
      surfaceEpoch: epoch ?? this.epoch,
      x: x,
      y: y,
      button: b,
      down: down,
      clickCount: clickCount,
    ),
  );

  void wheel(
    int x,
    int y, {
    int dx = 0,
    int dy = 0,
    WheelUnit unit = WheelUnit.pixel,
  }) => send(
    Wheel(next(), surfaceEpoch: epoch, x: x, y: y, dx: dx, dy: dy, unit: unit),
  );

  void key(int usage, KeyAction action, {int modifiers = 0}) => send(
    KeyMessage(next(), usage: usage, action: action, modifiers: modifiers),
  );

  void text(String text) => send(TextMessage(next(), text));

  void releaseAll() => send(ReleaseAll(next()));
}
