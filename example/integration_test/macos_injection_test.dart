// The macOS injection test (roadmap M3, docs/design.md §12).
//
// IT MOVES THE REAL POINTER AND TYPES REAL KEYS. Everything goes into this
// app's own window, but run it only when the machine's owner says it's free,
// and keep your hands off the mouse, trackpad and keyboard while it runs:
// local input pauses the session, and the test fails, by design.
//
// It needs the Accessibility permission for the test app (System Settings >
// Privacy & Security > Accessibility). Run, from example/:
//
//   flutter test integration_test/macos_injection_test.dart -d macos
//
// Besides injection, it checks open question 2 on the device: the package's
// own events must not count as local input (the session never pauses).
// Skipped on other platforms.

import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/testing.dart';

const _window = MethodChannel('remote_input_example/window');

const _keyA = 0x00070004;
const _enter = 0x00070028;
const _backspace = 0x0007002A;

/// What the test window received.
final class _Probe {
  final List<PointerEvent> pointer = [];
  final List<KeyEvent> keys = [];
  final TextEditingController text = TextEditingController();
  final FocusNode focus = FocusNode();
  int doubleTaps = 0;
  int submitted = 0;

  T last<T extends PointerEvent>() => pointer.whereType<T>().last;

  bool keyHandler(KeyEvent e) {
    keys.add(e);
    return false;
  }
}

Widget _app(_Probe p) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: Scaffold(
    body: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: p.pointer.add,
      onPointerUp: p.pointer.add,
      onPointerMove: p.pointer.add,
      onPointerHover: p.pointer.add,
      onPointerSignal: p.pointer.add,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: () => p.doubleTaps++,
        child: Align(
          alignment: const Alignment(0, 0.8),
          child: SizedBox(
            width: 320,
            child: TextField(
              controller: p.text,
              focusNode: p.focus,
              onSubmitted: (_) => p.submitted++,
            ),
          ),
        ),
      ),
    ),
  ),
);

Future<void> _settle(WidgetTester tester, [int ms = 80]) async {
  await Future<void>.delayed(Duration(milliseconds: ms));
  await tester.pump();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('injects pointer, keys and text into its own window', (
    tester,
  ) async {
    final status = await RemoteInputPermissions.status();
    expect(
      status,
      RemoteInputPermissionStatus.granted,
      reason:
          'Grant Accessibility to the test app first (System Settings > '
          'Privacy & Security > Accessibility).',
    );

    binding.shouldPropagateDevicePointerEvents = true;
    final probe = _Probe();
    HardwareKeyboard.instance.addHandler(probe.keyHandler);
    ControlSession? session;
    RemoteInputViewer? viewer;
    try {
      await tester.pumpWidget(_app(probe));
      await _settle(tester, 300);

      final info = (await _window.invokeMapMethod<String, Object?>(
        'describe',
      ))!;
      final windowId = info['windowNumber']! as int;
      final insets = EdgeInsets.fromLTRB(
        (info['insetLeft']! as num).toDouble(),
        (info['insetTop']! as num).toDouble(),
        (info['insetRight']! as num).toDouble(),
        (info['insetBottom']! as num).toDouble(),
      );
      final view = tester.view;
      final size = view.physicalSize / view.devicePixelRatio;
      Offset at(Offset n) => Offset(n.dx * size.width, n.dy * size.height);

      final pair = MemoryInputLink.pair();
      final host = RemoteInputHost();
      expect(host.checkAvailable(), isNull);
      final states = <SessionState>[];
      session = host.enable(
        link: pair.host,
        surface: SharedSurface.window(windowId, contentInsets: insets),
        // The test injects into its own window, which the host otherwise
        // protects (HostOptions.protectHostWindows).
        options: const HostOptions(protectHostWindows: false),
      );
      session.stateChanges.listen(states.add);
      viewer = RemoteInputViewer(link: pair.viewer);
      await viewer.stateChanges
          .firstWhere((s) => s is SessionActive)
          .timeout(const Duration(seconds: 5));

      // A first click activates the app, so its window takes keys.
      viewer.click(const Offset(0.75, 0.2));
      await _settle(tester, 500);

      // Corners and centre: within one point (success criterion 2).
      for (final n in const [
        Offset(0.01, 0.01),
        Offset(0.99, 0.01),
        Offset(0.01, 0.99),
        Offset(0.99, 0.99),
        Offset(0.5, 0.5),
      ]) {
        viewer.pointerMove(n);
        await _settle(tester);
        final hover = probe.last<PointerHoverEvent>();
        expect(
          (hover.position - at(n)).distance,
          lessThanOrEqualTo(1.0),
          reason: 'move to $n',
        );
      }

      // A click at the centre.
      probe.pointer.clear();
      viewer.click(const Offset(0.5, 0.5));
      await _settle(tester);
      final down = probe.last<PointerDownEvent>();
      expect(down.buttons, kPrimaryButton);
      expect(
        (down.position - at(const Offset(0.5, 0.5))).distance,
        lessThan(1),
      );
      expect(probe.pointer.whereType<PointerUpEvent>(), isNotEmpty);

      // A right click.
      viewer.click(const Offset(0.3, 0.6), button: PointerButton.right);
      await _settle(tester);
      expect(probe.last<PointerDownEvent>().buttons, kSecondaryButton);
      await _settle(tester, 500); // Past the double-tap timeout.

      // A double click (kCGMouseEventClickState 1, then 2).
      viewer.click(const Offset(0.25, 0.25));
      await _settle(tester, 40);
      viewer.click(const Offset(0.25, 0.25), clickCount: 2);
      await _settle(tester, 500);
      expect(probe.doubleTaps, 1);

      // A drag: moves with the button held arrive as moves with buttons.
      probe.pointer.clear();
      const from = Offset(0.2, 0.4);
      const to = Offset(0.6, 0.7);
      viewer.pointerButton(from, PointerButton.left, down: true);
      for (var i = 1; i <= 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
        viewer.pointerMove(Offset.lerp(from, to, i / 10)!);
      }
      await _settle(tester, 40);
      viewer.pointerButton(to, PointerButton.left, down: false);
      await _settle(tester);
      final moves = probe.pointer.whereType<PointerMoveEvent>().toList();
      expect(moves, isNotEmpty);
      expect(moves.every((m) => m.buttons & kPrimaryButton != 0), isTrue);
      expect((moves.last.position - at(to)).distance, lessThanOrEqualTo(1.0));
      expect(
        (probe.last<PointerUpEvent>().position - at(to)).distance,
        lessThanOrEqualTo(1.0),
      );

      // Scrolling: positive dy reveals what's below, in pixels and lines.
      probe.pointer.clear();
      viewer.wheel(const Offset(0.5, 0.3), dy: 40);
      await _settle(tester);
      viewer.wheel(const Offset(0.5, 0.3), dy: -2, unit: WheelUnit.line);
      await _settle(tester);
      final scrolls = probe.pointer.whereType<PointerScrollEvent>().toList();
      expect(scrolls.length, greaterThanOrEqualTo(2));
      expect(scrolls.first.scrollDelta.dy, greaterThan(0));
      expect(scrolls.last.scrollDelta.dy, lessThan(0));

      // Keys, with Shift by flags (open question 10).
      probe.focus.requestFocus();
      await _settle(tester, 200);
      probe.keys.clear();
      viewer
        ..key(_keyA, KeyAction.down)
        ..key(_keyA, KeyAction.up)
        ..key(
          HidModifier.shiftLeft,
          KeyAction.down,
          modifiers: KeyModifiers.shift,
        )
        ..key(_keyA, KeyAction.down, modifiers: KeyModifiers.shift)
        ..key(_keyA, KeyAction.up, modifiers: KeyModifiers.shift)
        ..key(HidModifier.shiftLeft, KeyAction.up);
      await _settle(tester, 200);
      expect(probe.text.text, 'aA');
      final downs = probe.keys.whereType<KeyDownEvent>().toList();
      expect(
        downs.where((e) => e.physicalKey == PhysicalKeyboardKey.keyA).length,
        2,
      );
      expect(downs.map((e) => e.character), contains('A'));

      viewer
        ..key(_backspace, KeyAction.down)
        ..key(_backspace, KeyAction.up);
      await _settle(tester, 150);
      expect(probe.text.text, 'a');

      // Command+A selects all (Command by flags), Backspace clears it.
      viewer
        ..key(
          HidModifier.metaLeft,
          KeyAction.down,
          modifiers: KeyModifiers.meta,
        )
        ..key(_keyA, KeyAction.down, modifiers: KeyModifiers.meta)
        ..key(_keyA, KeyAction.up, modifiers: KeyModifiers.meta)
        ..key(HidModifier.metaLeft, KeyAction.up)
        ..key(_backspace, KeyAction.down)
        ..key(_backspace, KeyAction.up);
      await _settle(tester, 200);
      expect(probe.text.text, isEmpty);

      // Text by Unicode, in chunks of up to 20 UTF-16 units.
      const typed = 'héllo wörld — 👋 the quick brown fox 0123456789 ñ';
      viewer.text(typed);
      await _settle(tester, 800);
      expect(probe.text.text, typed);

      viewer
        ..key(_enter, KeyAction.down)
        ..key(_enter, KeyAction.up);
      await _settle(tester, 150);
      expect(probe.submitted, 1);

      // Nothing the package posted counted as local input (open question 2).
      expect(
        states.whereType<SessionPaused>(),
        isEmpty,
        reason:
            "The package's own events paused the session: "
            'set MacosActivityDetector.ownEventsReachHidState to true.',
      );

      session.stop();
      expect(session.state, const SessionStopped(StopReason.byHost));
      await _settle(tester, 100);
      expect(HardwareKeyboard.instance.physicalKeysPressed, isEmpty);
    } finally {
      session?.stop();
      await viewer?.close();
      HardwareKeyboard.instance.removeHandler(probe.keyHandler);
      binding.shouldPropagateDevicePointerEvents = false;
    }
  }, skip: !Platform.isMacOS);

  testWidgets('the permission API answers', (tester) async {
    expect(
      await RemoteInputPermissions.status(),
      isNot(RemoteInputPermissionStatus.unsupported),
    );
    expect(RemoteInputHost.isSupported, isTrue);
    final displays = await RemoteInputHost().displays();
    expect(displays.where((d) => d.isPrimary), hasLength(1));
    expect(displays.firstWhere((d) => d.isPrimary).bounds.topLeft, Offset.zero);
  }, skip: !Platform.isMacOS);
}
