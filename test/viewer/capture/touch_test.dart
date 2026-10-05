import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/testing.dart';

import 'support.dart';

const _cursorKey = Key('cursor');

void main() {
  tearDown(RemoteInputHost.stopAll);

  Widget trackpad(RemoteInputViewer v) => RemoteInputCapture(
    viewer: v,
    touchMode: TouchMode.trackpad,
    cursorBuilder: (_) => const SizedBox(key: _cursorKey, width: 4, height: 4),
    child: picture,
  );

  Widget direct(RemoteInputViewer v) => RemoteInputCapture(
    viewer: v,
    touchMode: TouchMode.direct,
    child: picture,
  );

  Future<void> tap(WidgetTester tester, Offset p, {int pointer = 1}) async {
    final g = await tester.startGesture(p, pointer: pointer);
    await g.up();
  }

  Future<void> drag(
    WidgetTester tester,
    Offset from,
    Offset step,
    int steps, {
    int pointer = 1,
  }) async {
    final g = await tester.startGesture(from, pointer: pointer);
    for (var i = 0; i < steps; i++) {
      await g.moveBy(step);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
  }

  /// Two fingers from [a] and [b], each moved by its step [steps] times.
  Future<void> twoFingers(
    WidgetTester tester,
    Offset a,
    Offset b,
    Offset stepA,
    Offset stepB,
    int steps,
  ) async {
    final ga = await tester.startGesture(a, pointer: 1);
    final gb = await tester.startGesture(b, pointer: 2);
    for (var i = 0; i < steps; i++) {
      await ga.moveBy(stepA);
      await gb.moveBy(stepB);
      await tester.pump(const Duration(milliseconds: 40));
    }
    await ga.up();
    await gb.up();
  }

  group('trackpad mode', () {
    testWidgets('draws a cursor at the centre and taps click at it', (
      tester,
    ) async {
      final h = Harness();
      await h.start(tester, trackpad);
      expect(tester.getTopLeft(find.byKey(_cursorKey)), const Offset(400, 300));
      await tap(tester, const Offset(100, 500)); // anywhere
      await h.settle(tester);
      final c = landing(const Offset(0.5, 0.5));
      expect(h.events, [
        InjectedButton(c, PointerButton.left, down: true),
        InjectedButton(c, PointerButton.left, down: false),
      ]);
      await h.finish(tester);
    });

    testWidgets('one finger moves the cursor relatively', (tester) async {
      final h = Harness();
      await h.start(tester, trackpad);
      // 80 px across an 800 px picture, at 1.25×: an eighth of its width.
      await drag(tester, const Offset(100, 500), const Offset(20, 0), 4);
      await h.settle(tester);
      expect(h.buttons, isEmpty);
      expect(h.events.last, InjectedMove(landing(const Offset(0.625, 0.5))));
      expect(tester.getTopLeft(find.byKey(_cursorKey)), const Offset(500, 300));
      // The cursor stops at the edge.
      await drag(tester, const Offset(100, 500), const Offset(0, 200), 4);
      await h.settle(tester);
      expect(h.events.last, InjectedMove(landing(const Offset(0.625, 1))));
      await h.finish(tester);
    });

    testWidgets('double tap double-clicks; two-finger tap right-clicks', (
      tester,
    ) async {
      final h = Harness();
      await h.start(tester, trackpad);
      await tap(tester, const Offset(300, 300));
      await tester.pump(const Duration(milliseconds: 100));
      await tap(tester, const Offset(310, 305));
      await tester.pump(const Duration(milliseconds: 400));
      final a = await tester.startGesture(const Offset(300, 300), pointer: 3);
      final b = await tester.startGesture(const Offset(360, 300), pointer: 4);
      await a.up();
      await b.up();
      await h.settle(tester);
      final c = landing(const Offset(0.5, 0.5));
      expect(h.buttons, [
        InjectedButton(c, PointerButton.left, down: true),
        InjectedButton(c, PointerButton.left, down: false),
        InjectedButton(c, PointerButton.left, down: true, clickCount: 2),
        InjectedButton(c, PointerButton.left, down: false, clickCount: 2),
        InjectedButton(c, PointerButton.right, down: true),
        InjectedButton(c, PointerButton.right, down: false),
      ]);
      await h.finish(tester);
    });

    testWidgets('tap then drag is a left-button drag', (tester) async {
      final h = Harness();
      await h.start(tester, trackpad);
      await tap(tester, const Offset(300, 300));
      await tester.pump(const Duration(milliseconds: 100));
      await drag(tester, const Offset(300, 300), const Offset(20, 0), 2);
      await h.settle(tester);
      final c = landing(const Offset(0.5, 0.5));
      final end = landing(const Offset(0.5625, 0.5));
      expect(h.buttons, [
        InjectedButton(c, PointerButton.left, down: true),
        InjectedButton(c, PointerButton.left, down: false),
        InjectedButton(c, PointerButton.left, down: true),
        InjectedButton(end, PointerButton.left, down: false),
      ]);
      final moves = h.events.whereType<InjectedMove>().toList();
      expect(moves, isNotEmpty);
      expect(
        moves.every((m) => m.heldButtons.contains(PointerButton.left)),
        isTrue,
      );
      await h.finish(tester);
    });

    testWidgets('two fingers scroll at the cursor', (tester) async {
      final h = Harness();
      await h.start(tester, trackpad);
      await twoFingers(
        tester,
        const Offset(300, 400),
        const Offset(500, 400),
        const Offset(0, -20),
        const Offset(0, -20),
        3,
      );
      await h.settle(tester);
      final wheels = h.events.whereType<InjectedWheel>().toList();
      expect(wheels.fold<int>(0, (s, w) => s + w.dy), 60);
      expect(
        wheels.every((w) => w.point == landing(const Offset(0.5, 0.5))),
        isTrue,
      );
      expect(h.buttons, isEmpty);
      await h.finish(tester);
    });
  });

  group('direct mode', () {
    testWidgets('a tap clicks at the finger, twice for a double tap', (
      tester,
    ) async {
      final h = Harness();
      await h.start(tester, direct);
      const p = Offset(200, 150);
      await tap(tester, p);
      await tester.pump(const Duration(milliseconds: 100));
      await tap(tester, p + const Offset(5, 5));
      await tester.pump(const Duration(milliseconds: 400));
      await tap(tester, const Offset(400, 20)); // the letterbox: not sent
      await h.settle(tester);
      expect(h.buttons, [
        InjectedButton(at(p), PointerButton.left, down: true),
        InjectedButton(at(p), PointerButton.left, down: false),
        InjectedButton(
          at(p + const Offset(5, 5)),
          PointerButton.left,
          down: true,
          clickCount: 2,
        ),
        InjectedButton(
          at(p + const Offset(5, 5)),
          PointerButton.left,
          down: false,
          clickCount: 2,
        ),
      ]);
      await h.finish(tester);
    });

    testWidgets('a long press right-clicks', (tester) async {
      final h = Harness();
      await h.start(tester, direct);
      const p = Offset(300, 200);
      final g = await tester.startGesture(p);
      await tester.pump(const Duration(milliseconds: 600));
      await g.up();
      await h.settle(tester);
      expect(h.buttons, [
        InjectedButton(at(p), PointerButton.right, down: true),
        InjectedButton(at(p), PointerButton.right, down: false),
      ]);
      await h.finish(tester);
    });

    testWidgets('one finger drags with the left button', (tester) async {
      final h = Harness();
      await h.start(tester, direct);
      const from = Offset(100, 200);
      await drag(tester, from, const Offset(20, 0), 5);
      await h.settle(tester);
      expect(h.buttons, [
        InjectedButton(at(from), PointerButton.left, down: true),
        InjectedButton(
          at(const Offset(200, 200)),
          PointerButton.left,
          down: false,
        ),
      ]);
      expect(
        h.events.whereType<InjectedMove>().every(
          (m) => m.heldButtons.contains(PointerButton.left),
        ),
        isTrue,
      );
      await h.finish(tester);
    });

    testWidgets('two fingers scroll where they are', (tester) async {
      final h = Harness();
      await h.start(tester, direct);
      await twoFingers(
        tester,
        const Offset(200, 300),
        const Offset(400, 300),
        const Offset(0, 25),
        const Offset(0, 25),
        4,
      );
      await h.settle(tester);
      final wheels = h.events.whereType<InjectedWheel>().toList();
      expect(wheels.fold<int>(0, (s, w) => s + w.dy), -100);
      expect(
        wheels.every((w) => w.point == at(const Offset(300, 300))),
        isTrue,
      );
      await h.finish(tester);
    });

    testWidgets('pinch zooms the local view, and taps map through it', (
      tester,
    ) async {
      final h = Harness();
      await h.start(tester, direct);
      // Spread from 100 px apart to 200 around the centre: 2×.
      await twoFingers(
        tester,
        const Offset(350, 300),
        const Offset(450, 300),
        const Offset(-10, 0),
        const Offset(10, 0),
        5,
      );
      await h.settle(tester);
      expect(h.events, isEmpty);
      final transform = tester.widget<Transform>(
        find.descendant(
          of: find.byType(RemoteInputCapture),
          matching: find.byType(Transform),
        ),
      );
      expect(transform.transform.getMaxScaleOnAxis(), closeTo(2, 1e-9));

      const p = Offset(200, 150);
      await tap(tester, p);
      await h.settle(tester);
      // (200, 150) on screen is (300, 225) in the unzoomed view.
      expect(
        h.buttons.first,
        InjectedButton(
          at(const Offset(300, 225)),
          PointerButton.left,
          down: true,
        ),
      );
      await h.finish(tester);
    });

    testWidgets('a stylus works directly even in trackpad mode', (
      tester,
    ) async {
      final h = Harness();
      await h.start(tester, trackpad);
      const p = Offset(200, 150);
      final g = await tester.startGesture(p, kind: PointerDeviceKind.stylus);
      await g.up();
      await h.settle(tester);
      expect(
        h.buttons.first,
        InjectedButton(at(p), PointerButton.left, down: true),
      );
      await h.finish(tester);
    });
  });

  testWidgets('phones default to trackpad mode, larger screens to direct', (
    tester,
  ) async {
    final h = Harness();
    await h.start(tester, (v) => RemoteInputCapture(viewer: v, child: picture));
    final before = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .where((p) => p.size == const Size(14, 21));
    expect(before, isEmpty);

    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pump();
    final after = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .where((p) => p.size == const Size(14, 21));
    expect(after, hasLength(1));
    await h.finish(tester);
  });
}
