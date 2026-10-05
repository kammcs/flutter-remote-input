import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/src/viewer/capture/text_bridge.dart';
import 'package:remote_input/testing.dart';

import 'support.dart';

const _shift = HidModifier.shiftLeft;
const _ctrl = HidModifier.controlLeft;
const _alt = HidModifier.altLeft;
const _altRight = HidModifier.altRight;

InjectedKey _down(int usage) => InjectedKey(usage, down: true);
InjectedKey _up(int usage) => InjectedKey(usage, down: false);

/// A desktop viewer: the text input attaches as soon as the capture has
/// focus.
final _desktop = TargetPlatformVariant.only(TargetPlatform.macOS);

void main() {
  tearDown(RemoteInputHost.stopAll);

  Widget capture(
    RemoteInputViewer v, {
    KeyboardMode mode = KeyboardMode.auto,
    RemoteInputCaptureController? controller,
    ShortcutActivator? releaseShortcut,
  }) => RemoteInputCapture(
    viewer: v,
    keyboardMode: mode,
    controller: controller,
    releaseShortcut: releaseShortcut,
    touchMode: TouchMode.direct,
    child: picture,
  );

  group('auto mode', () {
    testWidgets(
      'letters go by text, Enter, arrows and Ctrl+C physically, none twice',
      (tester) async {
        final h = Harness();
        await h.start(tester, capture);
        expect(tester.testTextInput.hasAnyClients, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        // A printable key is left to the platform's text input (unhandled),
        // which commits it.
        expect(
          await tester.sendKeyDownEvent(
            LogicalKeyboardKey.keyH,
            character: 'h',
          ),
          isFalse,
        );
        await h.type(tester, 'h');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyH);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        expect(
          await tester.sendKeyDownEvent(
            LogicalKeyboardKey.keyI,
            character: 'I',
          ),
          isFalse,
        );
        await h.type(tester, 'I');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyI);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

        expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isTrue);
        expect(await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft), isTrue);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyC), isTrue);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

        // Emoji and anything else the text input commits.
        await h.type(tester, '👋🏽');
        await h.settle(tester);
        expect(h.events, [
          const InjectedText('h'),
          _down(_shift),
          const InjectedText('I'),
          _up(_shift),
          _down(usageEnter),
          _up(usageEnter),
          _down(usageArrowLeft),
          _up(usageArrowLeft),
          _down(_ctrl),
          _down(usageC),
          _up(usageC),
          _up(_ctrl),
          const InjectedText('👋🏽'),
        ]);
        await h.finish(tester);
      },
      variant: _desktop,
    );

    testWidgets('a held key repeats physically', (tester) async {
      final h = Harness();
      await h.start(tester, capture);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await h.settle(tester);
      expect(h.events, [
        _down(usageArrowLeft),
        const InjectedKey(usageArrowLeft, down: true, repeat: true),
        _up(usageArrowLeft),
      ]);
      await h.finish(tester);
    }, variant: _desktop);

    testWidgets('Caps Lock is not forwarded; Alt shortcuts are', (
      tester,
    ) async {
      final h = Harness();
      await h.start(tester, capture);
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.capsLock), isFalse);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      expect(
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'å'),
        isTrue,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await h.settle(tester);
      expect(h.events, [_down(_alt), _down(usageA), _up(usageA), _up(_alt)]);
      await h.finish(tester);
    }, variant: _desktop);

    testWidgets(
      'AltGr characters go by text, without the host seeing Ctrl+Alt',
      (tester) async {
        final h = Harness();
        await h.start(tester, capture);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altRight);
        expect(
          await tester.sendKeyDownEvent(
            LogicalKeyboardKey.keyQ,
            character: '@',
          ),
          isFalse,
        );
        await h.type(tester, '@');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyQ);
        await h.settle(tester);
        expect(h.events, [
          _down(_ctrl),
          _down(_altRight),
          _up(_ctrl),
          _up(_altRight),
          const InjectedText('@'),
        ]);

        // Still holding them, a key without a character is a shortcut
        // again: the modifiers go back down first.
        h.platform.injector.clear();
        // (The simulator would give T a character; Ctrl+Alt+T has none.)
        expect(
          await tester.sendKeyEvent(LogicalKeyboardKey.keyT, character: ''),
          isTrue,
        );
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altRight);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await h.settle(tester);
        expect(h.events, [
          _down(_ctrl),
          _down(_altRight),
          _down(0x00070017),
          _up(0x00070017),
          _up(_altRight),
          _up(_ctrl),
        ]);
        await h.finish(tester);
      },
      variant: _desktop,
    );

    testWidgets('IME composing shows locally, and only the commit is sent', (
      tester,
    ) async {
      final h = Harness();
      await h.start(tester, capture);
      await h.compose(tester, 'か');
      expect(find.text('か'), findsOneWidget);
      // While composing, Enter belongs to the IME.
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isFalse);
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.space), isFalse);
      await h.compose(tester, '家');
      await h.settle(tester);
      expect(h.events, isEmpty);
      await h.commitComposition(tester, '家');
      await h.settle(tester);
      expect(h.events, [const InjectedText('家')]);
      expect(find.text('家'), findsNothing);
      await h.finish(tester);
    }, variant: _desktop);

    testWidgets(
      'a dead key is left to the platform, which commits the result',
      (tester) async {
        final h = Harness();
        await h.start(tester, capture);
        // Option+E on a Mac, or ´ on many layouts: no character yet.
        expect(
          await tester.sendKeyDownEvent(
            LogicalKeyboardKey.keyE,
            physicalKey: PhysicalKeyboardKey.quote,
            character: '',
          ),
          isFalse,
        );
        await tester.sendKeyUpEvent(
          LogicalKeyboardKey.keyE,
          physicalKey: PhysicalKeyboardKey.quote,
        );
        await h.compose(tester, '´');
        expect(
          await tester.sendKeyDownEvent(
            LogicalKeyboardKey.keyE,
            character: 'é',
          ),
          isFalse,
        );
        await h.commitComposition(tester, 'é');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyE);
        await h.settle(tester);
        expect(h.events, [const InjectedText('é')]);
        await h.finish(tester);
      },
      variant: _desktop,
    );

    testWidgets('editing deltas are sent once', (tester) async {
      final h = Harness();
      await h.start(tester, capture);
      const p = CaptureTextInput.placeholder;
      await h.sendDeltas(tester, [insertionDelta(p, 'x')]);
      await h.sendDeltas(tester, [
        insertionDelta('${p}x', 'ü', composing: true),
      ]);
      expect(find.text('ü'), findsOneWidget);
      await h.sendDeltas(tester, [
        {
          ...insertionDelta('${p}x', 'ü'),
          'deltaText': '',
          'deltaStart': -1,
          'deltaEnd': -1,
          'oldText': '${p}xü',
        },
      ]);
      await h.settle(tester);
      expect(h.events, [const InjectedText('x'), const InjectedText('ü')]);
      await h.finish(tester);
    }, variant: _desktop);
  });

  testWidgets('physical mode sends every key by position, with no text input', (
    tester,
  ) async {
    final h = Harness();
    await h.start(tester, (v) => capture(v, mode: KeyboardMode.physical));
    expect(tester.testTextInput.hasAnyClients, isFalse);
    expect(
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'a'),
      isTrue,
    );
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.capsLock), isTrue);
    await h.settle(tester);
    expect(h.events, [
      _down(usageA),
      _up(usageA),
      _down(usageCapsLock),
      _up(usageCapsLock),
    ]);
    await h.finish(tester);
  }, variant: _desktop);

  testWidgets('text mode types Alt characters by text', (tester) async {
    final h = Harness();
    await h.start(tester, (v) => capture(v, mode: KeyboardMode.text));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    expect(
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA, character: 'å'),
      isFalse,
    );
    await h.type(tester, 'å');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    // Ctrl shortcuts are still keys.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyC), isTrue);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await h.settle(tester);
    expect(h.events, [
      _down(_alt),
      _up(_alt),
      const InjectedText('å'),
      _down(_ctrl),
      _down(usageC),
      _up(usageC),
      _up(_ctrl),
    ]);
    await h.finish(tester);
  }, variant: _desktop);

  group('phones', () {
    testWidgets('a soft keyboard types text, Backspace and Enter', (
      tester,
    ) async {
      final h = Harness(viewerPlatform: PeerPlatform.android);
      final controller = RemoteInputCaptureController();
      addTearDown(controller.dispose);
      await h.start(tester, (v) => capture(v, controller: controller));
      // No soft keyboard until asked for.
      expect(tester.testTextInput.hasAnyClients, isFalse);
      controller.showSoftKeyboard();
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      expect(controller.isSoftKeyboardRequested, isTrue);

      await h.type(tester, 'hey');
      await h.delete(tester); // iOS: a deletion edit
      await h.type(tester, '\n'); // a Return that inserts a line break
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      // Android sends Backspace as a key event: it goes physically, once.
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.backspace), isTrue);
      await h.settle(tester);
      expect(h.events, [
        const InjectedText('hey'),
        _down(usageBackspace),
        _up(usageBackspace),
        _down(usageEnter),
        _up(usageEnter),
        _down(usageEnter),
        _up(usageEnter),
        _down(usageBackspace),
        _up(usageBackspace),
      ]);

      controller.hideSoftKeyboard();
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isFalse);
      await h.finish(tester);
    });

    testWidgets('an input action with a hardware Enter held is not sent', (
      tester,
    ) async {
      // The web engine performs the input action on a hardware Enter as
      // well as delivering the key.
      final h = Harness(viewerPlatform: PeerPlatform.android);
      final controller = RemoteInputCaptureController();
      addTearDown(controller.dispose);
      await h.start(tester, (v) => capture(v, controller: controller));
      controller.showSoftKeyboard();
      await tester.pump();
      expect(await tester.sendKeyDownEvent(LogicalKeyboardKey.enter), isTrue);
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await h.settle(tester);
      expect(h.events, [_down(usageEnter), _up(usageEnter)]);
      await h.finish(tester);
    });

    testWidgets('a hardware keyboard types with the soft keyboard down', (
      tester,
    ) async {
      final h = Harness(viewerPlatform: PeerPlatform.android);
      await h.start(tester, capture);
      expect(
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'a'),
        isTrue,
      );
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.tab), isTrue);
      await h.settle(tester);
      expect(h.events, [
        const InjectedText('a'),
        _down(usageTab),
        _up(usageTab),
      ]);
      await h.finish(tester);
    });
  });

  testWidgets(
    'a new viewer and focus node are picked up, releasing the old viewer',
    (tester) async {
      final first = Harness();
      // A second viewer with no host: it stays waiting.
      final second = RemoteInputViewer(link: MemoryInputLink.pair().viewer);
      final controller = RemoteInputCaptureController();
      addTearDown(controller.dispose);
      Widget tree(RemoteInputViewer v, {FocusNode? focusNode}) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: RemoteInputCapture(
              viewer: v,
              controller: controller,
              focusNode: focusNode,
              child: picture,
            ),
          ),
          RemoteKeyBar(viewer: v, controller: controller),
        ],
      );
      await first.start(tester, tree);
      controller.toggleStickyModifier(_ctrl);
      await tester.pump();
      await first.settle(tester);
      expect(first.events, [_down(_ctrl)]);

      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox.expand(child: tree(second, focusNode: node)),
          ),
        ),
      );
      await first.settle(tester);
      expect(first.events, [_down(_ctrl), _up(_ctrl)]);
      expect(controller.stickyModifierBits, 0);
      expect(tester.takeException(), isNull);

      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isTrue);
      // The new viewer isn't active, so keys are the app's.
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isFalse);
      expect(second.stats.sent, 0);
      await second.close();
      await first.finish(tester);
    },
    variant: _desktop,
  );

  group('focus', () {
    testWidgets('losing focus releases what is held on the host', (
      tester,
    ) async {
      final h = Harness();
      await h.start(tester, capture);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: const Offset(400, 300));
      await g.down(const Offset(400, 300));
      await h.settle(tester);
      expect(h.events, hasLength(2));
      FocusManager.instance.primaryFocus!.unfocus();
      await h.settle(tester);
      expect(h.events.skip(2), [
        _up(_shift),
        InjectedButton(
          at(const Offset(400, 300)),
          PointerButton.left,
          down: false,
        ),
      ]);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      // Later releases aren't sent again.
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await g.up();
      await h.settle(tester);
      expect(h.events, hasLength(4));
      await g.removePointer();
      await h.finish(tester);
    }, variant: _desktop);

    testWidgets('the release shortcut gives up focus and is not sent', (
      tester,
    ) async {
      final h = Harness();
      await h.start(
        tester,
        (v) => capture(
          v,
          releaseShortcut: const SingleActivator(LogicalKeyboardKey.f12),
        ),
      );
      final focus = Focus.of(
        tester.element(
          find
              .descendant(
                of: find.byType(RemoteInputCapture),
                matching: find.byType(Listener),
              )
              .first,
        ),
      );
      expect(focus.hasFocus, isTrue);
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.f12), isTrue);
      await tester.pump();
      expect(focus.hasFocus, isFalse);
      // Keys now go to the app.
      expect(
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'a'),
        isFalse,
      );
      await h.settle(tester);
      expect(h.events, isEmpty);
      await h.finish(tester);
    }, variant: _desktop);

    testWidgets('while the session is paused, keys are the app\'s', (
      tester,
    ) async {
      final h = Harness();
      await h.start(tester, capture);
      h.session.pause();
      await h.settle(tester);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isFalse);
      h.session.resume();
      await h.settle(tester);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isTrue);
      await h.settle(tester);
      expect(h.events, [_down(usageEnter), _up(usageEnter)]);
      await h.finish(tester);
    }, variant: _desktop);
  });
}
