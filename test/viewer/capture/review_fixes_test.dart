// Tests for the capture review fixes: release on app lifecycle changes,
// buttons held through a release, the driving finger, soft keyboard
// dismissal in a Scaffold, the web context menu, sticky modifiers while
// paused, shortcuts with held modifiers, stylus hover and removal, a new
// viewer's text input, and composing text before a click.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/src/viewer/capture/context_menu.dart';
import 'package:remote_input/src/viewer/capture/text_bridge.dart';
import 'package:remote_input/testing.dart';

import 'support.dart';

const _ctrl = HidModifier.controlLeft;
const _alt = HidModifier.altLeft;
const _shift = HidModifier.shiftLeft;

InjectedKey _down(int usage) => InjectedKey(usage, down: true);
InjectedKey _up(int usage) => InjectedKey(usage, down: false);

final _windows = TargetPlatformVariant.only(TargetPlatform.windows);
final _macOS = TargetPlatformVariant.only(TargetPlatform.macOS);

void main() {
  tearDown(RemoteInputHost.stopAll);

  Widget capture(
    RemoteInputViewer v, {
    RemoteInputCaptureController? controller,
    TouchMode touchMode = TouchMode.direct,
  }) => RemoteInputCapture(
    viewer: v,
    controller: controller,
    touchMode: touchMode,
    child: picture,
  );

  Future<TestGesture> mouse(WidgetTester tester, Offset at) async {
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: at);
    return g;
  }

  group('H3: the app losing the foreground', () {
    Future<void> holdAndLeave(
      WidgetTester tester,
      Harness h,
      LogicalKeyboardKey modifier,
      AppLifecycleState state,
    ) async {
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      // The modifier goes down; Tab never arrives (the OS takes Alt+Tab or
      // Cmd+Tab).
      await tester.sendKeyDownEvent(modifier);
      await h.settle(tester);
      tester.binding.handleAppLifecycleStateChanged(state);
      await h.settle(tester);
    }

    for (final (variant, modifier, usage) in [
      (
        TargetPlatformVariant.only(TargetPlatform.iOS),
        LogicalKeyboardKey.metaLeft,
        HidModifier.metaLeft,
      ),
      (_windows, LogicalKeyboardKey.altLeft, _alt),
    ]) {
      testWidgets('inactive releases keys and buttons held on the host', (
        tester,
      ) async {
        final h = Harness();
        await h.start(tester, capture);
        const p = Offset(400, 300);
        final g = await mouse(tester, p);
        await g.down(p);
        await holdAndLeave(tester, h, modifier, AppLifecycleState.inactive);
        expect(h.events, [
          InjectedButton(at(p), PointerButton.left, down: true),
          _down(usage),
          _up(usage),
          InjectedButton(at(p), PointerButton.left, down: false),
        ]);

        // Back again: the late releases aren't sent, and the next key is.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await tester.sendKeyUpEvent(modifier);
        await g.up();
        expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isTrue);
        await h.settle(tester);
        expect(h.events.skip(4), [_down(usageEnter), _up(usageEnter)]);
        await g.removePointer();
        await h.finish(tester);
      }, variant: variant);
    }

    testWidgets('on Android, hidden releases and inactive alone does not', (
      tester,
    ) async {
      final h = Harness(viewerPlatform: PeerPlatform.android);
      await h.start(tester, capture);
      await holdAndLeave(
        tester,
        h,
        LogicalKeyboardKey.altLeft,
        AppLifecycleState.inactive,
      );
      expect(h.events, [_down(_alt)]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await h.settle(tester);
      expect(h.events, [_down(_alt), _up(_alt)]);
      await h.finish(tester);
    });
  });

  group('M2: a button held through a release', () {
    testWidgets('is not pressed again after a pause', (tester) async {
      final h = Harness();
      await h.start(tester, capture);
      const p = Offset(400, 300);
      final g = await mouse(tester, p);
      await g.down(p);
      await h.settle(tester);
      h.session.pause();
      await h.settle(tester);
      h.session.resume();
      await h.settle(tester);
      h.platform.injector.clear();

      // Still held: moving neither presses it nor drags.
      await g.moveTo(const Offset(450, 320));
      await g.up();
      await h.settle(tester);
      expect(h.events, isEmpty);

      // The next click is sent.
      await tester.pump(const Duration(seconds: 1));
      await g.down(p);
      await g.up();
      await h.settle(tester);
      expect(h.buttons, [
        InjectedButton(at(p), PointerButton.left, down: true),
        InjectedButton(at(p), PointerButton.left, down: false),
      ]);
      await g.removePointer();
      await h.finish(tester);
    });

    testWidgets('let go while paused, the next press is sent', (tester) async {
      final h = Harness();
      await h.start(tester, capture);
      const p = Offset(400, 300);
      final g = await mouse(tester, p);
      await g.down(p);
      await h.settle(tester);
      h.session.pause();
      await h.settle(tester);
      await g.up();
      h.session.resume();
      await h.settle(tester);
      h.platform.injector.clear();
      await g.down(p);
      await g.up();
      await h.settle(tester);
      expect(h.buttons, hasLength(2));
      await g.removePointer();
      await h.finish(tester);
    });

    testWidgets('is not pressed again after focus loss', (tester) async {
      final h = Harness();
      await h.start(tester, capture);
      const p = Offset(400, 300);
      final g = await mouse(tester, p);
      await g.down(p);
      await h.settle(tester);
      FocusManager.instance.primaryFocus!.unfocus();
      await h.settle(tester);
      h.platform.injector.clear();
      await g.moveTo(const Offset(450, 320));
      await g.up();
      await h.settle(tester);
      expect(h.events, isEmpty);
      await g.removePointer();
      await h.finish(tester);
    });
  });

  group('M1: a second finger during a direct drag', () {
    testWidgets('does not take the drag over', (tester) async {
      final h = Harness();
      await h.start(tester, capture);
      const from = Offset(100, 200);
      final a = await tester.startGesture(from, pointer: 1);
      for (var i = 0; i < 3; i++) {
        await a.moveBy(const Offset(20, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      // A stray finger lands far away, moves and lifts.
      final b = await tester.startGesture(const Offset(700, 450), pointer: 2);
      await b.moveBy(const Offset(-30, -30));
      await tester.pump(const Duration(milliseconds: 16));
      await b.up();
      await a.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 16));
      await a.up();
      await h.settle(tester);
      expect(h.buttons, [
        InjectedButton(at(from), PointerButton.left, down: true),
        InjectedButton(
          at(const Offset(180, 200)),
          PointerButton.left,
          down: false,
        ),
      ]);
      // Every move followed the first finger.
      expect(
        h.events.whereType<InjectedMove>().every(
          (m) => m.point.dx < at(const Offset(200, 200)).dx,
        ),
        isTrue,
      );
      await h.finish(tester);
    });

    testWidgets('the driving finger lifting ends the drag for good', (
      tester,
    ) async {
      final h = Harness();
      await h.start(tester, capture);
      const from = Offset(100, 200);
      final a = await tester.startGesture(from, pointer: 1);
      await a.moveBy(const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 16));
      final b = await tester.startGesture(const Offset(700, 450), pointer: 2);
      await a.up();
      await h.settle(tester);
      expect(h.buttons, hasLength(2));
      h.platform.injector.clear();
      await b.moveBy(const Offset(-50, 0));
      await tester.pump(const Duration(milliseconds: 16));
      await b.up();
      await h.settle(tester);
      expect(h.events, isEmpty);
      await h.finish(tester);
    });
  });

  testWidgets('M3: a soft keyboard dismissed inside a Scaffold is noticed', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final h = Harness(viewerPlatform: PeerPlatform.android);
    final controller = RemoteInputCaptureController();
    addTearDown(controller.dispose);
    // The harness puts the capture in a Scaffold's body, which doesn't see
    // the keyboard's inset.
    await h.start(tester, (v) => capture(v, controller: controller));
    controller.showSoftKeyboard();
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 900);
    await tester.pump();
    expect(controller.isSoftKeyboardRequested, isTrue);
    expect(tester.testTextInput.hasAnyClients, isTrue);
    // The back button lowers it.
    tester.view.resetViewInsets();
    await tester.pump();
    expect(controller.isSoftKeyboardRequested, isFalse);
    expect(tester.testTextInput.hasAnyClients, isFalse);
    await h.finish(tester);
  });

  group('M4: the browser context menu', () {
    var disabled = 0;
    var enabled = 0;
    var appTurnedItOff = false;

    setUp(() {
      disabled = 0;
      enabled = 0;
      appTurnedItOff = false;
      CaptureContextMenu.applies = true;
      CaptureContextMenu.disable = () async => disabled++;
      CaptureContextMenu.enable = () async => enabled++;
      CaptureContextMenu.menuEnabled = () => !appTurnedItOff;
    });
    tearDown(() {
      CaptureContextMenu.applies = false;
      CaptureContextMenu.disable = BrowserContextMenu.disableContextMenu;
      CaptureContextMenu.enable = BrowserContextMenu.enableContextMenu;
      CaptureContextMenu.menuEnabled = () => BrowserContextMenu.enabled;
    });

    Widget two(RemoteInputViewer v) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: capture(v)),
        Expanded(
          child: RemoteInputCapture(
            viewer: v,
            autofocus: false,
            child: picture,
          ),
        ),
      ],
    );

    testWidgets('is off while any capture is active, once', (tester) async {
      final h = Harness();
      await h.start(tester, two);
      expect(CaptureContextMenu.holders, 2);
      expect((disabled, enabled), (1, 0));
      h.session.pause();
      await h.settle(tester);
      expect(CaptureContextMenu.holders, 0);
      expect((disabled, enabled), (1, 1));
      h.session.resume();
      await h.settle(tester);
      expect((disabled, enabled), (2, 1));
      await h.finish(tester);
      expect(CaptureContextMenu.holders, 0);
      expect((disabled, enabled), (2, 2));
    });

    testWidgets('is left alone if the app turned it off', (tester) async {
      appTurnedItOff = true;
      final h = Harness();
      await h.start(tester, two);
      await h.finish(tester);
      expect((disabled, enabled), (0, 0));
      expect(CaptureContextMenu.holders, 0);
    });
  });

  group('the key bar', () {
    late RemoteInputCaptureController controller;
    setUp(() => controller = RemoteInputCaptureController());
    tearDown(() => controller.dispose());

    Widget both(RemoteInputViewer v) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: capture(v, controller: controller)),
        RemoteKeyBar(viewer: v, controller: controller),
      ],
    );

    Finder bar(String label) => find.descendant(
      of: find.byType(RemoteKeyBar),
      matching: find.text(label),
    );

    Future<void> tapKey(WidgetTester tester, String label) async {
      await tester.ensureVisible(bar(label));
      await tester.tap(bar(label), warnIfMissed: false);
      await tester.pump();
    }

    testWidgets('M6: sticky modifiers are ignored while paused', (
      tester,
    ) async {
      final h = Harness();
      await h.start(tester, both);
      h.session.pause();
      await h.settle(tester);
      await tapKey(tester, 'Ctrl');
      controller.toggleStickyModifier(_shift);
      expect(controller.stickyModifierBits, 0);
      h.session.resume();
      await h.settle(tester);
      await tapKey(tester, 'Tab');
      await h.settle(tester);
      expect(h.events, [_down(usageTab), _up(usageTab)]);
      await h.finish(tester);
    });

    testWidgets('M6: a bar without a capture lets go of sticky modifiers', (
      tester,
    ) async {
      final h = Harness();
      await h.start(
        tester,
        (v) => Align(
          alignment: Alignment.bottomCenter,
          child: RemoteKeyBar(viewer: v, controller: controller),
        ),
      );
      await tapKey(tester, 'Ctrl');
      await tapKey(tester, 'Ctrl');
      expect(controller.stickyModifier(_ctrl), StickyModifierState.locked);
      h.session.pause();
      await h.settle(tester);
      expect(controller.stickyModifierBits, 0);
      await h.finish(tester);
    });

    testWidgets('L1: Send keys keeps a locked modifier held on the host', (
      tester,
    ) async {
      final h = Harness();
      await h.start(tester, both);
      await tapKey(tester, 'Ctrl');
      await tapKey(tester, 'Ctrl');
      await tapKey(tester, 'Keys…');
      await tester.tap(find.widgetWithText(MenuItemButton, 'Alt+Tab'));
      await tester.pumpAndSettle();
      await h.settle(tester);
      expect(h.events, [
        _down(_ctrl),
        _down(_alt),
        _down(usageTab),
        _up(usageTab),
        _up(_alt),
      ]);
      expect(controller.stickyModifier(_ctrl), StickyModifierState.locked);
      await tapKey(tester, 'Ctrl');
      await h.settle(tester);
      expect(h.events.last, _up(_ctrl));
      await h.finish(tester);
    });
  });

  group('L2: a stylus', () {
    testWidgets('hovering with its barrel button only moves the pointer', (
      tester,
    ) async {
      final h = Harness();
      await h.start(tester, capture);
      const p = Offset(300, 300);
      const q = Offset(320, 310);
      await tester.sendEventToBinding(
        const PointerAddedEvent(
          kind: PointerDeviceKind.stylus,
          device: 7,
          position: p,
        ),
      );
      for (final at in [p, q]) {
        await tester.sendEventToBinding(
          PointerHoverEvent(
            kind: PointerDeviceKind.stylus,
            device: 7,
            pointer: 70,
            position: at,
            buttons: kSecondaryStylusButton,
          ),
        );
      }
      await tester.sendEventToBinding(
        const PointerRemovedEvent(
          kind: PointerDeviceKind.stylus,
          device: 7,
          pointer: 70,
          position: q,
        ),
      );
      await h.settle(tester);
      expect(h.buttons, isEmpty);
      expect(h.events.last, InjectedMove(at(q)));
      await h.finish(tester);
    });

    testWidgets('leaving range while drawing ends the drag', (tester) async {
      final h = Harness();
      await h.start(tester, capture);
      const from = Offset(200, 200);
      final g = await tester.createGesture(kind: PointerDeviceKind.stylus);
      await g.down(from);
      await g.moveBy(const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 16));
      await g.removePointer();
      await h.settle(tester);
      expect(h.buttons, [
        InjectedButton(at(from), PointerButton.left, down: true),
        InjectedButton(
          at(const Offset(240, 200)),
          PointerButton.left,
          down: false,
        ),
      ]);
      await h.finish(tester);
    });
  });

  testWidgets('a removed mouse lets go of its buttons', (tester) async {
    final h = Harness();
    await h.start(tester, capture);
    const p = Offset(400, 300);
    final g = await mouse(tester, p);
    await g.down(p);
    await g.removePointer();
    await h.settle(tester);
    expect(h.buttons, [
      InjectedButton(at(p), PointerButton.left, down: true),
      InjectedButton(at(p), PointerButton.left, down: false),
    ]);
    await h.finish(tester);
  });

  testWidgets('L5: a new viewer attaches or detaches the text input', (
    tester,
  ) async {
    final first = Harness();
    final waiting = RemoteInputViewer(link: MemoryInputLink.pair().viewer);
    await first.start(tester, capture);
    expect(tester.testTextInput.hasAnyClients, isTrue);

    Future<void> show(RemoteInputViewer v) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SizedBox.expand(child: capture(v))),
      ),
    );

    await show(waiting);
    expect(tester.testTextInput.hasAnyClients, isFalse);
    await show(first.viewer);
    expect(tester.testTextInput.hasAnyClients, isTrue);
    await waiting.close();
    await first.finish(tester);
  }, variant: _macOS);

  group('L7: composing text before a click', () {
    testWidgets('an Android word is committed before a tap', (tester) async {
      final h = Harness(viewerPlatform: PeerPlatform.android);
      final controller = RemoteInputCaptureController();
      addTearDown(controller.dispose);
      await h.start(tester, (v) => capture(v, controller: controller));
      controller.showSoftKeyboard();
      await tester.pump();
      await h.type(tester, 'a ');
      await h.compose(tester, 'hel');
      expect(find.text('hel'), findsOneWidget);
      await h.settle(tester);
      expect(h.events, [const InjectedText('a ')]);

      const p = Offset(300, 300);
      await tester.tapAt(p);
      await h.settle(tester);
      expect(h.events.skip(1), [
        const InjectedText('hel'),
        InjectedButton(at(p), PointerButton.left, down: true),
        InjectedButton(at(p), PointerButton.left, down: false),
      ]);
      expect(find.text('hel'), findsNothing);
      // The platform was told the composition is over.
      final set = tester.testTextInput.log.lastWhere(
        (c) => c.method == 'TextInput.setEditingState',
      );
      final state = set.arguments as Map;
      expect(state['text'], CaptureTextInput.placeholder);
      expect(state['composingBase'], -1);

      // What's typed next goes after it, once.
      await h.type(tester, 'x');
      await h.settle(tester);
      expect(h.events.last, const InjectedText('x'));
      expect(h.events.whereType<InjectedText>(), hasLength(3));
      await h.finish(tester);
    });

    testWidgets('an IME composition is committed before a mouse click', (
      tester,
    ) async {
      final h = Harness();
      await h.start(tester, capture);
      await h.compose(tester, 'か');
      const p = Offset(300, 300);
      final g = await mouse(tester, p);
      await g.down(p);
      await g.up();
      await h.settle(tester);
      expect(h.events, [
        const InjectedText('か'),
        InjectedButton(at(p), PointerButton.left, down: true),
        InjectedButton(at(p), PointerButton.left, down: false),
      ]);
      await g.removePointer();
      await h.finish(tester);
    }, variant: _macOS);
  });
}
