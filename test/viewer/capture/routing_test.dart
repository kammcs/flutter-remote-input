import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/src/viewer/capture/geometry.dart';
import 'package:remote_input/src/viewer/capture/key_routing.dart';

const _a = 0x00070004;
const _q = 0x00070014;
const _e = 0x00070008;
const _enter = 0x00070028;
const _f5 = 0x0007003E;
const _keypad7 = 0x0007005F;
const _hiragana = 0x00070088;

KeyRoute _route(
  KeyboardMode mode,
  int usage, {
  String? character,
  int modifiers = 0,
  bool composing = false,
  bool processKey = false,
  bool altGr = true,
}) => routeKeyDown(
  mode: mode,
  usage: usage,
  character: character,
  modifiers: modifiers,
  composing: composing,
  processKey: processKey,
  altGr: altGr,
);

void main() {
  group('routeKeyDown in auto mode', () {
    const auto = KeyboardMode.auto;

    test('printable characters go by text, with or without Shift', () {
      expect(_route(auto, _a, character: 'a'), KeyRoute.text);
      expect(
        _route(auto, _a, character: 'A', modifiers: KeyModifiers.shift),
        KeyRoute.text,
      );
      expect(_route(auto, HidKey.space, character: ' '), KeyRoute.text);
    });

    test('non-printing keys and modifiers go physically', () {
      for (final usage in [
        _enter,
        HidKey.escape,
        HidKey.backspace,
        HidKey.tab,
        HidKey.arrowLeft,
        HidKey.home,
        HidKey.delete,
        _f5,
        HidModifier.shiftLeft,
        HidModifier.metaRight,
      ]) {
        expect(_route(auto, usage), KeyRoute.physical, reason: '$usage');
      }
    });

    test('Ctrl, Alt and Meta make shortcuts', () {
      for (final m in [
        KeyModifiers.control,
        KeyModifiers.alt,
        KeyModifiers.meta,
        KeyModifiers.meta | KeyModifiers.shift,
      ]) {
        expect(
          _route(auto, _a, character: 'å', modifiers: m),
          KeyRoute.physical,
        );
      }
    });

    test('AltGr characters go by text', () {
      expect(
        _route(
          auto,
          _q,
          character: '@',
          modifiers: KeyModifiers.control | KeyModifiers.alt,
        ),
        KeyRoute.text,
      );
      // Ctrl+Alt with no character is a shortcut.
      expect(
        _route(auto, _q, modifiers: KeyModifiers.control | KeyModifiers.alt),
        KeyRoute.physical,
      );
    });

    test('Ctrl+Alt is AltGr only where the platform means it', () {
      expect(ctrlAltIsAltGr(TargetPlatform.windows), isTrue);
      expect(ctrlAltIsAltGr(TargetPlatform.linux), isTrue);
      for (final p in [
        TargetPlatform.macOS,
        TargetPlatform.iOS,
        TargetPlatform.android,
      ]) {
        expect(ctrlAltIsAltGr(p), isFalse);
      }
      // A Mac's Ctrl+Option+Q is a shortcut, whatever character it makes.
      for (final mode in [KeyboardMode.auto, KeyboardMode.text]) {
        expect(
          _route(
            mode,
            _q,
            character: 'œ',
            modifiers: KeyModifiers.control | KeyModifiers.alt,
            altGr: false,
          ),
          KeyRoute.physical,
        );
      }
    });

    test('dead keys and IMEs stay with the platform', () {
      expect(_route(auto, _e), KeyRoute.text); // a dead key: composed
      expect(
        _route(auto, _a, character: 'a', composing: true),
        KeyRoute.platform,
      );
      expect(_route(auto, _enter, composing: true), KeyRoute.platform);
      expect(_route(auto, _a, processKey: true), KeyRoute.platform);
      expect(_route(auto, _hiragana), KeyRoute.platform);
    });

    test('lock keys are not forwarded', () {
      expect(_route(auto, HidKey.capsLock), KeyRoute.platform);
      expect(_route(auto, HidKey.numLock), KeyRoute.platform);
    });

    test('the keypad without Num Lock navigates', () {
      expect(_route(auto, _keypad7, character: '7'), KeyRoute.text);
      expect(_route(auto, _keypad7), KeyRoute.physical);
    });
  });

  test('physical mode sends every key physically', () {
    for (final usage in [_a, HidKey.capsLock, _hiragana, _enter]) {
      expect(
        _route(KeyboardMode.physical, usage, character: 'a', composing: true),
        KeyRoute.physical,
      );
    }
  });

  test('text mode types Alt and Option characters and dead keys', () {
    const text = KeyboardMode.text;
    expect(
      _route(text, _a, character: 'å', modifiers: KeyModifiers.alt),
      KeyRoute.text,
    );
    expect(_route(text, _e, modifiers: KeyModifiers.alt), KeyRoute.text);
    expect(
      _route(text, _a, character: 'a', modifiers: KeyModifiers.control),
      KeyRoute.physical,
    );
    expect(_route(text, HidKey.capsLock), KeyRoute.platform);
    expect(_route(text, _enter), KeyRoute.physical);
  });

  test('isPrintableCharacter rejects control and function-key characters', () {
    expect(isPrintableCharacter('a'), isTrue);
    expect(isPrintableCharacter('👋'), isTrue);
    expect(isPrintableCharacter(null), isFalse);
    expect(isPrintableCharacter(''), isFalse);
    expect(isPrintableCharacter('\x03'), isFalse);
    expect(isPrintableCharacter('\x7F'), isFalse);
    expect(isPrintableCharacter(''), isFalse); // NSF1FunctionKey
  });

  test('usKeyForCharacter maps US-layout characters', () {
    expect(usKeyForCharacter('c'), (0x00070006, false));
    expect(usKeyForCharacter('Z'), (0x0007001D, true));
    expect(usKeyForCharacter('0'), (HidKey.digit0, false));
    expect(usKeyForCharacter('!'), (HidKey.digit1, true));
    expect(usKeyForCharacter('/'), (0x00070038, false));
    expect(usKeyForCharacter('?'), (0x00070038, true));
    expect(usKeyForCharacter('é'), isNull);
  });

  group('contentRectFor', () {
    const viewport = Size(800, 600);
    const picture = Size(1920, 1080);

    test('every BoxFit', () {
      final expected = <BoxFit, Rect>{
        BoxFit.contain: const Rect.fromLTWH(0, 75, 800, 450),
        BoxFit.fitWidth: const Rect.fromLTWH(0, 75, 800, 450),
        BoxFit.scaleDown: const Rect.fromLTWH(0, 75, 800, 450),
        BoxFit.fill: const Rect.fromLTWH(0, 0, 800, 600),
        BoxFit.cover: const Rect.fromLTWH(-400 / 3, 0, 3200 / 3, 600),
        BoxFit.fitHeight: const Rect.fromLTWH(-400 / 3, 0, 3200 / 3, 600),
        BoxFit.none: const Rect.fromLTWH(-560, -240, 1920, 1080),
      };
      for (final MapEntry(key: fit, value: rect) in expected.entries) {
        final r = contentRectFor(viewport, picture, fit);
        expect(r.left, closeTo(rect.left, 1e-9), reason: '$fit');
        expect(r.top, closeTo(rect.top, 1e-9), reason: '$fit');
        expect(r.width, closeTo(rect.width, 1e-9), reason: '$fit');
        expect(r.height, closeTo(rect.height, 1e-9), reason: '$fit');
      }
      expect(BoxFit.values, hasLength(expected.length));
    });

    test('pillarboxes a tall picture and keeps small ones unscaled', () {
      expect(
        contentRectFor(viewport, const Size(300, 600), BoxFit.contain),
        const Rect.fromLTWH(250, 0, 300, 600),
      );
      expect(
        contentRectFor(viewport, const Size(400, 300), BoxFit.scaleDown),
        const Rect.fromLTWH(200, 150, 400, 300),
      );
      expect(
        RemoteInputCapture.computeContentRect(viewport, null, BoxFit.contain),
        Offset.zero & viewport,
      );
    });
  });

  test('ViewZoom maps both ways and stays over the viewport', () {
    const zoom = ViewZoom(scale: 2, offset: Offset(-400, -300));
    expect(zoom.toChild(const Offset(400, 300)), const Offset(400, 300));
    expect(zoom.toWidget(Offset.zero), const Offset(-400, -300));
    expect(
      const ViewZoom(
        scale: 2,
        offset: Offset(100, -900),
      ).clampedTo(const Size(800, 600)),
      const ViewZoom(scale: 2, offset: Offset(0, -600)),
    );
    expect(
      const ViewZoom(
        scale: 0.5,
        offset: Offset(10, 10),
      ).clampedTo(const Size(800, 600)),
      ViewZoom.identity,
    );
  });
}
