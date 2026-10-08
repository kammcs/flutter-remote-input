// Tests for the fixes from the safety review (H1, M1, M3, M5, L1–L5, L8).
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/src/protocol/messages.dart';
import 'package:remote_input/testing.dart';

import 'session_test.dart' show Rig, display, point, usageA, usageR;

void main() {
  tearDown(RemoteInputHost.stopAll);

  group("the host app's own windows (H1)", () {
    test('pointer input over them is dropped', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.platform.surfaces.ownWindowAt = (p) => p.dx < 100;
        rig.viewer
          ..button(100, 100, PointerButton.left, down: true) // x ≈ 3 px
          ..wheel(100, 100, dy: 10)
          ..button(60000, 100, PointerButton.left, down: true);
        rig.flush();
        expect(rig.events, hasLength(1));
        expect(rig.dropped(DropReason.hostWindow), 2);
      });
    });

    test('keys are blocked while the host app is in front', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.platform.surfaces.ownAppInFront = true;
        rig.viewer
          ..key(usageA, KeyAction.down)
          ..text('approve');
        rig.flush();
        expect(rig.events, isEmpty);
        expect(
          rig.session.state,
          const SessionBlocked(BlockReason.hostAppInFront),
        );
        rig.platform.surfaces.ownAppInFront = false;
        rig.elapse(const Duration(milliseconds: 300));
        expect(rig.session.state, const SessionActive());
      });
    });

    test(
      'protectHostWindows: false lets tests inject into their own window',
      () {
        fakeAsync((async) {
          final rig = Rig(
            async,
            options: const HostOptions(protectHostWindows: false),
          );
          rig.platform.surfaces
            ..ownWindowAt = ((_) => true)
            ..ownAppInFront = true;
          rig.viewer
            ..button(100, 100, PointerButton.left, down: true)
            ..key(usageA, KeyAction.down);
          rig.flush();
          expect(rig.events, hasLength(2));
        });
      },
    );
  });

  group('KeyFilter (M1)', () {
    HostOptions noWinR() => HostOptions(
      keyFilter: (p) =>
          !(p.usage == usageR &&
              p.heldModifiers.contains(HidModifier.metaLeft)),
    );

    test('a modifier pressed after the key releases it, and its repeats '
        'are dropped', () {
      fakeAsync((async) {
        final rig = Rig(async, options: noWinR());
        rig.viewer
          ..key(usageR, KeyAction.down)
          ..key(
            HidModifier.metaLeft,
            KeyAction.down,
            modifiers: KeyModifiers.meta,
          )
          ..key(usageR, KeyAction.repeat, modifiers: KeyModifiers.meta);
        rig.flush();
        expect(rig.events, [
          const InjectedKey(usageR, down: true),
          const InjectedKey(HidModifier.metaLeft, down: true),
          const InjectedKey(usageR, down: false),
        ]);
      });
    });

    test('text with a command modifier held drops Tab and line breaks', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.viewer
          ..key(
            HidModifier.altLeft,
            KeyAction.down,
            modifiers: KeyModifiers.alt,
          )
          ..text('\ta\nb')
          ..text('\t');
        rig.flush();
        expect(rig.events.whereType<InjectedText>().single.text, 'ab');
        expect(rig.dropped(DropReason.filtered), 1);
      });
    });
  });

  test('no injection while local input is unmonitored (M3)', () {
    fakeAsync((async) {
      final rig = Rig(async);
      rig.platform.localActivity.healthy = false;
      rig.viewer.button(0, 0, PointerButton.left, down: true);
      rig.flush();
      expect(rig.events, isEmpty);
      expect(
        rig.session.state,
        const SessionBlocked(BlockReason.localInputUnmonitored),
      );
      rig.platform.localActivity.healthy = true;
      rig.elapse(const Duration(milliseconds: 300));
      expect(rig.session.state, const SessionActive());
    });
  });

  test('a release the OS refused is retried (M5)', () {
    fakeAsync((async) {
      final rig = Rig(async);
      rig.viewer.key(usageA, KeyAction.down);
      rig.flush();
      rig.injector.onInject = (e) => e is InjectedKey && !e.down
          ? InjectResult.failed
          : InjectResult.injected;
      rig.platform.secureContext.keyboard = BlockReason.secureDesktop;
      rig.viewer.key(usageA, KeyAction.repeat);
      rig.flush();
      expect(
        rig.session.state,
        const SessionBlocked(BlockReason.secureDesktop),
      );
      final ups = rig.events.where(
        (e) => e == const InjectedKey(usageA, down: false),
      );
      expect(ups, hasLength(1)); // tried, refused
      rig.injector.onInject = null;
      rig.platform.secureContext.keyboard = null;
      rig.elapse(const Duration(milliseconds: 300));
      expect(
        rig.events.where((e) => e == const InjectedKey(usageA, down: false)),
        hasLength(2),
      );
      rig.elapse(const Duration(seconds: 2));
      expect(
        rig.events.where((e) => e == const InjectedKey(usageA, down: false)),
        hasLength(2),
      );
    });
  });

  test(
    'a button release over another window lands where the pointer is (L2)',
    () {
      fakeAsync((async) {
        final platform = FakeHostPlatform();
        platform.surfaces.windows[7] = const SurfaceGeometry(
          bounds: display,
          pixelSize: Size(1920, 1080),
        );
        final rig = Rig(
          async,
          platform: platform,
          surface: const SharedSurface.window(7),
        );
        rig.viewer.button(1000, 1000, PointerButton.left, down: true);
        rig.flush();
        platform.surfaces.occluded = (p) => p.dx > 960;
        rig.viewer.button(60000, 1000, PointerButton.left, down: false);
        rig.flush();
        expect(
          rig.events.last,
          InjectedButton(
            point(display, 1000, 1000),
            PointerButton.left,
            down: false,
          ),
        );
      });
    },
  );

  test('points never leave the surface, whatever the insets (L3)', () {
    fakeAsync((async) {
      final surface = RectSurface(
        const Rect.fromLTWH(0, 0, 100, 100),
        contentInsets: const EdgeInsets.only(left: -50),
      );
      final rig = Rig(async, surface: surface);
      rig.viewer.button(0, 0, PointerButton.left, down: true);
      rig.flush();
      expect((rig.events.single as InjectedButton).point.dx, 0);

      surface.update(const Rect.fromLTWH(0, 0, double.nan, 100));
      rig.viewer.wheel(0, 0, dy: 1);
      rig.flush();
      expect(rig.events, hasLength(1));
      expect(rig.dropped(DropReason.failed), 1);
    });
  });

  test(
    "garbage and other sessions' messages don't keep held keys alive (L4)",
    () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.viewer.key(usageA, KeyAction.down);
        rig.flush();
        for (var i = 0; i < 6; i++) {
          rig.viewer.sendBytes(Uint8List.fromList([0x20, 0, 0]));
          rig.elapse(const Duration(seconds: 1));
        }
        expect(rig.events.last, const InjectedKey(usageA, down: false));
      });
    },
  );

  test('pings are rate limited (L8)', () {
    fakeAsync((async) {
      final rig = Rig(async);
      for (var i = 0; i < 30; i++) {
        rig.viewer.send(Ping(id: i, viewerMicros: 0));
      }
      rig.flush();
      expect(rig.viewer.received.whereType<Pong>(), hasLength(20));
    });
  });

  test('a key on a closed window stops the session', () {
    fakeAsync((async) {
      final platform = FakeHostPlatform();
      platform.surfaces.windows[7] = const SurfaceGeometry(
        bounds: display,
        pixelSize: Size(1920, 1080),
      );
      final rig = Rig(
        async,
        platform: platform,
        surface: const SharedSurface.window(7),
      );
      platform.surfaces.windows.remove(7);
      rig.viewer.key(usageA, KeyAction.down);
      rig.flush();
      expect(rig.session.state, const SessionStopped(StopReason.surfaceGone));
    });
  });

  test('stop() completes even if the transport throws (L1)', () {
    fakeAsync((async) {
      final pair = MemoryInputLink.pair();
      final link = _ThrowingLink(pair.host);
      final session = RemoteInputHost(platform: FakeHostPlatform())
          .enable(link: link, surface: const SharedSurface.display(1));
      async.flushMicrotasks();
      link.fail = true;
      session.stop();
      expect(session.state, const SessionStopped(StopReason.byHost));
      expect(RemoteInputHost.activeSession, isNull);
    });
  });

  test('the viewer survives a transport that throws on send', () {
    fakeAsync((async) {
      final pair = MemoryInputLink.pair();
      RemoteInputHost(platform: FakeHostPlatform())
          .enable(link: pair.host, surface: const SharedSurface.display(1));
      final link = _ThrowingLink(pair.viewer);
      final viewer = RemoteInputViewer(link: link);
      async.flushMicrotasks();
      expect(viewer.state, const SessionActive());
      link.fail = true;
      viewer
        ..pointerMove(const Offset(0.5, 0.5))
        ..key(usageA, KeyAction.down)
        ..releaseAll();
      async.elapse(const Duration(milliseconds: 50));
      unawaited(viewer.close());
      async.flushMicrotasks();
      expect(viewer.state, const SessionStopped(StopReason.viewerClosed));
    });
  });
}

final class _ThrowingLink implements InputLink {
  _ThrowingLink(this._inner);
  final InputLink _inner;
  bool fail = false;

  @override
  InputChannel get reliable => _ThrowingChannel(_inner.reliable, this);

  @override
  InputChannel get unreliable => _ThrowingChannel(_inner.unreliable, this);
}

final class _ThrowingChannel implements InputChannel {
  _ThrowingChannel(this._inner, this._link);
  final InputChannel _inner;
  final _ThrowingLink _link;

  @override
  int? get bufferedAmount => _inner.bufferedAmount;
  @override
  bool get isOpen => _inner.isOpen;
  @override
  Stream<Uint8List> get messages => _inner.messages;
  @override
  Stream<bool> get openChanges => _inner.openChanges;
  @override
  void send(Uint8List message) {
    if (_link.fail) throw StateError('closing');
    _inner.send(message);
  }
}
