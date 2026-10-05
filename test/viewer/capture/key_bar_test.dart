import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/testing.dart';

import 'support.dart';

InjectedKey _down(int usage) => InjectedKey(usage, down: true);
InjectedKey _up(int usage) => InjectedKey(usage, down: false);

void main() {
  tearDown(RemoteInputHost.stopAll);

  late RemoteInputCaptureController controller;

  setUp(() => controller = RemoteInputCaptureController());
  tearDown(() => controller.dispose());

  Widget both(RemoteInputViewer v) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        child: RemoteInputCapture(
          viewer: v,
          controller: controller,
          touchMode: TouchMode.direct,
          child: picture,
        ),
      ),
      RemoteKeyBar(viewer: v, controller: controller),
    ],
  );

  Finder bar(String label) => find.descendant(
    of: find.byType(RemoteKeyBar),
    matching: find.text(label),
  );

  Future<void> tapKey(WidgetTester tester, String label) async {
    await tester.ensureVisible(bar(label));
    await tester.tap(bar(label));
    await tester.pump();
  }

  testWidgets('keys press and release', (tester) async {
    final h = Harness();
    await h.start(tester, both);
    await tapKey(tester, 'Esc');
    await tapKey(tester, 'Tab');
    await tapKey(tester, '←');
    await tapKey(tester, 'PgDn');
    await h.settle(tester);
    expect(h.events, [
      _down(usageEscape),
      _up(usageEscape),
      _down(usageTab),
      _up(usageTab),
      _down(usageArrowLeft),
      _up(usageArrowLeft),
      _down(0x0007004E),
      _up(0x0007004E),
    ]);
    await h.finish(tester);
  });

  testWidgets('a held arrow repeats', (tester) async {
    final h = Harness();
    await h.start(tester, both);
    final g = await tester.startGesture(tester.getCenter(bar('→')));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 120));
    await g.up();
    await h.settle(tester);
    final keys = h.keys;
    expect(keys.first, _down(0x0007004F));
    expect(keys.last, _up(0x0007004F));
    expect(keys.where((k) => k.repeat), hasLength(greaterThanOrEqualTo(2)));
    await h.finish(tester);
  });

  testWidgets('a latched modifier is released after the next key', (
    tester,
  ) async {
    final h = Harness();
    await h.start(tester, both);
    await tapKey(tester, 'Ctrl');
    expect(
      controller.stickyModifier(HidModifier.controlLeft),
      StickyModifierState.latched,
    );
    await tapKey(tester, 'Tab');
    await h.settle(tester);
    expect(h.events, [
      _down(HidModifier.controlLeft),
      _down(usageTab),
      _up(usageTab),
      _up(HidModifier.controlLeft),
    ]);
    expect(
      controller.stickyModifier(HidModifier.controlLeft),
      StickyModifierState.off,
    );
    await h.finish(tester);
  });

  testWidgets('a locked modifier stays until tapped again', (tester) async {
    final h = Harness();
    await h.start(tester, both);
    await tapKey(tester, 'Shift');
    await tapKey(tester, 'Shift');
    expect(
      controller.stickyModifier(HidModifier.shiftLeft),
      StickyModifierState.locked,
    );
    await tapKey(tester, '→');
    await tapKey(tester, '→');
    await tapKey(tester, 'Shift');
    await h.settle(tester);
    expect(h.events, [
      _down(HidModifier.shiftLeft),
      _down(0x0007004F),
      _up(0x0007004F),
      _down(0x0007004F),
      _up(0x0007004F),
      _up(HidModifier.shiftLeft),
    ]);
    await h.finish(tester);
  });

  testWidgets('sticky Ctrl turns soft-keyboard text into a shortcut', (
    tester,
  ) async {
    final h = Harness(viewerPlatform: PeerPlatform.android);
    await h.start(tester, both);
    await tester.tap(find.byIcon(Icons.keyboard));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    expect(find.byIcon(Icons.keyboard_hide), findsOneWidget);
    await tapKey(tester, 'Ctrl');
    await h.type(tester, 'c');
    await h.type(tester, 'd'); // no longer latched
    await h.settle(tester);
    expect(h.events, [
      _down(HidModifier.controlLeft),
      _down(usageC),
      _up(usageC),
      _up(HidModifier.controlLeft),
      const InjectedText('d'),
    ]);
    await tester.ensureVisible(find.byIcon(Icons.keyboard_hide));
    await tester.tap(find.byIcon(Icons.keyboard_hide));
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isFalse);
    expect(controller.isSoftKeyboardRequested, isFalse);
    await h.finish(tester);
  });

  testWidgets('sticky Shift applies to the next click', (tester) async {
    final h = Harness();
    await h.start(tester, both);
    await tapKey(tester, 'Shift');
    const p = Offset(400, 250);
    await tester.tapAt(p);
    await h.settle(tester);
    expect(h.events, [
      _down(HidModifier.shiftLeft),
      InjectedButton(at(p, _barContent), PointerButton.left, down: true),
      InjectedButton(at(p, _barContent), PointerButton.left, down: false),
      _up(HidModifier.shiftLeft),
    ]);
    await h.finish(tester);
  });

  testWidgets('the Send keys menu sends shortcuts the OS would take', (
    tester,
  ) async {
    final h = Harness();
    await h.start(tester, both);
    await tapKey(tester, 'Keys…');
    expect(find.text('Ctrl+Esc'), findsOneWidget);
    expect(find.text('Cmd+Tab'), findsNothing); // a Windows host
    await tester.tap(find.widgetWithText(MenuItemButton, 'Alt+Tab'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'Keys…');
    await tester.tap(find.widgetWithText(MenuItemButton, 'Win'));
    await tester.pumpAndSettle();
    await h.settle(tester);
    expect(h.events, [
      _down(HidModifier.altLeft),
      _down(usageTab),
      _up(usageTab),
      _up(HidModifier.altLeft),
      _down(HidModifier.metaLeft),
      _up(HidModifier.metaLeft),
    ]);
    await h.finish(tester);
  });

  testWidgets('a Mac host gets Command from an Android viewer', (tester) async {
    final h = Harness(
      viewerPlatform: PeerPlatform.android,
      hostPlatform: PeerPlatform.macos,
    );
    await h.start(tester, both);
    expect(bar('⌘ cmd'), findsOneWidget);
    expect(bar('⌥ opt'), findsOneWidget);
    await tapKey(tester, '⌘ cmd');
    await tapKey(tester, 'Tab');
    await tapKey(tester, 'Keys…');
    await tester.tap(find.widgetWithText(MenuItemButton, 'Cmd+Space'));
    await tester.pumpAndSettle();
    await h.settle(tester);
    // The host swaps Control and Command for a non-Apple viewer; the bar
    // swapped them first, so they arrive as labelled.
    expect(h.events, [
      _down(HidModifier.metaLeft),
      _down(usageTab),
      _up(usageTab),
      _up(HidModifier.metaLeft),
      _down(HidModifier.metaLeft),
      _down(0x0007002C),
      _up(0x0007002C),
      _up(HidModifier.metaLeft),
    ]);
    await h.finish(tester);
  });
}

/// The content rect when the key bar takes 44 px below the capture.
final Rect _barContent = RemoteInputCapture.computeContentRect(
  const Size(800, 556),
  const Size(1920, 1080),
  BoxFit.contain,
);
