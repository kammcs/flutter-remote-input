import 'dart:typed_data';
import 'dart:ui';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/src/protocol/messages.dart';
import 'package:remote_input/testing.dart';

import '../support/raw_viewer.dart';

const usageA = 0x00070004;
const usageB = 0x00070005;
const usageR = 0x00070015;

final class Rig {
  Rig(
    this.async, {
    HostOptions options = const HostOptions(),
    SharedSurface? surface,
    FakeHostPlatform? platform,
    bool handshake = true,
    PeerPlatform viewerPlatform = PeerPlatform.windows,
  }) : platform = platform ?? FakeHostPlatform() {
    final pair = MemoryInputLink.pair();
    hostLink = pair.host;
    viewer = RawViewer(pair.viewer);
    session = RemoteInputHost(platform: this.platform).enable(
      link: hostLink,
      surface: surface ?? const SharedSurface.display(1),
      options: options,
    );
    session.stateChanges.listen(states.add);
    flush();
    if (handshake) {
      viewer.hello(platform: viewerPlatform);
      flush();
    }
  }

  final FakeAsync async;
  final FakeHostPlatform platform;
  late final MemoryInputLink hostLink;
  late final RawViewer viewer;
  late final ControlSession session;
  final List<SessionState> states = [];

  RecordingInjector get injector => platform.injector;
  List<InjectedEvent> get events => injector.events;

  void flush() => async.flushMicrotasks();

  void elapse(Duration d) => async.elapse(d);

  int dropped(DropReason r) => session.stats.dropped[r] ?? 0;

  int violations(ViolationKind k) => session.stats.violations[k] ?? 0;
}

/// The desktop point for normalized wire values on [bounds].
Offset point(Rect bounds, int x, int y) => Offset(
  bounds.left + (x + 0.5) * bounds.width / 65536,
  bounds.top + (y + 0.5) * bounds.height / 65536,
);

const display = Rect.fromLTWH(0, 0, 1920, 1080);

void main() {
  tearDown(RemoteInputHost.stopAll);

  group('off by default and the handshake', () {
    test('sends HostHello once the link opens, and waits', () {
      fakeAsync((async) {
        final pair = MemoryInputLink.pair(open: false);
        final viewer = RawViewer(pair.viewer);
        final session = RemoteInputHost(platform: FakeHostPlatform())
            .enable(link: pair.host, surface: const SharedSurface.display(1));
        async.flushMicrotasks();
        expect(viewer.hostHello, isNull);
        pair.host.open();
        async.flushMicrotasks();
        final hello = viewer.hostHello!;
        expect(hello.minVersion, 1);
        expect(hello.maxVersion, 1);
        expect(hello.hostPlatform, PeerPlatform.windows);
        expect((hello.surfaceWidth, hello.surfaceHeight), (1920, 1080));
        expect(session.state, const SessionWaiting());
      });
    });

    test('re-sends HostHello until the viewer answers', () {
      fakeAsync((async) {
        final rig = Rig(async, handshake: false);
        rig.elapse(const Duration(milliseconds: 3100));
        expect(rig.viewer.received.whereType<HostHello>(), hasLength(4));
        rig.viewer.hello();
        rig.flush();
        rig.elapse(const Duration(seconds: 3));
        expect(rig.viewer.received.whereType<HostHello>(), hasLength(4));
        expect(rig.session.state, const SessionActive());
      });
    });

    test('injects nothing before the viewer completes the handshake', () {
      fakeAsync((async) {
        final rig = Rig(async, handshake: false);
        rig.viewer
          ..key(usageA, KeyAction.down)
          ..button(100, 100, PointerButton.left, down: true)
          ..move(10, 10);
        rig.flush();
        rig.elapse(const Duration(milliseconds: 50));
        expect(rig.events, isEmpty);
        expect(rig.dropped(DropReason.notReady), 3);
        expect(rig.session.state, const SessionWaiting());
      });
    });

    test('becomes active on a valid Hello and tells the viewer', () {
      fakeAsync((async) {
        final rig = Rig(async);
        expect(rig.session.state, const SessionActive());
        expect(rig.session.viewerPlatform, PeerPlatform.windows);
        expect(rig.viewer.states.single.state, HostStateCode.active);
      });
    });

    test('a Hello with the wrong nonce is a violation', () {
      fakeAsync((async) {
        final rig = Rig(async, handshake: false);
        rig.viewer.send(
          Hello(
            version: 1,
            nonce: Uint8List(16),
            viewerPlatform: PeerPlatform.windows,
            capabilities: 0,
          ),
        );
        rig.flush();
        expect(rig.session.state, const SessionWaiting());
        expect(rig.violations(ViolationKind.wrongSession), 1);
      });
    });

    test('an unsupported version gets Bye and keeps waiting', () {
      fakeAsync((async) {
        final rig = Rig(async, handshake: false);
        rig.viewer.hello(version: 2);
        rig.flush();
        expect(rig.session.state, const SessionWaiting());
        expect(
          rig.viewer.received.whereType<Bye>().single.reason,
          ByeReason.unsupportedVersion,
        );
        rig.viewer.hello();
        rig.flush();
        expect(rig.session.state, const SessionActive());
      });
    });

    test('one session at a time per process', () {
      fakeAsync((async) {
        final rig = Rig(async);
        final host = RemoteInputHost(platform: FakeHostPlatform());
        final other = MemoryInputLink.pair();
        expect(
          () => host.enable(
            link: other.host,
            surface: const SharedSurface.display(1),
          ),
          throwsStateError,
        );
        expect(RemoteInputHost.activeSession, same(rig.session));
        rig.session.stop();
        expect(RemoteInputHost.activeSession, isNull);
        final again = host.enable(
          link: other.host,
          surface: const SharedSurface.display(1),
        );
        expect(RemoteInputHost.activeSession, same(again));
      });
    });

    test('refuses when the platform is unavailable', () {
      final platform = FakeHostPlatform()
        ..unavailable = HostUnavailableReason.permissionDenied;
      expect(
        () => RemoteInputHost(platform: platform).enable(
          link: MemoryInputLink.pair().host,
          surface: const SharedSurface.display(1),
        ),
        throwsA(
          isA<HostUnavailableException>().having(
            (e) => e.reason,
            'reason',
            HostUnavailableReason.permissionDenied,
          ),
        ),
      );
      expect(RemoteInputHost.activeSession, isNull);
    });

    test('has no default platform yet', () {
      expect(RemoteInputHost.isSupported, isFalse);
      expect(RemoteInputHost.new, throwsA(isA<HostUnavailableException>()));
    });

    test('refuses an unknown surface or a past expiry', () {
      final host = RemoteInputHost(platform: FakeHostPlatform());
      final link = MemoryInputLink.pair().host;
      expect(
        () => host.enable(link: link, surface: const SharedSurface.display(9)),
        throwsArgumentError,
      );
      expect(
        () => host.enable(
          link: link,
          surface: const SharedSurface.display(1),
          options: HostOptions(
            expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
          ),
        ),
        throwsArgumentError,
      );
      expect(RemoteInputHost.activeSession, isNull);
    });
  });

  group('pointer', () {
    test('maps onto a display left of and above the primary', () {
      fakeAsync((async) {
        const bounds = Rect.fromLTWH(-1920, -200, 1920, 1080);
        final platform = FakeHostPlatform(
          surfaces: FakeSurfaceResolver(
            displays: [
              const DisplayInfo(
                id: 2,
                bounds: bounds,
                scaleFactor: 1,
                isPrimary: false,
              ),
            ],
          ),
        );
        final rig = Rig(
          async,
          platform: platform,
          surface: const SharedSurface.display(2),
        );
        for (final (x, y) in [(0, 0), (65535, 65535), (32768, 32768)]) {
          rig.viewer.move(x, y);
          rig.flush();
          rig.elapse(const Duration(milliseconds: 5));
        }
        expect(rig.events, [
          InjectedMove(point(bounds, 0, 0)),
          InjectedMove(point(bounds, 65535, 65535)),
          InjectedMove(point(bounds, 32768, 32768)),
        ]);
        final first = (rig.events.first as InjectedMove).point;
        expect(first.dx, closeTo(-1920, 0.02));
        expect(first.dy, closeTo(-200, 0.01));
      });
    });

    test('maps onto app-supplied bounds, inside their content insets', () {
      fakeAsync((async) {
        final surface = SharedSurface.rect(
          const Rect.fromLTWH(100, 50, 800, 600),
          contentInsets: const EdgeInsets.only(top: 28),
        );
        final rig = Rig(async, surface: surface);
        rig.viewer.move(0, 0);
        rig.flush();
        expect(
          rig.events.single,
          InjectedMove(point(const Rect.fromLTWH(100, 78, 800, 572), 0, 0)),
        );
        (surface as RectSurface).update(const Rect.fromLTWH(0, 0, 400, 300));
        rig.elapse(const Duration(milliseconds: 5));
        rig.viewer.move(65535, 0);
        rig.flush();
        expect(
          rig.events.last,
          InjectedMove(point(const Rect.fromLTWH(0, 28, 400, 272), 65535, 0)),
        );
      });
    });

    test('clicks, double clicks and drags', () {
      fakeAsync((async) {
        final rig = Rig(async);
        final p = point(display, 1000, 2000);
        rig.viewer
          ..button(1000, 2000, PointerButton.left, down: true)
          ..button(1000, 2000, PointerButton.left, down: false)
          ..button(1000, 2000, PointerButton.left, down: true, clickCount: 2)
          ..move(3000, 3000, buttons: PointerButton.left.mask)
          ..button(3000, 3000, PointerButton.left, down: false, clickCount: 2);
        rig.flush();
        rig.elapse(const Duration(milliseconds: 10));
        final q = point(display, 3000, 3000);
        expect(rig.events, [
          InjectedButton(p, PointerButton.left, down: true),
          InjectedButton(p, PointerButton.left, down: false),
          InjectedButton(p, PointerButton.left, down: true, clickCount: 2),
          InjectedMove(q, heldButtons: {PointerButton.left}),
          InjectedButton(q, PointerButton.left, down: false, clickCount: 2),
        ]);
      });
    });

    test('drops moves older than a pointer event already applied', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.viewer.move(10, 10, seq: 5);
        rig.flush();
        rig.elapse(const Duration(milliseconds: 5));
        rig.viewer.move(20, 20, seq: 3);
        rig.flush();
        rig.elapse(const Duration(milliseconds: 5));
        expect(rig.events, hasLength(1));
        expect(rig.dropped(DropReason.staleMove), 1);

        // A move that arrives after the click it preceded.
        rig.viewer.seq = 10;
        rig.viewer
          ..button(500, 500, PointerButton.left, down: true)
          ..button(500, 500, PointerButton.left, down: false);
        rig.flush();
        rig.viewer.move(30, 30, seq: 9);
        rig.flush();
        rig.elapse(const Duration(milliseconds: 5));
        expect(rig.events.whereType<InjectedMove>(), hasLength(1));
        expect(rig.dropped(DropReason.staleMove), 2);
      });
    });

    test('coalesces moves to the newest, at most one per 4 ms', () {
      fakeAsync((async) {
        final rig = Rig(async);
        for (var i = 0; i < 10; i++) {
          rig.viewer.move(i * 100, i * 100);
        }
        rig.flush();
        expect(rig.events, [InjectedMove(point(display, 0, 0))]);
        rig.elapse(const Duration(milliseconds: 4));
        expect(rig.events, hasLength(2));
        expect(rig.events.last, InjectedMove(point(display, 900, 900)));
        expect(rig.dropped(DropReason.coalesced), 8);
      });
    });

    test('holds a move until the reliable input before it arrives', () {
      fakeAsync((async) {
        final rig = Rig(async);
        // The viewer pressed (seq 0), then moved (seq 1); the move arrives
        // first.
        rig.viewer.move(
          5000,
          5000,
          seq: 1,
          reliableSeq: 0,
          buttons: PointerButton.left.mask,
        );
        rig.flush();
        rig.elapse(const Duration(milliseconds: 10));
        expect(rig.events, isEmpty);
        rig.viewer.seq = 0;
        rig.viewer.button(100, 100, PointerButton.left, down: true);
        rig.flush();
        expect(rig.events, [
          InjectedButton(
            point(display, 100, 100),
            PointerButton.left,
            down: true,
          ),
          InjectedMove(
            point(display, 5000, 5000),
            heldButtons: {PointerButton.left},
          ),
        ]);
      });
    });

    test('drops a move whose buttons disagree with what the host holds', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.viewer.move(10, 10, buttons: PointerButton.left.mask);
        rig.flush();
        expect(rig.events, isEmpty);
        expect(rig.dropped(DropReason.inconsistentMove), 1);
      });
    });

    test('a new surface bumps the epoch, tells the viewer, and drops '
        'input aimed at the old one', () {
      fakeAsync((async) {
        final platform = FakeHostPlatform(
          surfaces: FakeSurfaceResolver(
            displays: [
              const DisplayInfo(
                id: 1,
                bounds: display,
                scaleFactor: 1,
                isPrimary: true,
              ),
              const DisplayInfo(
                id: 2,
                bounds: Rect.fromLTWH(1920, 0, 1280, 720),
                scaleFactor: 2,
                isPrimary: false,
              ),
            ],
          ),
        );
        final rig = Rig(async, platform: platform);
        rig.viewer.button(10, 10, PointerButton.left, down: true);
        rig.flush();
        rig.session.changeSurface(const SharedSurface.display(2));
        expect(rig.session.surfaceEpoch, 1);
        expect(
          rig.events.last,
          InjectedButton(
            point(display, 10, 10),
            PointerButton.left,
            down: false,
          ),
        );
        rig.flush();
        final surface = rig.viewer.received.whereType<SurfaceMessage>().single;
        expect(
          (surface.surfaceEpoch, surface.width, surface.height),
          (1, 2560, 1440),
        );
        rig.injector.clear();
        rig.viewer.button(10, 10, PointerButton.left, down: true, epoch: 0);
        rig.flush();
        expect(rig.events, isEmpty);
        expect(rig.dropped(DropReason.staleEpoch), 1);
        rig.viewer.button(10, 10, PointerButton.left, down: true, epoch: 1);
        rig.flush();
        expect(rig.events, hasLength(1));
      });
    });

    test('clamps wheel deltas', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.viewer
          ..wheel(0, 0, dy: 5000)
          ..wheel(0, 0, dx: -50, unit: WheelUnit.line);
        rig.flush();
        final p = point(display, 0, 0);
        expect(rig.events, [
          InjectedWheel(p, dx: 0, dy: 1200, unit: WheelUnit.pixel),
          InjectedWheel(p, dx: -10, dy: 0, unit: WheelUnit.line),
        ]);
      });
    });
  });

  group('keyboard', () {
    test('presses, repeats and releases keys', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.viewer
          ..key(usageA, KeyAction.down)
          ..key(usageA, KeyAction.repeat)
          ..key(usageA, KeyAction.down)
          ..key(usageA, KeyAction.up)
          ..key(usageA, KeyAction.up)
          ..key(usageB, KeyAction.repeat);
        rig.flush();
        expect(rig.events, [
          const InjectedKey(usageA, down: true),
          const InjectedKey(usageA, down: true, repeat: true),
          const InjectedKey(usageA, down: true, repeat: true),
          const InjectedKey(usageA, down: false),
        ]);
        expect(rig.dropped(DropReason.notHeld), 2);
      });
    });

    test('types text without control characters', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.viewer
          ..text('a\u001bb\b\n\tc\u0085')
          ..text('\u0007');
        rig.flush();
        expect(rig.events, [const InjectedText('ab\n\tc')]);
        expect(rig.dropped(DropReason.filtered), 1);
      });
    });

    test('with allowKeyboard false, drops keys and text', () {
      fakeAsync((async) {
        final rig = Rig(
          async,
          options: const HostOptions(allowKeyboard: false),
        );
        rig.viewer
          ..key(usageA, KeyAction.down)
          ..text('hi')
          ..button(0, 0, PointerButton.left, down: true);
        rig.flush();
        expect(rig.events, hasLength(1));
        expect(rig.dropped(DropReason.keyboardDisabled), 2);
      });
    });

    test("drops presses the app's KeyFilter rejects", () {
      fakeAsync((async) {
        final rig = Rig(
          async,
          options: HostOptions(
            keyFilter: (press) =>
                !(press.usage == usageR &&
                    press.heldModifiers.contains(HidModifier.metaLeft)),
          ),
        );
        rig.viewer
          ..key(
            HidModifier.metaLeft,
            KeyAction.down,
            modifiers: KeyModifiers.meta,
          )
          ..key(usageR, KeyAction.down, modifiers: KeyModifiers.meta)
          ..key(usageR, KeyAction.up, modifiers: KeyModifiers.meta)
          ..key(HidModifier.metaLeft, KeyAction.up);
        rig.flush();
        expect(rig.events, [
          const InjectedKey(HidModifier.metaLeft, down: true),
          const InjectedKey(HidModifier.metaLeft, down: false),
        ]);
        expect(rig.dropped(DropReason.filtered), 1);
      });
    });

    test('holds at most maxHeldKeys', () {
      fakeAsync((async) {
        final rig = Rig(async);
        for (var i = 0; i < 9; i++) {
          rig.viewer.key(usageA + i, KeyAction.down);
        }
        rig.flush();
        expect(rig.events, hasLength(8));
        expect(rig.dropped(DropReason.tooManyKeys), 1);
      });
    });

    test('releases modifiers the viewer no longer reports', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.viewer
          ..key(
            HidModifier.shiftLeft,
            KeyAction.down,
            modifiers: KeyModifiers.shift,
          )
          ..key(usageA, KeyAction.down);
        rig.flush();
        expect(rig.events, [
          const InjectedKey(HidModifier.shiftLeft, down: true),
          const InjectedKey(HidModifier.shiftLeft, down: false),
          const InjectedKey(usageA, down: true),
        ]);
      });
    });

    test('maps Command to Control between a Mac viewer and a Windows host', () {
      fakeAsync((async) {
        final rig = Rig(async, viewerPlatform: PeerPlatform.macos);
        rig.viewer
          ..key(
            HidModifier.metaLeft,
            KeyAction.down,
            modifiers: KeyModifiers.meta,
          )
          ..key(usageA, KeyAction.down, modifiers: KeyModifiers.meta);
        rig.flush();
        expect(rig.events, [
          const InjectedKey(HidModifier.controlLeft, down: true),
          const InjectedKey(usageA, down: true),
        ]);
      });
    });

    test('leaves modifiers alone with ModifierMapping.none, or two Macs', () {
      fakeAsync((async) {
        final rig = Rig(
          async,
          viewerPlatform: PeerPlatform.macos,
          options: const HostOptions(modifierMapping: ModifierMapping.none),
        );
        rig.viewer.key(
          HidModifier.metaLeft,
          KeyAction.down,
          modifiers: KeyModifiers.meta,
        );
        rig.flush();
        expect(rig.events, [
          const InjectedKey(HidModifier.metaLeft, down: true),
        ]);
        rig.session.stop();

        final mac = Rig(
          async,
          viewerPlatform: PeerPlatform.ios,
          platform: FakeHostPlatform(platform: PeerPlatform.macos),
        );
        mac.viewer.key(
          HidModifier.metaLeft,
          KeyAction.down,
          modifiers: KeyModifiers.meta,
        );
        mac.flush();
        expect(mac.events, [
          const InjectedKey(HidModifier.metaLeft, down: true),
        ]);
      });
    });

    test('types long text at the text rate', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.viewer.text('x' * 1000);
        rig.flush();
        String typed() =>
            rig.events.whereType<InjectedText>().map((e) => e.text).join();
        expect(typed(), hasLength(400)); // the burst
        rig.elapse(const Duration(seconds: 1));
        expect(typed().length, inInclusiveRange(590, 610));
        rig.elapse(const Duration(seconds: 2));
        expect(typed(), 'x' * 1000);
      });
    });
  });

  group('instant stop', () {
    test('stop() releases what the session holds before it returns', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.viewer
          ..key(usageA, KeyAction.down)
          ..button(10, 10, PointerButton.right, down: true);
        rig.flush();
        rig.injector.clear();
        rig.session.stop();
        expect(rig.session.state, const SessionStopped(StopReason.byHost));
        expect(rig.events, [
          const InjectedKey(usageA, down: false),
          InjectedButton(
            point(display, 10, 10),
            PointerButton.right,
            down: false,
          ),
        ]);
        rig.viewer
          ..key(usageB, KeyAction.down)
          ..move(5, 5);
        rig.flush();
        rig.elapse(const Duration(seconds: 1));
        expect(rig.events, hasLength(2));
        expect(
          rig.viewer.states.last,
          isA<HostState>()
              .having((s) => s.state, 'state', HostStateCode.stopped)
              .having((s) => s.reason, 'reason', StopReason.byHost.code),
        );
        expect(rig.states.last, const SessionStopped(StopReason.byHost));
        rig.session.stop();
        expect(rig.session.state, const SessionStopped(StopReason.byHost));
      });
    });

    test('stop() discards queued input', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.viewer.text('y' * 1000);
        rig.flush();
        rig.session.stop();
        rig.elapse(const Duration(seconds: 10));
        expect(
          rig.events.whereType<InjectedText>().map((e) => e.text).join(),
          hasLength(400),
        );
      });
    });

    test('stopAll() stops the live session', () {
      fakeAsync((async) {
        final rig = Rig(async);
        RemoteInputHost.stopAll();
        expect(rig.session.state, const SessionStopped(StopReason.stopAll));
        expect(RemoteInputHost.activeSession, isNull);
      });
    });

    test('stops when the link closes', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.hostLink.close();
        rig.flush();
        expect(rig.session.state, const SessionStopped(StopReason.linkClosed));
      });
    });

    test('stops when the viewer says goodbye', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.viewer.send(const Bye(ByeReason.closed));
        rig.flush();
        expect(rig.session.state, const SessionStopped(StopReason.viewerLeft));
      });
    });

    test('stops at expiresAt', () {
      fakeAsync((async) {
        final rig = Rig(
          async,
          options: HostOptions(
            expiresAt: DateTime.now().add(const Duration(minutes: 5)),
          ),
        );
        rig.elapse(const Duration(minutes: 4, seconds: 59));
        expect(rig.session.state, const SessionActive());
        rig.elapse(const Duration(seconds: 2));
        expect(rig.session.state, const SessionStopped(StopReason.expired));
      });
    });

    test('stops when the shared window closes or app bounds are closed', () {
      fakeAsync((async) {
        final platform = FakeHostPlatform();
        platform.surfaces.windows[42] = const SurfaceGeometry(
          bounds: Rect.fromLTWH(10, 10, 500, 400),
          pixelSize: Size(500, 400),
        );
        final rig = Rig(
          async,
          platform: platform,
          surface: const SharedSurface.window(42),
        );
        platform.surfaces.windows.remove(42);
        rig.viewer.button(0, 0, PointerButton.left, down: true);
        rig.flush();
        expect(rig.session.state, const SessionStopped(StopReason.surfaceGone));

        final rect = RectSurface(const Rect.fromLTWH(0, 0, 10, 10));
        final rig2 = Rig(async, surface: rect);
        rect.close();
        rig2.viewer.move(0, 0);
        rig2.flush();
        expect(
          rig2.session.state,
          const SessionStopped(StopReason.surfaceGone),
        );
      });
    });

    test('releases held input when the viewer goes quiet', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.viewer.key(usageA, KeyAction.down);
        rig.flush();
        rig.elapse(const Duration(seconds: 4));
        expect(rig.events, hasLength(1));
        rig.elapse(const Duration(seconds: 2));
        expect(rig.events.last, const InjectedKey(usageA, down: false));
        expect(rig.session.state, const SessionActive());
      });
    });

    test('ReleaseAll releases what the session holds', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.viewer
          ..key(usageA, KeyAction.down)
          ..key(usageB, KeyAction.down)
          ..releaseAll();
        rig.flush();
        expect(rig.events.skip(2), [
          const InjectedKey(usageA, down: false),
          const InjectedKey(usageB, down: false),
        ]);
      });
    });
  });

  group('local input wins', () {
    test('pauses, releases, and resumes after localIdle', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.viewer.key(usageA, KeyAction.down);
        rig.flush();
        rig.platform.localActivity.simulateInput();
        expect(rig.session.state, const SessionPaused(PauseReason.localInput));
        expect(rig.events.last, const InjectedKey(usageA, down: false));
        rig.flush();
        expect(rig.viewer.states.last.state, HostStateCode.paused);

        rig.viewer.key(usageB, KeyAction.down);
        rig.flush();
        expect(rig.dropped(DropReason.inactive), 1);

        rig.elapse(const Duration(milliseconds: 1000));
        rig.platform.localActivity.simulateInput(); // still typing
        rig.elapse(const Duration(milliseconds: 1000));
        expect(rig.session.state, const SessionPaused(PauseReason.localInput));
        rig.elapse(const Duration(milliseconds: 600));
        expect(rig.session.state, const SessionActive());
        rig.flush();
        expect(rig.viewer.states.last.state, HostStateCode.active);
      });
    });

    test('with ResumePolicy.manual, waits for resume()', () {
      fakeAsync((async) {
        final rig = Rig(
          async,
          options: const HostOptions(resumePolicy: ResumePolicy.manual),
        );
        rig.platform.localActivity.simulateInput();
        rig.elapse(const Duration(seconds: 10));
        expect(rig.session.state, const SessionPaused(PauseReason.localInput));
        rig.session.resume();
        expect(rig.session.state, const SessionActive());
      });
    });

    test('the host app can pause and resume', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.session.pause();
        expect(rig.session.state, const SessionPaused(PauseReason.byHost));
        rig.platform.localActivity.simulateInput();
        rig.elapse(const Duration(seconds: 2));
        expect(rig.session.state, const SessionPaused(PauseReason.byHost));
        rig.session.resume();
        expect(rig.session.state, const SessionActive());
      });
    });
  });

  group('secure contexts', () {
    test('secure input blocks keys but not the pointer', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.platform.secureContext.keyboard = BlockReason.secureInput;
        rig.viewer
          ..key(usageA, KeyAction.down)
          ..text('secret');
        rig.flush();
        expect(rig.events, isEmpty);
        expect(
          rig.session.state,
          const SessionBlocked(BlockReason.secureInput),
        );
        rig.viewer.button(0, 0, PointerButton.left, down: true);
        rig.flush();
        expect(rig.events, hasLength(1));

        rig.platform.secureContext.keyboard = null;
        rig.elapse(const Duration(milliseconds: 300));
        expect(rig.session.state, const SessionActive());
      });
    });

    test('an elevated target refused by the OS blocks until it clears', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.injector.onInject = (_) => InjectResult.elevatedTarget;
        rig.viewer.button(0, 0, PointerButton.left, down: true);
        rig.flush();
        expect(
          rig.session.state,
          const SessionBlocked(BlockReason.elevatedTarget),
        );
        rig.injector.onInject = null;
        rig.elapse(const Duration(milliseconds: 300));
        expect(rig.session.state, const SessionActive());
      });
    });

    test('a revoked permission stops the session', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.injector.onInject = (_) => InjectResult.permissionDenied;
        rig.viewer.key(usageA, KeyAction.down);
        rig.flush();
        expect(
          rig.session.state,
          const SessionStopped(StopReason.permissionDenied),
        );
      });
    });

    test('a window surface confines the pointer and keys', () {
      fakeAsync((async) {
        final platform = FakeHostPlatform();
        platform.surfaces.windows[7] = const SurfaceGeometry(
          bounds: Rect.fromLTWH(0, 0, 800, 600),
          pixelSize: Size(800, 600),
        );
        final rig = Rig(
          async,
          platform: platform,
          surface: const SharedSurface.window(7),
        );
        platform.surfaces.occluded = (p) => p.dx > 400;
        rig.viewer
          ..button(60000, 0, PointerButton.left, down: true)
          ..button(1000, 0, PointerButton.left, down: true);
        rig.flush();
        expect(rig.events, hasLength(1));
        expect(rig.dropped(DropReason.occluded), 1);

        platform.surfaces.keyboardFocus = false;
        rig.viewer.key(usageA, KeyAction.down);
        rig.flush();
        expect(rig.dropped(DropReason.notFocused), 1);
        expect(
          rig.session.state,
          const SessionBlocked(BlockReason.windowNotInFront),
        );
        rig.viewer.move(20, 20, buttons: PointerButton.left.mask);
        rig.flush();
        expect(rig.events.last, isA<InjectedMove>()); // the pointer continues
        platform.surfaces.keyboardFocus = true;
        rig.elapse(const Duration(milliseconds: 300));
        expect(rig.session.state, const SessionActive());

        platform.surfaces.windows[7] = const SurfaceGeometry(
          bounds: Rect.fromLTWH(0, 0, 800, 600),
          pixelSize: Size(800, 600),
          isHidden: true,
        );
        rig.viewer.move(10, 10, buttons: PointerButton.left.mask);
        rig.flush();
        expect(
          rig.session.state,
          const SessionBlocked(BlockReason.surfaceHidden),
        );
        platform.surfaces.windows[7] = const SurfaceGeometry(
          bounds: Rect.fromLTWH(0, 0, 800, 600),
          pixelSize: Size(800, 600),
        );
        rig.elapse(const Duration(milliseconds: 300));
        expect(rig.session.state, const SessionActive());
      });
    });
  });

  group('limits and violations', () {
    test('a full queue stops the session for flooding', () {
      fakeAsync((async) {
        final rig = Rig(async);
        // 120 go at once (the burst), 64 queue, the next overflows.
        for (var i = 0; i < 184; i++) {
          rig.viewer.wheel(0, 0, dy: 1);
        }
        rig.flush();
        expect(rig.events, hasLength(120));
        expect(rig.session.state, const SessionActive());
        rig.viewer.wheel(0, 0, dy: 1);
        rig.flush();
        expect(rig.session.state, const SessionStopped(StopReason.flooding));
      });
    });

    test('queued input drains at the event rate', () {
      fakeAsync((async) {
        final rig = Rig(async);
        for (var i = 0; i < 180; i++) {
          rig.viewer.wheel(0, 0, dy: 1);
        }
        rig.flush();
        expect(rig.events, hasLength(120));
        rig.elapse(const Duration(milliseconds: 500));
        expect(rig.events.length, inInclusiveRange(149, 151));
        rig.elapse(const Duration(milliseconds: 600));
        expect(rig.events, hasLength(180));
      });
    });

    test('counts each kind of violation', () {
      fakeAsync((async) {
        final rig = Rig(async);
        final v = rig.viewer;
        v.sendBytes(Uint8List.fromList([0x20, 0, 0])); // short
        v.send(const ReleaseAll(100), sessionTag: v.tag ^ 1);
        v.key(usageA, KeyAction.down);
        v.send(
          KeyMessage(0, usage: usageB, action: KeyAction.down, modifiers: 0),
        );
        v.send(
          KeyMessage(
            v.next(),
            usage: usageB,
            action: KeyAction.down,
            modifiers: 0,
          ),
          unreliable: true,
        );
        v.send(const Pong(id: 1, viewerMicros: 1));
        v.sendBytes(Uint8List(3000));
        v.sendBytes(Uint8List.fromList([0xC5, 0, 0]));
        rig.flush();
        expect(rig.session.stats.violations, {
          ViolationKind.malformed: 1,
          ViolationKind.wrongSession: 1,
          ViolationKind.replayed: 1,
          ViolationKind.wrongChannel: 1,
          ViolationKind.wrongDirection: 1,
          ViolationKind.oversized: 1,
        });
        expect(rig.session.stats.ignored, 1);
        expect(rig.session.state, const SessionActive());
      });
    });

    test('more than 50 violations in 10 seconds stop the session', () {
      fakeAsync((async) {
        final rig = Rig(async);
        for (var i = 0; i < 50; i++) {
          rig.viewer.sendBytes(Uint8List.fromList([0x01]));
        }
        rig.flush();
        expect(rig.session.state, const SessionActive());
        rig.elapse(const Duration(seconds: 11));
        for (var i = 0; i < 50; i++) {
          rig.viewer.sendBytes(Uint8List.fromList([0x01]));
        }
        rig.flush();
        expect(rig.session.state, const SessionActive());
        rig.viewer.sendBytes(Uint8List.fromList([0x01]));
        rig.flush();
        expect(
          rig.session.state,
          const SessionStopped(StopReason.protocolViolation),
        );
      });
    });

    test('answers pings', () {
      fakeAsync((async) {
        final rig = Rig(async);
        rig.viewer.send(const Ping(id: 7, viewerMicros: 123456));
        rig.flush();
        final pong = rig.viewer.received.whereType<Pong>().single;
        expect((pong.id, pong.viewerMicros), (7, 123456));
      });
    });

    test('limits cannot be raised past their caps', () {
      expect(() => InputLimits(eventRate: 201), throwsArgumentError);
      expect(() => InputLimits(maxMessageBytes: 4097), throwsArgumentError);
      expect(() => InputLimits(maxHeldKeys: 0), throwsArgumentError);
      expect(InputLimits(eventRate: 200).eventRate, 200);
    });

    test('survives a flood of random bytes', () {
      fakeAsync((async) {
        final rig = Rig(async);
        final seed = Uint8List.fromList(List.generate(64, (i) => i * 37 % 256));
        for (var i = 0; i < 2000; i++) {
          final bytes = seed.sublist(0, 1 + i % 60)..[0] = i % 256;
          rig.viewer.sendBytes(bytes, unreliable: i.isOdd);
        }
        rig.flush();
        rig.elapse(const Duration(seconds: 1));
        expect(rig.session.state.isStopped, isTrue);
      });
    });
  });
}
