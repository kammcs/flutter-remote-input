import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/testing.dart';

import 'support.dart';

void main() {
  tearDown(RemoteInputHost.stopAll);

  Widget capture(
    RemoteInputViewer v, {
    BoxFit fit = BoxFit.contain,
    Size? contentSize,
    Rect? contentRect,
  }) => RemoteInputCapture(
    viewer: v,
    fit: fit,
    contentSize: contentSize,
    contentRect: contentRect,
    touchMode: TouchMode.direct,
    child: picture,
  );

  Future<TestGesture> mouse(
    WidgetTester tester,
    Offset at, {
    int buttons = kPrimaryMouseButton,
  }) async {
    final g = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: buttons,
    );
    await g.addPointer(location: at);
    return g;
  }

  testWidgets('a click lands where it was aimed, inside the letterbox', (
    tester,
  ) async {
    final h = Harness();
    await h.start(tester, capture);
    const p = Offset(200, 300);
    final g = await mouse(tester, p);
    await g.down(p);
    await g.up();
    await h.settle(tester);
    expect(h.events, [
      InjectedButton(at(p), PointerButton.left, down: true),
      InjectedButton(at(p), PointerButton.left, down: false),
    ]);
    await g.removePointer();
    await h.finish(tester);
  });

  testWidgets('hover is sent inside the picture only', (tester) async {
    final h = Harness();
    await h.start(tester, capture);
    final g = await mouse(tester, const Offset(400, 20));
    await g.moveTo(const Offset(400, 40)); // the top bar
    await h.settle(tester);
    expect(h.events, isEmpty);
    await g.moveTo(const Offset(400, 300));
    await h.settle(tester);
    expect(h.events, [InjectedMove(at(const Offset(400, 300)))]);
    // A press on the bar isn't sent, nor its drag or release.
    await g.moveTo(const Offset(400, 40));
    await g.down(const Offset(400, 40));
    await g.moveTo(const Offset(400, 300));
    await g.up();
    await h.settle(tester);
    expect(h.events, hasLength(1));
    await g.removePointer();
    await h.finish(tester);
  });

  testWidgets('a drag past the edge is clamped to it', (tester) async {
    final h = Harness();
    await h.start(tester, capture);
    const start = Offset(400, 300);
    final g = await mouse(tester, start);
    await g.down(start);
    await g.moveTo(const Offset(400, 20)); // above the picture
    await h.settle(tester);
    await g.moveTo(const Offset(-50, 590)); // past the bottom-left corner
    await h.settle(tester);
    await g.up();
    await h.settle(tester);
    expect(h.events, [
      InjectedButton(at(start), PointerButton.left, down: true),
      InjectedMove(
        landing(const Offset(0.5, 0)),
        heldButtons: {PointerButton.left},
      ),
      InjectedMove(
        landing(const Offset(0, 1)),
        heldButtons: {PointerButton.left},
      ),
      InjectedButton(
        landing(const Offset(0, 1)),
        PointerButton.left,
        down: false,
      ),
    ]);
    await g.removePointer();
    await h.finish(tester);
  });

  testWidgets('counts clicks within the interval and slop', (tester) async {
    final h = Harness();
    await h.start(tester, capture);
    const p = Offset(300, 300);
    final g = await mouse(tester, p);
    Future<void> click(Offset q) async {
      await g.moveTo(q);
      await g.down(q);
      await g.up();
      await tester.pump(const Duration(milliseconds: 100));
    }

    await click(p);
    await click(p);
    await click(p + const Offset(2, 2));
    await click(p);
    await tester.pump(const Duration(milliseconds: 600));
    await click(p); // too late
    await click(p + const Offset(40, 0)); // too far
    await h.settle(tester);
    expect(h.buttons.where((b) => b.down).map((b) => b.clickCount), [
      1,
      2,
      3,
      4,
      1,
      1,
    ]);
    expect(h.buttons.where((b) => !b.down).map((b) => b.clickCount), [
      1,
      2,
      3,
      4,
      1,
      1,
    ]);
    await g.removePointer();
    await h.finish(tester);
  });

  testWidgets('sends the right, middle, back and forward buttons', (
    tester,
  ) async {
    final h = Harness();
    await h.start(tester, capture);
    const p = Offset(400, 300);
    for (final (bits, button) in [
      (kSecondaryMouseButton, PointerButton.right),
      (kMiddleMouseButton, PointerButton.middle),
      (kBackMouseButton, PointerButton.back),
      (kForwardMouseButton, PointerButton.forward),
    ]) {
      final g = await mouse(tester, p, buttons: bits);
      await g.down(p);
      await g.up();
      await g.removePointer();
      await h.settle(tester);
      expect(h.buttons.last, InjectedButton(at(p), button, down: false));
    }
    expect(h.buttons, hasLength(8));
    await h.finish(tester);
  });

  testWidgets('scroll wheels and trackpads scroll, in pixels', (tester) async {
    final h = Harness();
    await h.start(tester, capture);
    const p = Offset(400, 300);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(p));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
    // A second notch within the interval is coalesced and sent after it.
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
    await h.settle(tester);
    // Outside the picture, the wheel is the app's.
    await tester.sendEventToBinding(pointer.hover(const Offset(400, 20)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
    await h.settle(tester);
    final wheels = h.events.whereType<InjectedWheel>().toList();
    expect(wheels, [
      InjectedWheel(at(p), dx: 0, dy: 120, unit: WheelUnit.pixel),
      InjectedWheel(at(p), dx: 0, dy: 120, unit: WheelUnit.pixel),
    ]);

    h.platform.injector.clear();
    final pad = await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await pad.panZoomStart(p);
    for (var i = 1; i <= 5; i++) {
      // Fingers moving up reveal what's below.
      await pad.panZoomUpdate(p, pan: Offset(-i * 2.5, -i * 10), scale: 1.2);
      await tester.pump(const Duration(milliseconds: 40));
    }
    await pad.panZoomEnd();
    await h.settle(tester);
    final pans = h.events.whereType<InjectedWheel>().toList();
    expect(pans.fold<int>(0, (s, w) => s + w.dy), 50);
    expect(pans.fold<int>(0, (s, w) => s + w.dx), 12); // 12.5, truncated
    expect(pans.every((w) => w.point == at(p)), isTrue);
    await h.finish(tester);
  });

  testWidgets('maps through each fit, and an explicit content rect', (
    tester,
  ) async {
    const p = Offset(100, 500);
    for (final (fit, rect) in [
      (BoxFit.cover, const Rect.fromLTWH(-400 / 3, 0, 3200 / 3, 600)),
      (BoxFit.fill, const Rect.fromLTWH(0, 0, 800, 600)),
      (BoxFit.none, const Rect.fromLTWH(-560, -240, 1920, 1080)),
    ]) {
      final h = Harness();
      await h.start(tester, (v) => capture(v, fit: fit));
      final g = await mouse(tester, p);
      await g.down(p);
      await g.up();
      await g.removePointer();
      await h.settle(tester);
      expect(h.buttons.first.point, closeToPoint(at(p, rect)), reason: '$fit');
      await h.finish(tester);
    }

    const custom = Rect.fromLTWH(50, 100, 400, 300);
    const q = Offset(250, 250);
    final h = Harness();
    await h.start(tester, (v) => capture(v, contentRect: custom));
    final g = await mouse(tester, q);
    await g.down(q);
    await g.up();
    await g.removePointer();
    await h.settle(tester);
    expect(h.buttons.first.point, at(q, custom));
    await h.finish(tester);
  });

  testWidgets('a contentSize overrides the surface size', (tester) async {
    final h = Harness();
    // A 4:3 frame pillarboxed in 800×600 fills it exactly.
    await h.start(
      tester,
      (v) => capture(v, contentSize: const Size(1024, 768)),
    );
    const p = Offset(100, 50);
    final g = await mouse(tester, p);
    await g.down(p);
    await g.up();
    await g.removePointer();
    await h.settle(tester);
    expect(h.buttons.first.point, at(p, const Rect.fromLTWH(0, 0, 800, 600)));
    await h.finish(tester);
  });

  testWidgets('sends nothing, and takes nothing from the app, while paused', (
    tester,
  ) async {
    final h = Harness();
    final list = ScrollController();
    await h.start(
      tester,
      capture,
      wrap: (c) => ListView(
        controller: list,
        children: [
          SizedBox(height: 600, child: c),
          const SizedBox(height: 900),
        ],
      ),
    );
    h.session.pause();
    await h.settle(tester);
    expect(h.viewer.state, isA<SessionPaused>());
    await tester.dragFrom(const Offset(400, 400), const Offset(0, -200));
    await h.settle(tester);
    expect(h.events, isEmpty);
    expect(list.offset, greaterThan(0));

    // Active again: the capture takes the drag, and the list stays.
    list.jumpTo(0);
    h.session.resume();
    await h.settle(tester);
    await tester.dragFrom(const Offset(400, 400), const Offset(0, -200));
    await h.settle(tester);
    expect(list.offset, 0);
    expect(h.buttons, hasLength(2));
    await h.finish(tester);
  });
}
