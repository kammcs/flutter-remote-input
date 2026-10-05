/// The v1 binary codec (`docs/design.md` §5): little-endian, one message per
/// transport message.
///
/// [decodeMessage] never throws: bytes it can't decode come back as a
/// [DecodeFailed] for the session to drop and count.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'messages.dart';
import 'wire_types.dart';

/// The header: `type u8`, `sessionTag u16`.
const int headerBytes = 3;

/// The most UTF-8 bytes one [TextMessage] carries.
const int maxTextBytes = 1024;

/// The length of a session nonce.
const int nonceBytes = 16;

/// The session tag for [nonce]: its low 16 bits, little-endian.
int sessionTagOf(Uint8List nonce) => nonce[0] | nonce[1] << 8;

/// The minimum v1 body length of each known type, after the header.
/// Decoders ignore bytes past these (`docs/design.md` §5.5).
const Map<int, int> _bodyBytes = {
  MessageType.hostHello: 33,
  MessageType.hello: 22,
  MessageType.bye: 1,
  MessageType.hostState: 4,
  MessageType.surface: 10,
  MessageType.ping: 12,
  MessageType.pong: 12,
  MessageType.pointerMove: 15,
  MessageType.pointerButton: 13,
  MessageType.wheel: 15,
  MessageType.key: 11,
  MessageType.text: 6,
  MessageType.releaseAll: 4,
};

/// Encodes [message] with [sessionTag] in its header.
///
/// Throws an [ArgumentError] for a value that doesn't fit its field (a
/// programming error on the sending side, never caused by received bytes).
Uint8List encodeMessage(WireMessage message, {required int sessionTag}) {
  _checkRange('sessionTag', sessionTag, 0xFFFF);
  final Uint8List? text = message is TextMessage
      ? utf8.encode(message.text)
      : null;
  if (text != null && text.length > maxTextBytes) {
    throw ArgumentError.value(
      text.length,
      'text',
      'is longer than $maxTextBytes UTF-8 bytes',
    );
  }
  final length = headerBytes + _bodyBytes[message.type]! + (text?.length ?? 0);
  final w = _Writer(length)
    ..u8(message.type)
    ..u16(sessionTag);
  switch (message) {
    case HostHello m:
      _checkNonce(m.nonce);
      w
        ..u8(m.minVersion)
        ..u8(m.maxVersion)
        ..bytes(m.nonce)
        ..u8(m.hostPlatform.code)
        ..u32(m.capabilities)
        ..u16(m.surfaceEpoch)
        ..u32(m.surfaceWidth)
        ..u32(m.surfaceHeight);
    case Hello m:
      _checkNonce(m.nonce);
      w
        ..u8(m.version)
        ..bytes(m.nonce)
        ..u8(m.viewerPlatform.code)
        ..u32(m.capabilities);
    case Bye m:
      w.u8(m.reason.code);
    case HostState m:
      w
        ..u8(m.state.code)
        ..u8(m.reason)
        ..u16(m.surfaceEpoch);
    case SurfaceMessage m:
      w
        ..u16(m.surfaceEpoch)
        ..u32(m.width)
        ..u32(m.height);
    case Ping m:
      w
        ..u32(m.id)
        ..u64(m.viewerMicros);
    case Pong m:
      w
        ..u32(m.id)
        ..u64(m.viewerMicros);
    case PointerMove m:
      w
        ..u32(m.seq)
        ..u16(m.surfaceEpoch)
        ..u16(m.x)
        ..u16(m.y)
        ..u8(m.buttons)
        ..u32(m.reliableSeq);
    case PointerButtonMessage m:
      w
        ..u32(m.seq)
        ..u16(m.surfaceEpoch)
        ..u16(m.x)
        ..u16(m.y)
        ..u8(m.button.code)
        ..u8(m.down ? 1 : 0)
        ..u8(m.clickCount);
    case Wheel m:
      w
        ..u32(m.seq)
        ..u16(m.surfaceEpoch)
        ..u16(m.x)
        ..u16(m.y)
        ..i16(m.dx)
        ..i16(m.dy)
        ..u8(m.unit.code);
    case KeyMessage m:
      w
        ..u32(m.seq)
        ..u32(m.usage)
        ..u8(m.action.code)
        ..u16(m.modifiers);
    case TextMessage m:
      w
        ..u32(m.seq)
        ..u16(text!.length)
        ..bytes(text);
    case ReleaseAll m:
      w.u32(m.seq);
  }
  return w.done();
}

/// What [decodeMessage] made of some bytes.
sealed class DecodeResult {
  const DecodeResult();
}

/// A message decoded.
final class Decoded extends DecodeResult {
  /// Creates a [Decoded].
  const Decoded(this.sessionTag, this.message);

  /// The header's session tag.
  final int sessionTag;

  /// The message.
  final WireMessage message;
}

/// An ignorable extension type (`0xC0`–`0xFF`) this version doesn't know.
/// Drop it silently.
final class DecodeIgnored extends DecodeResult {
  /// Creates a [DecodeIgnored].
  const DecodeIgnored(this.type);

  /// The type code.
  final int type;
}

/// Why bytes couldn't be decoded.
enum DecodeError {
  /// Shorter than the header, or than the type's v1 body.
  tooShort,

  /// A type that isn't defined and isn't in the ignorable range.
  unknownType,

  /// A field holds a value that isn't defined (a button code, a key
  /// action, a text length past the end, invalid UTF-8, a session tag that
  /// doesn't match the nonce).
  badValue,
}

/// Bytes that aren't a valid message. Drop it and count a violation.
final class DecodeFailed extends DecodeResult {
  /// Creates a [DecodeFailed].
  const DecodeFailed(this.error);

  /// Why.
  final DecodeError error;
}

const _failShort = DecodeFailed(DecodeError.tooShort);
const _failValue = DecodeFailed(DecodeError.badValue);

/// Decodes [bytes]. Never throws.
DecodeResult decodeMessage(Uint8List bytes) {
  if (bytes.length < headerBytes) return _failShort;
  final type = bytes[0];
  final body = _bodyBytes[type];
  if (body == null) {
    return type >= MessageType.firstIgnorable
        ? DecodeIgnored(type)
        : const DecodeFailed(DecodeError.unknownType);
  }
  if (bytes.length < headerBytes + body) return _failShort;
  final r = _Reader(bytes);
  final tag = r.u16();
  final WireMessage message;
  switch (type) {
    case MessageType.hostHello:
      final minVersion = r.u8();
      final maxVersion = r.u8();
      final nonce = r.bytes(nonceBytes);
      if (sessionTagOf(nonce) != tag) return _failValue;
      message = HostHello(
        minVersion: minVersion,
        maxVersion: maxVersion,
        nonce: nonce,
        hostPlatform: PeerPlatform.fromCode(r.u8()),
        capabilities: r.u32(),
        surfaceEpoch: r.u16(),
        surfaceWidth: r.u32(),
        surfaceHeight: r.u32(),
      );
    case MessageType.hello:
      message = Hello(
        version: r.u8(),
        nonce: r.bytes(nonceBytes),
        viewerPlatform: PeerPlatform.fromCode(r.u8()),
        capabilities: r.u32(),
      );
    case MessageType.bye:
      message = Bye(ByeReason.fromCode(r.u8()));
    case MessageType.hostState:
      final state = HostStateCode.fromCode(r.u8());
      if (state == null) return _failValue;
      message = HostState(state: state, reason: r.u8(), surfaceEpoch: r.u16());
    case MessageType.surface:
      message = SurfaceMessage(
        surfaceEpoch: r.u16(),
        width: r.u32(),
        height: r.u32(),
      );
    case MessageType.ping:
      message = Ping(id: r.u32(), viewerMicros: r.u64());
    case MessageType.pong:
      message = Pong(id: r.u32(), viewerMicros: r.u64());
    case MessageType.pointerMove:
      message = PointerMove(
        r.u32(),
        surfaceEpoch: r.u16(),
        x: r.u16(),
        y: r.u16(),
        buttons: r.u8(),
        reliableSeq: r.u32(),
      );
    case MessageType.pointerButton:
      final seq = r.u32();
      final epoch = r.u16();
      final x = r.u16();
      final y = r.u16();
      final button = PointerButton.fromCode(r.u8());
      final down = r.u8();
      final clickCount = r.u8();
      if (button == null || down > 1) return _failValue;
      message = PointerButtonMessage(
        seq,
        surfaceEpoch: epoch,
        x: x,
        y: y,
        button: button,
        down: down == 1,
        clickCount: clickCount,
      );
    case MessageType.wheel:
      final seq = r.u32();
      final epoch = r.u16();
      final x = r.u16();
      final y = r.u16();
      final dx = r.i16();
      final dy = r.i16();
      final unit = WheelUnit.fromCode(r.u8());
      if (unit == null) return _failValue;
      message = Wheel(
        seq,
        surfaceEpoch: epoch,
        x: x,
        y: y,
        dx: dx,
        dy: dy,
        unit: unit,
      );
    case MessageType.key:
      final seq = r.u32();
      final usage = r.u32();
      final action = KeyAction.fromCode(r.u8());
      if (action == null) return _failValue;
      message = KeyMessage(
        seq,
        usage: usage,
        action: action,
        modifiers: r.u16(),
      );
    case MessageType.text:
      final seq = r.u32();
      final length = r.u16();
      if (length > maxTextBytes || r.remaining < length) return _failValue;
      final String text;
      try {
        text = utf8.decode(r.view(length));
      } on FormatException {
        return _failValue;
      }
      message = TextMessage(seq, text);
    case MessageType.releaseAll:
      message = ReleaseAll(r.u32());
    default:
      // Every key of _bodyBytes is handled above.
      return const DecodeFailed(DecodeError.unknownType);
  }
  return Decoded(tag, message);
}

/// The largest value a u64 field carries: 2^53 - 1, exact on every
/// platform, including the web.
const int _maxU64Value = 0x1FFFFFFFFFFFFF;

void _checkRange(String name, int value, int max, {int min = 0}) {
  if (value < min || value > max) {
    // No value in the message: it may be a key code or a position
    // (docs/design.md §6.6).
    throw RangeError('$name is out of range $min..$max');
  }
}

void _checkNonce(Uint8List nonce) {
  if (nonce.length != nonceBytes) {
    throw ArgumentError.value(nonce.length, 'nonce', 'must be 16 bytes');
  }
}

final class _Writer {
  _Writer(int length) : _bytes = Uint8List(length) {
    _data = ByteData.sublistView(_bytes);
  }

  final Uint8List _bytes;
  late final ByteData _data;
  int _offset = 0;

  void u8(int v) {
    _checkRange('u8', v, 0xFF);
    _data.setUint8(_offset, v);
    _offset += 1;
  }

  void u16(int v) {
    _checkRange('u16', v, 0xFFFF);
    _data.setUint16(_offset, v, Endian.little);
    _offset += 2;
  }

  void i16(int v) {
    _checkRange('i16', v, 0x7FFF, min: -0x8000);
    _data.setInt16(_offset, v, Endian.little);
    _offset += 2;
  }

  void u32(int v) {
    _checkRange('u32', v, 0xFFFFFFFF);
    _data.setUint32(_offset, v, Endian.little);
    _offset += 4;
  }

  // Two u32 halves rather than setUint64, which the web doesn't support.
  void u64(int v) {
    _checkRange('u64', v, _maxU64Value);
    u32(v % 0x100000000);
    u32(v ~/ 0x100000000);
  }

  void bytes(Uint8List b) {
    _bytes.setRange(_offset, _offset + b.length, b);
    _offset += b.length;
  }

  Uint8List done() {
    assert(_offset == _bytes.length);
    return _bytes;
  }
}

final class _Reader {
  _Reader(this._bytes) : _data = ByteData.sublistView(_bytes), _offset = 1;

  final Uint8List _bytes;
  final ByteData _data;
  int _offset;

  int get remaining => _bytes.length - _offset;

  int u8() => _data.getUint8(_offset++);

  int u16() {
    final v = _data.getUint16(_offset, Endian.little);
    _offset += 2;
    return v;
  }

  int i16() {
    final v = _data.getInt16(_offset, Endian.little);
    _offset += 2;
    return v;
  }

  int u32() {
    final v = _data.getUint32(_offset, Endian.little);
    _offset += 4;
    return v;
  }

  /// The top 11 bits are ignored, so the value is exact on the web and
  /// re-encodes without overflow.
  int u64() => u32() + (u32() & 0x1FFFFF) * 0x100000000;

  Uint8List bytes(int n) => Uint8List.fromList(view(n));

  Uint8List view(int n) {
    final v = Uint8List.sublistView(_bytes, _offset, _offset + n);
    _offset += n;
    return v;
  }
}
