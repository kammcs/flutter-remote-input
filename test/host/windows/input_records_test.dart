import 'dart:ffi';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/src/host/windows/input_records.dart';
import 'package:remote_input/src/keys/key_tables.g.dart';
import 'package:remote_input/src/surface.dart';

import 'fake_win32.dart';

// The Windows SDK's structs, declared with dart:ffi, to cross-check the
// hand-written layout. Their layout on this (64-bit) test host follows the
// same natural-alignment rules as 64-bit Windows for these field types.
final class _MouseInput extends Struct {
  @Int32()
  external int dx;
  @Int32()
  external int dy;
  @Uint32()
  external int mouseData;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int time;
  @Uint64()
  external int dwExtraInfo;
}

final class _KeybdInput extends Struct {
  @Uint16()
  external int wVk;
  @Uint16()
  external int wScan;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int time;
  @Uint64()
  external int dwExtraInfo;
}

final class _HardwareInput extends Struct {
  @Uint32()
  external int uMsg;
  @Uint16()
  external int wParamL;
  @Uint16()
  external int wParamH;
}

final class _InputUnion extends Union {
  external _MouseInput mi;
  external _KeybdInput ki;
  external _HardwareInput hi;
}

final class _Input extends Struct {
  @Uint32()
  external int type;
  external _InputUnion u;
}

Uint8List _bytesOf(Pointer<_Input> p) =>
    Uint8List.fromList(p.cast<Uint8>().asTypedList(sizeOf<_Input>()));

String _hex(Uint8List b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('INPUT layout', () {
    test('matches the Windows SDK structs', () {
      expect(sizeOf<_Input>(), inputRecordSize);
      expect(sizeOf<_MouseInput>(), 32);
      expect(sizeOf<_KeybdInput>(), 24);
    });

    test('a mouse record is byte-for-byte the struct', () {
      const record = MouseRecord(
        dx: 0x1234,
        dy: -2,
        mouseData: -120,
        flags: 0xC001,
        extraInfo: testTag,
      );
      final p = calloc<_Input>();
      addTearDown(() => calloc.free(p));
      p.ref.type = Win32Input.typeMouse;
      p.ref.u.mi
        ..dx = 0x1234
        ..dy = -2
        ..mouseData = (-120) & 0xFFFFFFFF
        ..dwFlags = 0xC001
        ..dwExtraInfo = testTag;
      expect(encodeInputRecords([record]), _bytesOf(p));
    });

    test('a key record is byte-for-byte the struct', () {
      const record = KeyRecord(scan: 0x48, flags: 0x0B, extraInfo: testTag);
      final p = calloc<_Input>();
      addTearDown(() => calloc.free(p));
      p.ref.type = Win32Input.typeKeyboard;
      p.ref.u.ki
        ..wScan = 0x48
        ..dwFlags = 0x0B
        ..dwExtraInfo = testTag;
      expect(encodeInputRecords([record]), _bytesOf(p));
    });

    test('golden bytes', () {
      // An absolute move to the centre of the virtual desktop.
      expect(
        _hex(
          encodeInputRecords([
            const MouseRecord(
              dx: 0x8000,
              dy: 0x8000,
              flags: 0xC001,
              extraInfo: testTag,
            ),
          ]),
        ),
        '00000000' // type: INPUT_MOUSE
        '00000000' // padding
        '00800000' // dx
        '00800000' // dy
        '00000000' // mouseData
        '01c00000' // dwFlags: ABSOLUTE | VIRTUALDESK | MOVE
        '00000000' // time
        '00000000' // padding
        '3412000069746d72', // dwExtraInfo: the tag
      );
      // Up arrow released: extended scan code 0x48.
      expect(
        _hex(
          encodeInputRecords([
            const KeyRecord(scan: 0x48, flags: 0x0B, extraInfo: testTag),
          ]),
        ),
        '01000000' // type: INPUT_KEYBOARD
        '00000000' // padding
        '0000' // wVk
        '4800' // wScan
        '0b000000' // dwFlags: SCANCODE | KEYUP | EXTENDEDKEY
        '00000000' // time
        '00000000' // padding
        '3412000069746d72' // dwExtraInfo
        '0000000000000000', // the rest of the union
      );
    });

    test('records are laid out one after another', () {
      final records = textRecords('ab', tag: testTag);
      final bytes = encodeInputRecords(records);
      expect(bytes.length, 4 * inputRecordSize);
      expect(decodeInputRecords(bytes), records);
    });
  });

  group('absolute coordinates', () {
    // (origin, extent) pairs: one display, two side by side with the
    // primary on the right (negative origin), odd sizes, 8K, three 8Ks.
    const desktops = [
      (0, 1920),
      (-1920, 3840),
      (-2560, 4480),
      (0, 1366),
      (-1080, 2160),
      (0, 7680),
      (-7680, 23040),
      (0, 1),
      (0, 3),
    ];

    test('every pixel round-trips through truncation', () {
      for (final (origin, extent) in desktops) {
        for (var p = origin; p < origin + extent; p++) {
          final a = absoluteCoordinate(p, origin, extent);
          expect(a, inInclusiveRange(0, 65535));
          expect(
            pixelForAbsolute(a, origin, extent),
            p,
            reason: 'pixel $p of $extent from $origin',
          );
        }
      }
    });

    test('every pixel also survives rounding instead of truncation', () {
      for (final (origin, extent) in desktops) {
        for (var p = origin; p < origin + extent; p++) {
          final a = absoluteCoordinate(p, origin, extent);
          final rounded = origin + (a * extent / 65536).round();
          expect(rounded, p, reason: 'pixel $p of $extent from $origin');
        }
      }
    });

    test('the naive formula is off by one', () {
      // `i * 65535 / extent`, truncated, lands on the pixel before.
      const extent = 1920;
      final naive = 1000 * 65535 ~/ extent;
      expect(pixelForAbsolute(naive, 0, extent), 999);
      expect(
        pixelForAbsolute(absoluteCoordinate(1000, 0, extent), 0, extent),
        1000,
      );
    });

    test('corners and the end of the range', () {
      expect(absoluteCoordinate(-1920, -1920, 3840), 0);
      // ceil(3839 * 65536 / 3840) = ceil(65518.93)
      expect(absoluteCoordinate(1919, -1920, 3840), 65519);
      // Out of range clamps to the desktop.
      expect(
        absoluteCoordinate(5000, 0, 1920),
        absoluteCoordinate(1919, 0, 1920),
      );
      expect(absoluteCoordinate(-5, 0, 1920), 0);
      expect(absoluteCoordinate(10, 0, 0), 0);
    });

    test('wire corners map to the surface pixels', () {
      // A display left of the primary.
      const bounds = Rect.fromLTWH(-2560, -200, 2560, 1440);
      Offset pixel(int x, int y) {
        final p = mapNormalizedPoint(x, y, bounds);
        return Offset(
          desktopPixel(p.dx).toDouble(),
          desktopPixel(p.dy).toDouble(),
        );
      }

      expect(pixel(0, 0), const Offset(-2560, -200));
      expect(pixel(65535, 65535), const Offset(-1, 1239));
      expect(pixel(65535, 0), const Offset(-1, -200));
      expect(pixel(32768, 32768), const Offset(-1280, 520));
      // Rounding instead would leave the surface at the far edge.
      final far = mapNormalizedPoint(65535, 65535, bounds);
      expect(far.dx.round(), 0);
      expect(desktopPixel(far.dx), -1);
    });
  });

  group('scan codes', () {
    test('plain and extended keys', () {
      expect(scanCodeForUsage(0x00070004), (scan: 0x1E, extended: false));
      expect(scanCodeForUsage(0x00070052), (scan: 0x48, extended: true));
      expect(scanCodeForUsage(0x000700E4), (scan: 0x1D, extended: true));
      expect(scanCodeForUsage(0x000700E6), (scan: 0x38, extended: true));
      // NumLock is E0 45 and Pause plain 45, as Windows reports them.
      expect(scanCodeForUsage(0x00070053), (scan: 0x45, extended: true));
      expect(scanCodeForUsage(0x00070048), (scan: 0x45, extended: false));
    });

    test('unknown usages have none', () {
      expect(scanCodeForUsage(0x00070000), isNull);
      expect(scanCodeForUsage(0x00FF0001), isNull);
    });

    test('every table entry is plain or E0-extended', () {
      for (final code in hidToWindowsScanCode.values) {
        expect(code >> 8, anyOf(0, 0xE0));
      }
    });

    test('records carry the flags', () {
      const up = (scan: 0x48, extended: true);
      expect(
        scanCodeRecord(up, down: true, tag: testTag),
        const KeyRecord(scan: 0x48, flags: 0x09, extraInfo: testTag),
      );
      expect(
        scanCodeRecord(up, down: false, tag: testTag),
        const KeyRecord(scan: 0x48, flags: 0x0B, extraInfo: testTag),
      );
      expect(
        scanCodeRecord((scan: 0x1E, extended: false), down: true, tag: 1),
        const KeyRecord(scan: 0x1E, flags: 0x08, extraInfo: 1),
      );
    });
  });

  group('text', () {
    KeyRecord unicode(int unit, {bool up = false}) => KeyRecord(
      scan: unit,
      flags: Win32Input.keyUnicode | (up ? Win32Input.keyUp : 0),
      extraInfo: testTag,
    );

    test('a down and an up per UTF-16 unit', () {
      expect(textRecords('hé', tag: testTag), [
        unicode(0x68),
        unicode(0x68, up: true),
        unicode(0xE9),
        unicode(0xE9, up: true),
      ]);
    });

    test('a surrogate pair is two units', () {
      expect(textRecords('😀', tag: testTag), [
        unicode(0xD83D),
        unicode(0xD83D, up: true),
        unicode(0xDE00),
        unicode(0xDE00, up: true),
      ]);
    });

    test('line breaks press Enter and tabs press Tab', () {
      const enterDown = KeyRecord(scan: 0x1C, flags: 0x08, extraInfo: testTag);
      const enterUp = KeyRecord(scan: 0x1C, flags: 0x0A, extraInfo: testTag);
      const tabDown = KeyRecord(scan: 0x0F, flags: 0x08, extraInfo: testTag);
      const tabUp = KeyRecord(scan: 0x0F, flags: 0x0A, extraInfo: testTag);
      expect(textRecords('a\r\nb', tag: testTag), [
        unicode(0x61),
        unicode(0x61, up: true),
        enterDown,
        enterUp,
        unicode(0x62),
        unicode(0x62, up: true),
      ]);
      expect(textRecords('\n\r\t', tag: testTag), [
        enterDown,
        enterUp,
        enterDown,
        enterUp,
        tabDown,
        tabUp,
      ]);
    });

    test('empty text has no records', () {
      expect(textRecords('', tag: testTag), isEmpty);
    });
  });

  group('wheel', () {
    (int, int) convert(
      WheelConverter c, {
      int dx = 0,
      int dy = 0,
      bool pixels = false,
      int lines = 3,
      int chars = 3,
    }) => c.convert(
      dx: dx,
      dy: dy,
      pixels: pixels,
      linesPerNotch: lines,
      charsPerNotch: chars,
    );

    test('lines scroll the same number of lines', () {
      final c = WheelConverter();
      // Three lines down is one notch towards the user.
      expect(convert(c, dy: 3), (0, -120));
      expect(convert(c, dy: -1), (0, 40));
      expect(convert(c, dx: 3), (120, 0));
      // With 6 lines per notch, a line is 20 units.
      expect(convert(c, dy: 1, lines: 6), (0, -20));
      expect(convert(c, dx: -1, chars: 1), (-120, 0));
    });

    test('100 pixels are a notch at 3 lines per notch', () {
      final c = WheelConverter();
      expect(convert(c, dy: 100, pixels: true), (0, -120));
      expect(convert(c, dx: -100, pixels: true), (-120, 0));
      // More lines per notch: fewer units for the same distance.
      expect(convert(c, dy: 100, pixels: true, lines: 6), (0, -60));
    });

    test('small pixel deltas accumulate', () {
      final c = WheelConverter();
      var total = 0;
      for (var i = 0; i < 10; i++) {
        final (_, v) = convert(c, dy: 1, pixels: true);
        expect(v, inInclusiveRange(-2, 0));
        total += v;
      }
      // 10 pixels are 12 units.
      expect(total, -12);
    });

    test('a reversal starts afresh', () {
      final c = WheelConverter();
      expect(convert(c, dy: 2, pixels: true), (0, -2)); // 2.4: keeps 0.4
      expect(convert(c, dy: -1, pixels: true), (0, 1)); // 1.2, not 1.2 - 0.4
    });

    test('a disabled or page setting falls back to 3', () {
      final c = WheelConverter();
      expect(convert(c, dy: 3, lines: 0), (0, -120));
      expect(convert(c, dy: 3, lines: wheelPageScroll), (0, -120));
    });

    test('reset forgets fractions', () {
      final c = WheelConverter();
      convert(c, dy: 1, pixels: true);
      c.reset();
      final (_, v) = convert(c, dy: 4, pixels: true); // 4.8
      expect(v, -4);
    });
  });
}
