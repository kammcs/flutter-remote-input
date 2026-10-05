import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/src/protocol/codec.dart';
import 'package:remote_input/src/protocol/messages.dart';
import 'package:remote_input/src/protocol/wire_types.dart';

Uint8List hex(String s) {
  final clean = s.replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList([
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
}

String toHex(Uint8List b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

final nonce = Uint8List.fromList(List.generate(16, (i) => 0x10 + i));
const nonceHex = '101112131415161718191a1b1c1d1e1f';
const tag = 0x1110; // nonce[0] | nonce[1] << 8

/// Every v1 message, with its exact encoding. Changing one of these is a
/// protocol change (docs/design.md §5.5).
final golden = <String, (WireMessage, String)>{
  'HostHello': (
    HostHello(
      minVersion: 1,
      maxVersion: 1,
      nonce: nonce,
      hostPlatform: PeerPlatform.macos,
      capabilities: 0,
      surfaceEpoch: 0x0203,
      surfaceWidth: 1920,
      surfaceHeight: 1080,
    ),
    '01 1011 01 01 $nonceHex 02 00000000 0302 80070000 38040000',
  ),
  'Hello': (
    Hello(
      version: 1,
      nonce: nonce,
      viewerPlatform: PeerPlatform.windows,
      capabilities: ViewerCapabilities.web,
    ),
    '02 1011 01 $nonceHex 01 01000000',
  ),
  'Bye': (const Bye(ByeReason.unsupportedVersion), '03 1011 02'),
  'HostState': (
    HostState(
      state: HostStateCode.blocked,
      reason: BlockReason.secureInput.code,
      surfaceEpoch: 0x0203,
    ),
    '04 1011 03 03 0302',
  ),
  'Surface': (
    const SurfaceMessage(surfaceEpoch: 0x0203, width: 1280, height: 720),
    '05 1011 0302 00050000 d0020000',
  ),
  'Ping': (
    const Ping(id: 0x12345678, viewerMicros: 0x0001020304050607),
    '06 1011 78563412 0706050403020100',
  ),
  'Pong': (
    const Pong(id: 0x12345678, viewerMicros: 0x0001020304050607),
    '07 1011 78563412 0706050403020100',
  ),
  'PointerMove': (
    const PointerMove(
      0xFFFFFFFE,
      surfaceEpoch: 0x0203,
      x: 0,
      y: 65535,
      buttons: 0x05,
      reliableSeq: 0xFFFFFFFD,
    ),
    '10 1011 feffffff 0302 0000 ffff 05 fdffffff',
  ),
  'PointerButton': (
    const PointerButtonMessage(
      1,
      surfaceEpoch: 0x0203,
      x: 0x8000,
      y: 0x4000,
      button: PointerButton.right,
      down: true,
      clickCount: 2,
    ),
    '11 1011 01000000 0302 0080 0040 02 01 02',
  ),
  'Wheel': (
    const Wheel(
      2,
      surfaceEpoch: 0x0203,
      x: 0x8000,
      y: 0x8000,
      dx: -120,
      dy: 3,
      unit: WheelUnit.line,
    ),
    '12 1011 02000000 0302 0080 0080 88ff 0300 01',
  ),
  'Key': (
    const KeyMessage(
      3,
      usage: 0x00070004,
      action: KeyAction.down,
      modifiers: KeyModifiers.shift | KeyModifiers.meta,
    ),
    '20 1011 03000000 04000700 01 0900',
  ),
  'Text': (const TextMessage(4, 'hé!'), '21 1011 04000000 0400 68c3a921'),
  'ReleaseAll': (const ReleaseAll(5), '22 1011 05000000'),
};

void main() {
  group('golden bytes', () {
    for (final MapEntry(key: name, value: (message, bytes)) in golden.entries) {
      test(name, () {
        final encoded = encodeMessage(message, sessionTag: tag);
        expect(toHex(encoded), toHex(hex(bytes)));
        final decoded = decodeMessage(encoded);
        expect(decoded, isA<Decoded>());
        decoded as Decoded;
        expect(decoded.sessionTag, tag);
        expect(decoded.message.runtimeType, message.runtimeType);
        expect(
          toHex(encodeMessage(decoded.message, sessionTag: tag)),
          toHex(encoded),
        );
      });
    }

    test('cover every message type', () {
      final types = golden.values.map((g) => g.$1.type).toSet();
      expect(types, hasLength(13));
    });
  });

  group('decoding', () {
    test('ignores trailing bytes (fields added at the end within v1)', () {
      final bytes = hex('${golden['Key']!.$2} aabbcc');
      final r = decodeMessage(bytes) as Decoded;
      final key = r.message as KeyMessage;
      expect(key.usage, 0x00070004);
      expect(key.modifiers, 9);
    });

    test('rejects every body shorter than its v1 size', () {
      for (final (message, bytes) in golden.values) {
        final full = hex(bytes);
        // Text's length prefix makes its full size depend on the text.
        final minimum = message is TextMessage ? 9 : full.length;
        for (var n = 0; n < minimum; n++) {
          final r = decodeMessage(Uint8List.sublistView(full, 0, n));
          expect(r, isA<DecodeFailed>(), reason: '${message.type} at $n bytes');
        }
      }
    });

    test('a text length past the end is malformed', () {
      final r = decodeMessage(hex('21 1011 04000000 0500 68c3a921'));
      expect((r as DecodeFailed).error, DecodeError.badValue);
    });

    test('invalid UTF-8 is malformed', () {
      final r = decodeMessage(hex('21 1011 04000000 0200 c328'));
      expect((r as DecodeFailed).error, DecodeError.badValue);
    });

    test('text over 1024 bytes is malformed', () {
      final bytes = Uint8List(9 + 1025)
        ..setAll(0, hex('21 1011 04000000 0104'));
      bytes.fillRange(9, bytes.length, 0x61);
      expect(
        (decodeMessage(bytes) as DecodeFailed).error,
        DecodeError.badValue,
      );
    });

    test('undefined values are malformed', () {
      for (final bad in [
        '11 1011 01000000 0302 0080 0040 06 01 02', // button 6
        '11 1011 01000000 0302 0080 0040 02 02 02', // down = 2
        '12 1011 02000000 0302 0080 0080 88ff 0300 02', // unit 2
        '20 1011 03000000 04000700 03 0900', // action 3
        '04 1011 05 00 0000', // state 5
        '04 1011 00 00 0000', // state 0
      ]) {
        expect(
          (decodeMessage(hex(bad)) as DecodeFailed).error,
          DecodeError.badValue,
          reason: bad,
        );
      }
    });

    test("a HostHello whose tag isn't its nonce's is malformed", () {
      final bytes = hex(golden['HostHello']!.$2)..[1] = 0x99;
      expect(
        (decodeMessage(bytes) as DecodeFailed).error,
        DecodeError.badValue,
      );
    });

    test('unknown types fail, ignorable extensions are ignored', () {
      expect(
        (decodeMessage(hex('08 1011')) as DecodeFailed).error,
        DecodeError.unknownType,
      );
      expect(
        (decodeMessage(hex('bf 1011 00')) as DecodeFailed).error,
        DecodeError.unknownType,
      );
      expect(decodeMessage(hex('c0 1011')), isA<DecodeIgnored>());
      expect(decodeMessage(hex('ff 1011 0102')), isA<DecodeIgnored>());
    });

    test('unknown reason and platform codes decode as other/unknown', () {
      final hello = hex(golden['Hello']!.$2)..[20] = 0x7F;
      expect(
        ((decodeMessage(hello) as Decoded).message as Hello).viewerPlatform,
        PeerPlatform.unknown,
      );
      expect(
        ((decodeMessage(hex('03 1011 7f')) as Decoded).message as Bye).reason,
        ByeReason.other,
      );
      expect(StopReason.fromCode(0x7F), StopReason.other);
      expect(PauseReason.fromCode(0x7F), PauseReason.other);
      expect(BlockReason.fromCode(0x7F), BlockReason.other);
    });

    test('u64 fields ignore their top 11 bits, so they re-encode', () {
      final r =
          decodeMessage(hex('06 1011 00000000 ffffffffffffffff')) as Decoded;
      final ping = r.message as Ping;
      expect(ping.viewerMicros, 0x1FFFFFFFFFFFFF);
      expect(() => encodeMessage(ping, sessionTag: tag), returnsNormally);
    });
  });

  group('encoding', () {
    test('rejects values that do not fit', () {
      expect(
        () => encodeMessage(const ReleaseAll(0x100000000), sessionTag: 0),
        throwsRangeError,
      );
      expect(
        () => encodeMessage(const ReleaseAll(0), sessionTag: 0x10000),
        throwsRangeError,
      );
      expect(
        () => encodeMessage(TextMessage(0, 'a' * 1025), sessionTag: 0),
        throwsArgumentError,
      );
      expect(
        () => encodeMessage(
          Hello(
            version: 1,
            nonce: Uint8List(15),
            viewerPlatform: PeerPlatform.windows,
            capabilities: 0,
          ),
          sessionTag: 0,
        ),
        throwsArgumentError,
      );
    });
  });

  group('fuzz', () {
    // At least a million inputs, random and mutated (docs/roadmap.md,
    // success criterion 7): decoding never throws, and whatever decodes
    // re-encodes, since the host echoes some fields back.
    test('a million random and mutated messages', () {
      final random = Random(42);
      final seeds = [for (final g in golden.values) hex(g.$2)];
      var decoded = 0;
      for (var i = 0; i < 1000000; i++) {
        final Uint8List bytes;
        if (i.isEven) {
          bytes = Uint8List(random.nextInt(48));
          for (var j = 0; j < bytes.length; j++) {
            bytes[j] = random.nextInt(256);
          }
          // Mostly known types, so bodies get exercised.
          if (bytes.isNotEmpty && random.nextBool()) {
            bytes[0] = seeds[random.nextInt(seeds.length)][0];
          }
        } else {
          final seed = seeds[random.nextInt(seeds.length)];
          final length = max(0, seed.length + random.nextInt(9) - 4);
          bytes = Uint8List(length)
            ..setRange(0, min(length, seed.length), seed);
          for (var k = random.nextInt(4); k >= 0; k--) {
            if (length == 0) break;
            bytes[random.nextInt(length)] = random.nextInt(256);
          }
        }
        final r = decodeMessage(bytes);
        if (r is Decoded) {
          decoded++;
          encodeMessage(r.message, sessionTag: r.sessionTag);
        }
      }
      expect(decoded, greaterThan(100000));
    });
  });
}
