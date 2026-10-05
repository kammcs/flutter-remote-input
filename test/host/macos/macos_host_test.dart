import 'dart:ui';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/src/host/macos/macos_events.dart';
import 'package:remote_input/src/host/macos/macos_host.dart';
import 'package:remote_input/src/host/macos/macos_native.dart';
import 'package:remote_input/testing.dart';

import 'fake_native.dart';

const usageA = 0x00070004;
const usageEnter = 0x00070028;
const keyCodeA = 0x00;
const keyCodeShift = 0x38;
const keyCodeCommand = 0x37;

MacosWindowInfo window({
  Rect bounds = const Rect.fromLTWH(100, 100, 800, 600),
  bool onScreen = true,
  int pid = 42,
  double scale = 2,
  List<MacosWindowRecord> above = const [],
}) => MacosWindowInfo(
  bounds: bounds,
  onScreen: onScreen,
  ownerPid: pid,
  scale: scale,
  above: above,
);

void main() {
  late FakeMacosNative native;
  setUp(() => native = FakeMacosNative());

  group('platform', () {
    test('reports macOS', () {
      expect(MacosHostPlatform(native).platform, PeerPlatform.macos);
    });

    test('unavailable without the Accessibility permission', () {
      final p = MacosHostPlatform(native);
      expect(p.checkAvailable(), isNull);
      native.access = false;
      expect(p.checkAvailable(), HostUnavailableReason.permissionDenied);
    });
  });

  group('injector', () {
    late MacosInputInjector injector;
    final pointed = <Offset>[];
    setUp(() {
      pointed.clear();
      injector = MacosInputInjector(native, onPointer: pointed.add);
    });

    test('a move with no button is a mouse move at the point', () {
      expect(
        injector.movePointer(const Offset(10.5, 20.25), heldButtons: {}),
        InjectResult.injected,
      );
      final m = native.mouse.single;
      expect(m.type, MacEventType.mouseMoved);
      expect(m.point, const Offset(10.5, 20.25));
      expect(m.flags, 0);
      expect(pointed, [const Offset(10.5, 20.25)]);
    });

    test('a move with the left button held is a drag', () {
      injector.movePointer(Offset.zero, heldButtons: {PointerButton.left});
      expect(native.mouse.single.type, MacEventType.leftMouseDragged);
    });

    test('buttons carry their number and click count', () {
      injector.pointerButton(
        const Offset(5, 5),
        PointerButton.left,
        down: true,
        clickCount: 2,
      );
      injector.pointerButton(
        const Offset(5, 5),
        PointerButton.back,
        down: true,
        clickCount: 1,
      );
      final m = native.mouse;
      expect((m[0].type, m[0].button, m[0].clickState), (1, 0, 2));
      expect((m[1].type, m[1].button, m[1].clickState), (25, 3, 1));
    });

    test('a click count below 1 is posted as 1', () {
      injector.pointerButton(
        Offset.zero,
        PointerButton.right,
        down: true,
        clickCount: 0,
      );
      expect(native.mouse.single.clickState, 1);
    });

    test('held modifiers ride on clicks (Command-click)', () {
      injector.key(HidModifier.metaLeft, down: true);
      injector.pointerButton(
        Offset.zero,
        PointerButton.left,
        down: true,
        clickCount: 1,
      );
      expect(
        native.mouse.single.flags,
        macModifierFlags([HidModifier.metaLeft]),
      );
    });

    test('a modifier key\'s own event carries the flags after it', () {
      injector.key(HidModifier.shiftLeft, down: true);
      injector.key(usageA, down: true);
      injector.key(usageA, down: false);
      injector.key(HidModifier.shiftLeft, down: false);
      injector.key(usageA, down: true);
      final k = native.keys;
      expect(k.map((c) => (c.keyCode, c.down, c.flags)), [
        (keyCodeShift, true, 0x20002),
        (keyCodeA, true, 0x20002),
        (keyCodeA, false, 0x20002),
        (keyCodeShift, false, 0),
        (keyCodeA, true, 0),
      ]);
    });

    test('repeats are marked; modifier repeats are not posted', () {
      injector.key(usageA, down: true);
      injector.key(usageA, down: true, repeat: true);
      injector.key(HidModifier.metaLeft, down: true);
      expect(
        injector.key(HidModifier.metaLeft, down: true, repeat: true),
        InjectResult.injected,
      );
      expect(native.keys.map((k) => (k.keyCode, k.autorepeat)), [
        (keyCodeA, false),
        (keyCodeA, true),
        (keyCodeCommand, false),
      ]);
    });

    test('a usage with no Mac key is unmapped and posts nothing', () {
      expect(injector.key(0x00070046, down: true), InjectResult.unmappedKey);
      expect(native.calls, isEmpty);
    });

    test(
      'a refused modifier press is not held, a release always is let go',
      () {
        native.postStatus = MacosStatus.permissionDenied;
        expect(
          injector.key(HidModifier.shiftLeft, down: true),
          InjectResult.permissionDenied,
        );
        native.postStatus = MacosStatus.ok;
        injector.key(usageA, down: true);
        expect(native.keys.single.flags, 0);
        injector.key(HidModifier.altLeft, down: true);
        native.postStatus = MacosStatus.failed;
        expect(
          injector.key(HidModifier.altLeft, down: false),
          InjectResult.failed,
        );
        native.postStatus = MacosStatus.ok;
        injector.key(usageEnter, down: true);
        expect(native.keys.last.flags, 0);
      },
    );

    test('scrolling at the pointer posts only the scroll, signs flipped', () {
      native.cursor = const Offset(50, 50);
      injector.wheel(
        const Offset(50.2, 50),
        dx: 0,
        dy: 120,
        unit: WheelUnit.pixel,
      );
      final s = native.calls.single as ScrollCall;
      expect((s.unit, s.wheel1, s.wheel2), (0, -120, 0));
      expect(s.point, const Offset(50.2, 50));
    });

    test('scrolling elsewhere moves the pointer there first', () {
      native.cursor = const Offset(0, 0);
      injector.wheel(
        const Offset(300, 200),
        dx: -2,
        dy: 0,
        unit: WheelUnit.line,
      );
      expect(native.calls.first, isA<MouseCall>());
      final s = native.calls.last as ScrollCall;
      expect((s.unit, s.wheel1, s.wheel2), (1, 0, 2));
      expect(pointed, [const Offset(300, 200)]);
    });

    test('the move before a scroll drags while a button is held', () {
      injector.pointerButton(
        Offset.zero,
        PointerButton.right,
        down: true,
        clickCount: 1,
      );
      native.cursor = Offset.zero;
      injector.wheel(const Offset(40, 40), dx: 0, dy: 1, unit: WheelUnit.line);
      expect(native.mouse.last.type, MacEventType.rightMouseDragged);
    });

    test('text is typed in chunks of at most 20 UTF-16 units', () {
      final text = 'Hello, wörld! 😀 ${'z' * 30}';
      expect(injector.text(text), InjectResult.injected);
      final chunks = native.calls.cast<TextCall>();
      expect(chunks.every((c) => c.units.length <= 20), isTrue);
      expect(chunks.map((c) => c.text).join(), text);
    });

    test('text stops at the first refused chunk', () {
      native.postStatus = MacosStatus.permissionDenied;
      expect(injector.text('x' * 50), InjectResult.permissionDenied);
    });

    test('status codes map to results', () {
      expect(macosInjectResult(MacosStatus.ok), InjectResult.injected);
      expect(
        macosInjectResult(MacosStatus.permissionDenied),
        InjectResult.permissionDenied,
      );
      expect(macosInjectResult(MacosStatus.failed), InjectResult.failed);
      expect(macosInjectResult(99), InjectResult.failed);
    });
  });

  group('occlusion (open question 5)', () {
    MacosWindowRecord rec({
      int pid = 7,
      int layer = 0,
      double alpha = 1,
      Rect bounds = const Rect.fromLTWH(200, 200, 100, 100),
    }) => MacosWindowRecord(
      ownerPid: pid,
      layer: layer,
      alpha: alpha,
      bounds: bounds,
    );

    test('another app\'s window over the point occludes it', () {
      final w = window(above: [rec()]);
      expect(macosIsOccluded(const Offset(250, 250), w), isTrue);
      expect(macosIsOccluded(const Offset(150, 150), w), isFalse);
    });

    test('the same app\'s menus and pop-ups count as the surface', () {
      final w = window(above: [rec(pid: 42, layer: 101)]);
      expect(macosIsOccluded(const Offset(250, 250), w), isFalse);
    });

    test('floating panels of other apps occlude', () {
      final w = window(above: [rec(layer: 3)]);
      expect(macosIsOccluded(const Offset(250, 250), w), isTrue);
    });

    test('the Dock, Notification Center, menu bar and cursor do not', () {
      final full = const Rect.fromLTWH(0, 0, 1728, 1117);
      final w = window(
        above: [
          rec(layer: 20, bounds: full),
          rec(layer: 21, bounds: full),
          rec(layer: 24, bounds: const Rect.fromLTWH(0, 0, 1728, 33)),
          rec(layer: 2147483630, bounds: const Rect.fromLTWH(240, 240, 28, 40)),
        ],
      );
      expect(macosIsOccluded(const Offset(250, 250), w), isFalse);
    });

    test('a fully transparent window does not', () {
      final w = window(above: [rec(alpha: 0)]);
      expect(macosIsOccluded(const Offset(250, 250), w), isFalse);
    });
  });

  group('surfaces', () {
    test('displays come from the native list', () async {
      final r = MacosSurfaceResolver(native);
      final list = await r.displays();
      expect(list.single.id, 1);
      final g = r.resolve(const SharedSurface.display(1))!;
      expect(g.bounds, const Rect.fromLTWH(0, 0, 1728, 1117));
      expect(g.pixelSize, const Size(3456, 2234));
      expect(r.resolve(const SharedSurface.display(9)), isNull);
    });

    test('displays are cached until the configuration changes', () {
      fakeAsync((async) {
        final r = MacosSurfaceResolver(native);
        r.resolve(const SharedSurface.display(1));
        r.resolve(const SharedSurface.display(1));
        expect(native.displayReads, 1);
        native.generation++;
        r.resolve(const SharedSurface.display(1));
        expect(native.displayReads, 2);
        async.elapse(const Duration(seconds: 1));
        r.resolve(const SharedSurface.display(1));
        expect(native.displayReads, 3);
      });
    });

    test('a window\'s geometry, hidden when off screen, gone when closed', () {
      fakeAsync((async) {
        native.windows[5] = window();
        final r = MacosSurfaceResolver(native);
        final g = r.resolve(const SharedSurface.window(5))!;
        expect(g.bounds, const Rect.fromLTWH(100, 100, 800, 600));
        expect(g.pixelSize, const Size(1600, 1200));
        expect(g.isHidden, isFalse);
        native.windows[5] = window(onScreen: false);
        async.elapse(const Duration(milliseconds: 50));
        expect(r.resolve(const SharedSurface.window(5))!.isHidden, isTrue);
        native.windows.remove(5);
        async.elapse(const Duration(milliseconds: 50));
        expect(r.resolve(const SharedSurface.window(5)), isNull);
      });
    });

    test('window reads are cached for 50 ms (open question 4)', () {
      fakeAsync((async) {
        native.windows[5] = window();
        final r = MacosSurfaceResolver(native);
        for (var i = 0; i < 10; i++) {
          r.resolve(const SharedSurface.window(5));
          r.isOnSurface(const SharedSurface.window(5), const Offset(150, 150));
          async.elapse(const Duration(milliseconds: 4));
        }
        expect(native.windowReads, 1);
        async.elapse(const Duration(milliseconds: 20));
        r.resolve(const SharedSurface.window(5));
        expect(native.windowReads, 2);
      });
    });

    test('handles outside the CGWindowID range are gone', () {
      final r = MacosSurfaceResolver(native);
      expect(r.resolve(const SharedSurface.window(-1)), isNull);
      expect(r.resolve(const SharedSurface.window(0x100000000)), isNull);
      expect(native.windowReads, 0);
    });

    test('on-surface checks occlusion and visibility', () {
      native.windows[5] = window(
        above: [
          const MacosWindowRecord(
            ownerPid: 7,
            layer: 0,
            alpha: 1,
            bounds: Rect.fromLTWH(500, 500, 100, 100),
          ),
        ],
      );
      final r = MacosSurfaceResolver(native);
      const s = SharedSurface.window(5);
      expect(r.isOnSurface(s, const Offset(150, 150)), isTrue);
      expect(r.isOnSurface(s, const Offset(550, 550)), isFalse);
      expect(
        r.isOnSurface(const SharedSurface.display(1), const Offset(550, 550)),
        isTrue,
      );
    });

    test('keyboard focus: the window\'s app is frontmost', () {
      native.windows[5] = window(pid: 42);
      final r = MacosSurfaceResolver(native);
      native.frontmost = 42;
      expect(r.hasKeyboardFocus(const SharedSurface.window(5)), isTrue);
      native.frontmost = 43;
      expect(r.hasKeyboardFocus(const SharedSurface.window(5)), isFalse);
      expect(r.hasKeyboardFocus(const SharedSurface.display(1)), isTrue);
    });
  });

  group('secure contexts', () {
    test('Secure Event Input blocks keys, not the pointer', () {
      final p = MacosSecureContext(native);
      native.secure = true;
      expect(p.check(InputKind.keyboard), BlockReason.secureInput);
      expect(p.check(InputKind.pointer), isNull);
    });

    test('an inactive session blocks everything', () {
      fakeAsync((async) {
        final p = MacosSecureContext(native);
        native.session = MacosSessionState.locked;
        expect(p.check(InputKind.pointer), BlockReason.sessionInactive);
        expect(p.check(InputKind.keyboard), BlockReason.sessionInactive);
        native.session = MacosSessionState.active;
        async.elapse(const Duration(milliseconds: 100));
        expect(p.check(InputKind.pointer), isNull);
      });
    });

    test('the session dictionary is read at most every 100 ms', () {
      fakeAsync((async) {
        final p = MacosSecureContext(native);
        for (var i = 0; i < 20; i++) {
          p.check(InputKind.pointer);
          async.elapse(const Duration(milliseconds: 4));
        }
        expect(native.sessionReads, 1);
      });
    });
  });

  group('local activity', () {
    test('polls only while listened to, and reports local input', () {
      fakeAsync((async) {
        final monitor = MacosLocalActivity(native);
        async.elapse(const Duration(milliseconds: 100));
        expect(native.snapshots, 0);
        var events = 0;
        final sub = monitor.activity.listen((_) => events++);
        async.elapse(const Duration(milliseconds: 100));
        expect(native.snapshots, greaterThanOrEqualTo(10));
        expect(events, 0);
        native.hid = const MacosActivityCounts(keyDowns: 1);
        async.elapse(const Duration(milliseconds: 10));
        expect(events, 1);
        sub.cancel();
        final polled = native.snapshots;
        async.elapse(const Duration(milliseconds: 100));
        expect(native.snapshots, polled);
      });
    });

    test('injected moves are not local input', () {
      fakeAsync((async) {
        final platform = MacosHostPlatform(native);
        var events = 0;
        platform.localActivity.activity.listen((_) => events++);
        async.elapse(const Duration(milliseconds: 20));
        platform.injector.movePointer(
          const Offset(700, 400),
          heldButtons: const {},
        );
        // Even if the HID system reported a move, the pointer is where the
        // package put it.
        native.hid = const MacosActivityCounts(moves: 1);
        async.elapse(const Duration(milliseconds: 20));
        expect(events, 0);
      });
    });
  });

  group('a session over the macOS platform', () {
    tearDown(RemoteInputHost.stopAll);

    test('a viewer\'s input reaches the native calls', () {
      fakeAsync((async) {
        native.windows[5] = window(pid: 42);
        native.frontmost = 42;
        final pair = MemoryInputLink.pair();
        final session = RemoteInputHost(platform: MacosHostPlatform(native))
            .enable(link: pair.host, surface: const SharedSurface.window(5));
        final viewer = RemoteInputViewer(link: pair.viewer);
        async.elapse(const Duration(milliseconds: 20));
        expect(session.state, const SessionActive());

        viewer.click(const Offset(0.5, 0.5), clickCount: 1);
        viewer.key(HidModifier.shiftLeft, KeyAction.down);
        viewer.key(usageA, KeyAction.down, modifiers: KeyModifiers.shift);
        viewer.key(usageA, KeyAction.up, modifiers: KeyModifiers.shift);
        viewer.key(HidModifier.shiftLeft, KeyAction.up);
        viewer.text('hi');
        async.elapse(const Duration(milliseconds: 200));

        final m = native.mouse;
        expect(m.map((c) => c.type), [
          MacEventType.leftMouseDown,
          MacEventType.leftMouseUp,
        ]);
        // The centre of the window, in points.
        expect(m.first.point.dx, closeTo(500, 0.01));
        expect(m.first.point.dy, closeTo(400, 0.01));
        expect(native.keys.map((k) => (k.keyCode, k.down, k.flags)), [
          (keyCodeShift, true, 0x20002),
          (keyCodeA, true, 0x20002),
          (keyCodeA, false, 0x20002),
          (keyCodeShift, false, 0),
        ]);
        expect(native.calls.whereType<TextCall>().single.text, 'hi');

        session.stop();
        async.flushMicrotasks();
      });
    });

    test('local input pauses the session', () {
      fakeAsync((async) {
        final pair = MemoryInputLink.pair();
        final session = RemoteInputHost(platform: MacosHostPlatform(native))
            .enable(link: pair.host, surface: const SharedSurface.display(1));
        RemoteInputViewer(link: pair.viewer);
        async.elapse(const Duration(milliseconds: 20));
        expect(session.state, const SessionActive());
        native.hid = const MacosActivityCounts(buttonDowns: 1);
        async.elapse(const Duration(milliseconds: 10));
        expect(session.state, const SessionPaused(PauseReason.localInput));
        session.stop();
        async.flushMicrotasks();
      });
    });

    test('a revoked permission stops the session', () {
      fakeAsync((async) {
        final pair = MemoryInputLink.pair();
        final session = RemoteInputHost(platform: MacosHostPlatform(native))
            .enable(link: pair.host, surface: const SharedSurface.display(1));
        final viewer = RemoteInputViewer(link: pair.viewer);
        async.elapse(const Duration(milliseconds: 20));
        native.postStatus = MacosStatus.permissionDenied;
        viewer.click(const Offset(0.5, 0.5));
        async.elapse(const Duration(milliseconds: 20));
        expect(
          session.state,
          const SessionStopped(StopReason.permissionDenied),
        );
      });
    });

    test('enable refuses without the permission', () {
      native.access = false;
      final pair = MemoryInputLink.pair();
      expect(
        () => RemoteInputHost(platform: MacosHostPlatform(native))
            .enable(link: pair.host, surface: const SharedSurface.display(1)),
        throwsA(
          isA<HostUnavailableException>().having(
            (e) => e.reason,
            'reason',
            HostUnavailableReason.permissionDenied,
          ),
        ),
      );
    });
  });
}
