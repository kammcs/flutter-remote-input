import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/src/host/macos/macos_events.dart';
import 'package:remote_input/src/keys/key_tables.g.dart';

void main() {
  group('modifier flags', () {
    test('none held: no flags', () {
      expect(macModifierFlags(const []), 0);
    });

    test('each modifier sets its mask and its side device bit', () {
      expect(macModifierFlags([HidModifier.shiftLeft]), 0x20002);
      expect(macModifierFlags([HidModifier.shiftRight]), 0x20004);
      expect(macModifierFlags([HidModifier.controlLeft]), 0x40001);
      expect(macModifierFlags([HidModifier.controlRight]), 0x42000);
      expect(macModifierFlags([HidModifier.altLeft]), 0x80020);
      expect(macModifierFlags([HidModifier.altRight]), 0x80040);
      expect(macModifierFlags([HidModifier.metaLeft]), 0x100008);
      expect(macModifierFlags([HidModifier.metaRight]), 0x100010);
    });

    test('combinations: both shifts, Command+Shift', () {
      expect(
        macModifierFlags([HidModifier.shiftLeft, HidModifier.shiftRight]),
        0x20006,
      );
      expect(
        macModifierFlags([HidModifier.metaLeft, HidModifier.shiftLeft]),
        MacEventFlags.command |
            MacEventFlags.shift |
            MacEventFlags.deviceLeftCommand |
            MacEventFlags.deviceLeftShift,
      );
    });

    test('non-modifier usages are ignored', () {
      expect(macModifierFlags([0x00070004, HidModifier.altLeft]), 0x80020);
    });

    test('every computed bit is inside the mask the native side owns', () {
      final all = macModifierFlags([
        for (var u = HidModifier.controlLeft; u <= HidModifier.metaRight; u++)
          u,
      ]);
      expect(all, MacEventFlags.modifierMask);
      // Caps Lock (alpha shift), Fn and the numeric-pad flag stay the
      // event's own.
      expect(MacEventFlags.modifierMask & 0x00010000, 0);
      expect(MacEventFlags.modifierMask & 0x00800000, 0);
      expect(MacEventFlags.modifierMask & 0x00200000, 0);
    });
  });

  group('mouse events', () {
    test('button numbers', () {
      expect(PointerButton.values.map(macButtonNumber), [0, 1, 2, 3, 4]);
    });

    test('down and up types per button', () {
      expect(macButtonEventType(PointerButton.left, down: true), 1);
      expect(macButtonEventType(PointerButton.left, down: false), 2);
      expect(macButtonEventType(PointerButton.right, down: true), 3);
      expect(macButtonEventType(PointerButton.right, down: false), 4);
      for (final b in [
        PointerButton.middle,
        PointerButton.back,
        PointerButton.forward,
      ]) {
        expect(macButtonEventType(b, down: true), 25);
        expect(macButtonEventType(b, down: false), 26);
      }
    });

    test('a move with no button is a plain move', () {
      expect(macMoveEvent({}), (type: MacEventType.mouseMoved, button: 0));
    });

    test('a move with a button held is that button\'s drag', () {
      expect(macMoveEvent({PointerButton.left}), (
        type: MacEventType.leftMouseDragged,
        button: 0,
      ));
      expect(macMoveEvent({PointerButton.right}), (
        type: MacEventType.rightMouseDragged,
        button: 1,
      ));
      expect(macMoveEvent({PointerButton.forward}), (
        type: MacEventType.otherMouseDragged,
        button: 4,
      ));
      expect(macMoveEvent({PointerButton.forward, PointerButton.middle}), (
        type: MacEventType.otherMouseDragged,
        button: 2,
      ));
    });

    test('left wins over right, right over the others', () {
      expect(
        macMoveEvent({PointerButton.right, PointerButton.left}).type,
        MacEventType.leftMouseDragged,
      );
      expect(
        macMoveEvent({PointerButton.back, PointerButton.right}).type,
        MacEventType.rightMouseDragged,
      );
    });
  });

  group('scrolling', () {
    test('units', () {
      expect(macScrollUnit(WheelUnit.pixel), 0);
      expect(macScrollUnit(WheelUnit.line), 1);
    });

    test('positive dy (reveal below) is a negative wheel1', () {
      expect(macWheels(dx: 0, dy: 120), (wheel1: -120, wheel2: 0));
      expect(macWheels(dx: 0, dy: -3), (wheel1: 3, wheel2: 0));
    });

    test('positive dx (reveal right) is a negative wheel2', () {
      expect(macWheels(dx: 40, dy: 0), (wheel1: 0, wheel2: -40));
    });

    test('clamped to 32-bit', () {
      expect(macWheels(dx: 0, dy: -0x100000000).wheel1, 0x7FFFFFFF);
    });
  });

  group('text chunks', () {
    test('short text is one chunk', () {
      expect(macTextChunks('hello'), ['hello'.codeUnits]);
    });

    test('empty text is no chunks', () {
      expect(macTextChunks(''), isEmpty);
    });

    test('at most 20 code units each, in order', () {
      final text = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ';
      final chunks = macTextChunks(text);
      expect(chunks.map((c) => c.length), [20, 20, 6]);
      expect(String.fromCharCodes(chunks.expand((c) => c)), text);
    });

    test('a surrogate pair is never split', () {
      // 19 ASCII units, then an emoji (a pair) straddling the boundary.
      final text = '${'x' * 19}😀${'y' * 5}';
      final chunks = macTextChunks(text);
      expect(chunks.first.length, 19);
      expect(String.fromCharCodes(chunks[1]).startsWith('😀'), isTrue);
      expect(String.fromCharCodes(chunks.expand((c) => c)), text);
      for (final c in chunks) {
        expect(c.length, lessThanOrEqualTo(macMaxTextUnits));
        expect(c.last >= 0xD800 && c.last <= 0xDBFF, isFalse);
      }
    });

    test('a run of emoji', () {
      final text = '😀' * 25;
      final chunks = macTextChunks(text);
      expect(chunks.every((c) => c.length == 20 || c.length == 10), isTrue);
      expect(String.fromCharCodes(chunks.expand((c) => c)), text);
    });

    test('maxUnits below 2 is rejected', () {
      expect(() => macTextChunks('a', maxUnits: 1), throwsArgumentError);
    });
  });

  group('key codes', () {
    test('letters, Return and the modifiers', () {
      expect(macKeyCode(0x00070004), 0x00); // A
      expect(macKeyCode(0x00070028), 0x24); // Return
      expect(macKeyCode(HidModifier.metaLeft), 0x37); // Command
      expect(macKeyCode(HidModifier.shiftRight), 0x3C);
    });

    test('usages with no Mac key have no code', () {
      expect(macKeyCode(0x00070046), isNull); // PrintScreen
      expect(macKeyCode(0x12345678), isNull);
    });

    test('the table maps to distinct key codes', () {
      final codes = hidToMacKeyCode.values.toList();
      expect(codes.toSet().length, codes.length);
    });
  });
}
