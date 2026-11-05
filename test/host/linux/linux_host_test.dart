import 'dart:async';
import 'dart:ui';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/src/host/linux/linux_activity.dart';
import 'package:remote_input/src/host/linux/linux_host.dart';
import 'package:remote_input/src/host/linux/linux_native.dart';
import 'package:remote_input/testing.dart';

import 'fake_linux_native.dart';

const usageA = 0x00070004;
const usageEnter = 0x00070028;
const evdevA = 30;
const evdevEnter = 28;
const evdevTab = 15;

void main() {
  late FakeLinuxNative native;
  setUp(() => native = FakeLinuxNative());

  group('platform', () {
    test('reports Linux, and follows the session backend', () {
      expect(LinuxHostPlatform(native).platform, PeerPlatform.linux);
      expect(LinuxHostPlatform(native).injector, isA<LinuxX11Injector>());
      native.backend = LinuxBackend.wayland;
      final w = LinuxHostPlatform(native);
      expect(w.injector, isA<LinuxWaylandInjector>());
      expect(w.surfaces, isA<LinuxWaylandSurfaceResolver>());
    });

    test('X11: unavailable without a session, XTest or XInput 2', () {
      final p = LinuxHostPlatform(native);
      expect(p.checkAvailable(), isNull);
      native.openStatus = 2;
      expect(p.checkAvailable(), HostUnavailableReason.unsupportedPlatform);
      native.backend = LinuxBackend.none;
      expect(
        LinuxHostPlatform(native).checkAvailable(),
        HostUnavailableReason.unsupportedPlatform,
      );
    });

    test('Wayland: the opt-in, then the portal session', () {
      native.backend = LinuxBackend.wayland;
      final p = LinuxHostPlatform(native);
      expect(p.checkAvailable(), HostUnavailableReason.waylandNotAllowed);
      expect(p.checkAvailable(allowWayland: true), isNull);
      native.connected = false;
      expect(
        p.checkAvailable(allowWayland: true),
        HostUnavailableReason.permissionDenied,
      );
      // The opt-in is asked about first.
      expect(p.checkAvailable(), HostUnavailableReason.waylandNotAllowed);
      native.hasWayland = false;
      expect(
        p.checkAvailable(allowWayland: true),
        HostUnavailableReason.unsupportedPlatform,
      );
    });

    test('root is refused unless allowed, after every other check', () {
      native.euid = 0;
      final p = LinuxHostPlatform(native);
      expect(p.checkAvailable(), HostUnavailableReason.elevatedHost);
      expect(p.checkAvailable(allowElevatedHost: true), isNull);
      native.openStatus = 1;
      expect(p.checkAvailable(), HostUnavailableReason.unsupportedPlatform);
    });
  });

  group('X11 injector', () {
    late LinuxX11Injector injector;
    setUp(() => injector = LinuxX11Injector(native));

    test('moves to the pixel containing the point', () {
      expect(
        injector.movePointer(const Offset(10.99, 20.01), heldButtons: {}),
        InjectResult.injected,
      );
      expect(native.log, ['move 10 20']);
    });

    test('a button moves there first, with X button numbers', () {
      for (final (b, n) in [
        (PointerButton.left, 1),
        (PointerButton.middle, 2),
        (PointerButton.right, 3),
        (PointerButton.back, 8),
        (PointerButton.forward, 9),
      ]) {
        native.calls.clear();
        injector.pointerButton(
          const Offset(5, 6),
          b,
          down: true,
          clickCount: 1,
        );
        expect(native.log, ['move 5 6', 'button $n true']);
      }
    });

    test('a release is posted even if the move fails', () {
      native.status = LinuxStatus.failed;
      injector.pointerButton(
        Offset.zero,
        PointerButton.left,
        down: false,
        clickCount: 1,
      );
      expect(native.args('button'), ['1 false']);
      native.calls.clear();
      injector.pointerButton(
        Offset.zero,
        PointerButton.left,
        down: true,
        clickCount: 1,
      );
      expect(native.named('button'), isEmpty);
    });

    test('the wheel clicks buttons 4 to 7, three lines a notch', () {
      injector.wheel(Offset.zero, dx: 0, dy: 3, unit: WheelUnit.line);
      expect(native.named('button').map((c) => c.$2), [
        [5, true],
        [5, false],
      ]);
      native.calls.clear();
      injector.wheel(Offset.zero, dx: -6, dy: 0, unit: WheelUnit.line);
      expect(native.named('button').length, 4);
      expect(native.named('button').first.$2, [6, true]);
      native.calls.clear();
      // A line is a third of a notch: the fractions add up.
      injector.wheel(Offset.zero, dx: 0, dy: -1, unit: WheelUnit.line);
      injector.wheel(Offset.zero, dx: 0, dy: -1, unit: WheelUnit.line);
      expect(native.named('button'), isEmpty);
      injector.wheel(Offset.zero, dx: 0, dy: -1, unit: WheelUnit.line);
      expect(native.named('button').first.$2, [4, true]);
      native.calls.clear();
      // 100 pixels a notch.
      injector.wheel(Offset.zero, dx: 0, dy: 250, unit: WheelUnit.pixel);
      expect(native.named('button').length, 4);
    });

    test('keys by evdev code; repeats dropped; unmapped refused', () {
      expect(injector.key(usageA, down: true), InjectResult.injected);
      expect(
        injector.key(usageA, down: true, repeat: true),
        InjectResult.injected,
      );
      expect(injector.key(usageA, down: false), InjectResult.injected);
      expect(native.log, ['key $evdevA true', 'key $evdevA false']);
      expect(injector.key(0x00070000, down: true), InjectResult.unmappedKey);
    });

    test('text: code points, Enter for line breaks, Tab for tabs', () {
      fakeAsync((async) {
        expect(injector.text('a\r\nb\tc\rd\n'), InjectResult.injected);
        expect(native.calls.map((c) => c.$1).toList(), [
          'text',
          'key',
          'key',
          'text',
          'key',
          'key',
          'text',
          'key',
          'key',
          'text',
          'key',
          'key',
        ]);
        expect(native.named('key').map((c) => c.$2.first).toSet(), {
          evdevEnter,
          evdevTab,
        });
        expect(native.named('text').map((c) => c.$2.single), [
          0x61,
          0x62,
          0x63,
          0x64,
        ]);
        // Emoji are one code point, not two UTF-16 units.
        native.calls.clear();
        injector.text('\u{1F600}');
        expect(native.named('text').single.$2, [0x1F600]);
      });
    });

    test('the spare keycodes are unbound 1.5 s after the last text', () {
      fakeAsync((async) {
        injector.text('a');
        async.elapse(const Duration(milliseconds: 900));
        injector.text('b');
        async.elapse(const Duration(milliseconds: 1400));
        expect(native.named('restore'), isEmpty);
        async.elapse(const Duration(milliseconds: 200));
        expect(native.named('restore').length, 1);
      });
    });

    test('a character with no free keycode is skipped and reported', () {
      fakeAsync((async) {
        native.textStatus = LinuxStatus.unmapped;
        expect(injector.text('xy'), InjectResult.unmappedKey);
        expect(native.named('text').length, 2);
        native.textStatus = LinuxStatus.failed;
        native.calls.clear();
        expect(injector.text('xy'), InjectResult.failed);
        expect(native.named('text').length, 1);
        async.elapse(const Duration(seconds: 2));
      });
    });
  });

  group('Wayland injector', () {
    late LinuxHostPlatform platform;
    setUp(() {
      native.backend = LinuxBackend.wayland;
      platform = LinuxHostPlatform(native);
    });

    test('posts into the region the surface resolved to', () {
      native.regions = [
        const LinuxDisplayRecord(
          id: 3,
          bounds: Rect.fromLTWH(0, 0, 800, 600),
          mappingId: 'stream-a',
        ),
      ];
      platform.surfaces.resolve(const SharedSurface.display(3));
      platform.injector.movePointer(const Offset(1.5, 2.5), heldButtons: {});
      expect(native.log, ['wlMove 3 1.5 2.5']);
      // A rect surface is in the desktop's coordinates.
      platform.surfaces.resolve(
        SharedSurface.rect(const Rect.fromLTWH(0, 0, 10, 10)),
      );
      platform.injector.movePointer(const Offset(1, 1), heldButtons: {});
      expect(native.log.last, 'wlMove 0 1.0 1.0');
    });

    test('buttons by evdev code, after a move', () {
      platform.injector.pointerButton(
        const Offset(4, 4),
        PointerButton.back,
        down: true,
        clickCount: 1,
      );
      expect(native.calls.map((c) => c.$1), ['wlMove', 'wlButton']);
      expect(native.calls.last.$2, [0x113, true]);
    });

    test('pixels scroll smoothly, lines in 120ths of a notch', () {
      platform.injector.wheel(
        Offset.zero,
        dx: 5,
        dy: -7,
        unit: WheelUnit.pixel,
      );
      expect(native.named('wlScroll').single.$2, [5.0, -7.0, false]);
      native.calls.clear();
      platform.injector.wheel(Offset.zero, dx: 0, dy: 3, unit: WheelUnit.line);
      expect(native.named('wlScroll').single.$2, [0.0, 120.0, true]);
    });

    test('repeats are dropped: clients repeat held keys', () {
      platform.injector.key(usageA, down: true);
      platform.injector.key(usageA, down: true, repeat: true);
      expect(native.named('wlKey').length, 1);
    });

    test("text the layout can't type is skipped and reported", () {
      native.textStatus = LinuxStatus.unmapped;
      expect(platform.injector.text('x\ny'), InjectResult.unmappedKey);
      // Both characters were tried, and the line break typed.
      expect(native.named('wlText').length, 2);
      expect(native.named('wlKey').map((c) => c.$2), [
        [evdevEnter, true],
        [evdevEnter, false],
      ]);
    });

    test('a closed portal session is a permission denied', () {
      native.status = LinuxStatus.permissionDenied;
      expect(
        platform.injector.key(usageA, down: true),
        InjectResult.permissionDenied,
      );
    });
  });

  group('X11 surfaces', () {
    late LinuxX11SurfaceResolver surfaces;
    setUp(() => surfaces = LinuxX11SurfaceResolver(native));

    test('displays are the RandR monitors, cached for a second', () {
      fakeAsync((async) {
        final surfaces = LinuxX11SurfaceResolver(native);
        late List<DisplayInfo> d;
        surfaces.displays().then((v) => d = v);
        async.flushMicrotasks();
        expect(d.single.id, 77);
        expect(d.single.isPrimary, isTrue);
        expect(
          surfaces.resolve(const SharedSurface.display(77))!.bounds,
          const Rect.fromLTWH(0, 0, 1920, 1080),
        );
        expect(surfaces.resolve(const SharedSurface.display(1)), isNull);
        expect(native.monitorReads, 1);
        async.elapse(const Duration(seconds: 2));
        surfaces.resolve(const SharedSurface.display(77));
        expect(native.monitorReads, 2);
      });
    });

    test('a window is read every time; gone is null, unmapped hidden', () {
      expect(surfaces.resolve(const SharedSurface.window(9)), isNull);
      native.windows[9] = const LinuxWindow(
        bounds: Rect.fromLTWH(10, 20, 300, 200),
        shown: false,
      );
      final g = surfaces.resolve(const SharedSurface.window(9))!;
      expect(g.bounds, const Rect.fromLTWH(10, 20, 300, 200));
      expect(g.isHidden, isTrue);
    });

    test('occlusion and focus: unknown counts as no', () {
      const w = SharedSurface.window(9);
      expect(surfaces.isOnSurface(w, const Offset(1.7, 2.2)), isTrue);
      expect(native.named('onWindow').single.$2, [9, 1, 2]);
      native.onWindow = null;
      expect(surfaces.isOnSurface(w, Offset.zero), isFalse);
      native.hasFocus = null;
      expect(surfaces.hasKeyboardFocus(w), isFalse);
      // Displays aren't checked.
      expect(
        surfaces.isOnSurface(const SharedSurface.display(1), Offset.zero),
        isTrue,
      );
    });

    test("the host's own windows: unknown counts as yes", () {
      expect(surfaces.isOwnWindowAt(Offset.zero), isFalse);
      native.ownWindowAt = null;
      expect(surfaces.isOwnWindowAt(Offset.zero), isTrue);
      native.ownAppInFront = null;
      expect(surfaces.isOwnAppInFront(), isTrue);
    });
  });

  group('Wayland surfaces', () {
    late LinuxHostPlatform platform;
    final sizes = <int, Size>{};
    setUp(() {
      sizes.clear();
      native.backend = LinuxBackend.wayland;
      platform = LinuxHostPlatform(native, contentSizeOf: (id) => sizes[id]);
    });

    test(
      'displays are the regions; a window stream uses its content size',
      () async {
        native.regions = [
          const LinuxDisplayRecord(
            id: 1,
            bounds: Rect.fromLTWH(0, 0, 1600, 900),
          ),
          const LinuxDisplayRecord(
            id: 2,
            bounds: Rect.fromLTWH(0, 0, 1600, 900),
            mappingId: 'window-stream',
            scale: 2,
          ),
        ];
        native.generation++;
        final d = await platform.surfaces.displays();
        expect(d.map((x) => x.id), [1, 2]);
        expect(
          platform.surfaces.resolve(const SharedSurface.display(2))!.bounds,
          const Rect.fromLTWH(0, 0, 1600, 900),
        );
        sizes[2] = const Size(640, 480);
        final g = platform.surfaces.resolve(const SharedSurface.display(2))!;
        expect(g.bounds, const Rect.fromLTWH(0, 0, 640, 480));
        expect(g.pixelSize, const Size(1280, 960));
        // The desktop's own regions ignore content sizes.
        sizes[1] = const Size(10, 10);
        expect(
          platform.surfaces
              .resolve(const SharedSurface.display(1))!
              .bounds
              .width,
          1600,
        );
      },
    );

    test('window surfaces are unsupported; no occlusion or focus checks', () {
      expect(platform.surfaces.resolve(const SharedSurface.window(1)), isNull);
      expect(
        platform.surfaces.isOnSurface(
          const SharedSurface.display(1),
          Offset.zero,
        ),
        isTrue,
      );
      expect(
        platform.surfaces.hasKeyboardFocus(const SharedSurface.display(1)),
        isTrue,
      );
    });

    test("own windows: only where the pointer already is", () {
      platform.surfaces.resolve(const SharedSurface.display(1));
      platform.injector.movePointer(const Offset(100, 100), heldButtons: {});
      expect(platform.surfaces.isOwnWindowAt(const Offset(100, 100)), isFalse);
      native.wlPointerOver = true;
      expect(platform.surfaces.isOwnWindowAt(const Offset(100.5, 100)), isTrue);
      // A move elsewhere goes through, so the pointer can leave.
      expect(platform.surfaces.isOwnWindowAt(const Offset(300, 100)), isFalse);
      native.wlPointerOver = null;
      expect(platform.surfaces.isOwnWindowAt(const Offset(300, 100)), isTrue);
      native.wlOwnFront = null;
      expect(platform.surfaces.isOwnAppInFront(), isTrue);
    });
  });

  group('secure context', () {
    test('a locked or inactive session blocks everything', () {
      final p = LinuxSecureContext(native, LinuxBackend.x11);
      expect(p.check(InputKind.pointer), isNull);
      native.session = LinuxSessionState.locked;
      expect(p.check(InputKind.keyboard), BlockReason.sessionInactive);
      native.session = LinuxSessionState.inactive;
      expect(p.check(InputKind.pointer), BlockReason.sessionInactive);
      native.session = LinuxSessionState.unknown;
      expect(p.check(InputKind.pointer), isNull);
    });

    test('Wayland: paused devices block', () {
      final p = LinuxSecureContext(native, LinuxBackend.wayland);
      native.paused = true;
      expect(p.check(InputKind.pointer), BlockReason.sessionInactive);
      expect(
        LinuxSecureContext(native, LinuxBackend.x11).check(InputKind.pointer),
        isNull,
      );
    });
  });

  group('local activity', () {
    test('emits when the count grows; checkNow consumes it', () {
      fakeAsync((async) {
        final m = LinuxLocalActivity(native);
        var n = 0;
        final sub = m.activity.listen((_) => n++);
        async.elapse(const Duration(milliseconds: 20));
        expect(m.isMonitoring, isTrue);
        expect(native.starts, 1);
        native.count = 1;
        async.elapse(const Duration(milliseconds: 10));
        expect(n, 1);
        native.count = 2;
        expect(m.checkNow(), isTrue);
        expect(m.checkNow(), isFalse);
        async.elapse(const Duration(milliseconds: 20));
        expect(n, 1);
        sub.cancel();
        expect(native.stops, 1);
        expect(m.isMonitoring, isFalse);
      });
    });

    test('fails closed: unhealthy, stale or without udev', () {
      fakeAsync((async) {
        final m = LinuxLocalActivity(native);
        var n = 0;
        final sub = m.activity.listen((_) => n++);
        async.elapse(const Duration(milliseconds: 20));
        native.healthy = false;
        async.elapse(const Duration(milliseconds: 10));
        expect(m.isMonitoring, isFalse);
        expect(m.checkNow(), isFalse);
        // Retries the thread while it's down.
        async.elapse(const Duration(seconds: 1));
        expect(native.starts, greaterThan(1));
        // Back: input in the gap went unseen, so it counts once.
        native.healthy = true;
        async.elapse(const Duration(milliseconds: 10));
        expect(m.isMonitoring, isTrue);
        expect(n, 1);
        expect(m.localInputCounts.counted[LocalInputSource.monitorGap], 1);
        native.heartbeatAge = 500;
        async.elapse(const Duration(milliseconds: 10));
        expect(m.isMonitoring, isFalse);
        native.heartbeatAge = 10;
        native.devicesLost = -1;
        async.elapse(const Duration(milliseconds: 10));
        expect(m.isMonitoring, isFalse);
        sub.cancel();
      });
    });

    test('a lost device is reported, by the poll or by checkNow', () {
      fakeAsync((async) {
        final m = LinuxLocalActivity(native);
        var lost = 0;
        final subs = [
          m.activity.listen((_) {}),
          m.devicesLost.listen((_) => lost++),
        ];
        async.elapse(const Duration(milliseconds: 20));
        native.devicesLost = 1;
        async.elapse(const Duration(milliseconds: 10));
        expect(lost, 1);
        native.devicesLost = 2;
        expect(m.checkNow(), isTrue);
        async.flushMicrotasks();
        expect(lost, 2);
        for (final s in subs) {
          s.cancel();
        }
      });
    });

    test('diagnostics are counts only', () {
      native.reasons[LinuxActivityReason.key] = 2;
      native.reasons[LinuxActivityReason.idle] = 3;
      native.reasons[LinuxActivityReason.stall] = 1;
      final c = LinuxLocalActivity(native).localInputCounts;
      expect(c.counted, {
        LocalInputSource.key: 2,
        LocalInputSource.idleTime: 3,
      });
      expect(c.stalls, 1);
    });
  });

  group('a session over the Linux platform', () {
    tearDown(RemoteInputHost.stopAll);

    test("an X11 viewer's input reaches XTest", () {
      fakeAsync((async) {
        final pair = MemoryInputLink.pair();
        final session = RemoteInputHost(platform: LinuxHostPlatform(native))
            .enable(link: pair.host, surface: const SharedSurface.display(77));
        final viewer = RemoteInputViewer(link: pair.viewer);
        async.elapse(const Duration(milliseconds: 20));
        expect(session.state, const SessionActive());

        viewer.click(const Offset(0.5, 0.5));
        viewer.key(usageEnter, KeyAction.down);
        viewer.key(usageEnter, KeyAction.up);
        viewer.text('hi');
        async.elapse(const Duration(milliseconds: 200));

        expect(native.named('move').first.$2, [960, 540]);
        expect(native.named('button').map((c) => c.$2), [
          [1, true],
          [1, false],
        ]);
        expect(native.named('key').map((c) => c.$2), [
          [evdevEnter, true],
          [evdevEnter, false],
        ]);
        expect(native.named('text').map((c) => c.$2.single), [0x68, 0x69]);
        session.stop();
        async.flushMicrotasks();
      });
    });

    test('local input pauses the session', () {
      fakeAsync((async) {
        final pair = MemoryInputLink.pair();
        final session = RemoteInputHost(platform: LinuxHostPlatform(native))
            .enable(link: pair.host, surface: const SharedSurface.display(77));
        RemoteInputViewer(link: pair.viewer);
        async.elapse(const Duration(milliseconds: 20));
        expect(session.state, const SessionActive());
        native.count++;
        async.elapse(const Duration(milliseconds: 20));
        expect(session.state, const SessionPaused(PauseReason.localInput));
        session.stop();
        async.flushMicrotasks();
      });
    });

    test('a closed portal session stops the control session at once', () {
      fakeAsync((async) {
        native.backend = LinuxBackend.wayland;
        final revoked = StreamController<void>.broadcast();
        final pair = MemoryInputLink.pair();
        final session =
            RemoteInputHost(
              platform: LinuxHostPlatform(native, revoked: revoked.stream),
            ).enable(
              link: pair.host,
              surface: const SharedSurface.display(1),
              options: const HostOptions(allowWayland: true),
            );
        RemoteInputViewer(link: pair.viewer);
        async.elapse(const Duration(milliseconds: 20));
        expect(session.state, const SessionActive());
        revoked.add(null);
        async.flushMicrotasks();
        expect(
          session.state,
          const SessionStopped(StopReason.permissionDenied),
        );
      });
    });

    test('Wayland needs the opt-in to enable', () {
      native.backend = LinuxBackend.wayland;
      final host = RemoteInputHost(platform: LinuxHostPlatform(native));
      expect(
        () => host.enable(
          link: MemoryInputLink.pair().host,
          surface: const SharedSurface.display(1),
        ),
        throwsA(
          isA<HostUnavailableException>().having(
            (e) => e.reason,
            'reason',
            HostUnavailableReason.waylandNotAllowed,
          ),
        ),
      );
    });
  });

  test('a fake platform can be revoked too', () {
    fakeAsync((async) {
      final platform = FakeHostPlatform();
      final pair = MemoryInputLink.pair();
      final session = RemoteInputHost(platform: platform)
          .enable(link: pair.host, surface: const SharedSurface.display(1));
      RemoteInputViewer(link: pair.viewer);
      async.elapse(const Duration(milliseconds: 20));
      platform.revoke();
      async.flushMicrotasks();
      expect(session.state, const SessionStopped(StopReason.permissionDenied));
    });
  });
}
