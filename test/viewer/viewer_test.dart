import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/src/protocol/codec.dart';
import 'package:remote_input/src/protocol/messages.dart';
import 'package:remote_input/src/viewer/viewer.dart' show splitUtf8;
import 'package:remote_input/testing.dart';

const usageA = 0x00070004;
const usageC = 0x00070006;
const display = Rect.fromLTWH(0, 0, 1920, 1080);

/// Where normalized [p] lands on [bounds], as the viewer and host compute
/// it together.
Offset landing(Rect bounds, Offset p) {
  int unit(double v) => (v * 65536).floor().clamp(0, 65535);
  return Offset(
    bounds.left + (unit(p.dx) + 0.5) * bounds.width / 65536,
    bounds.top + (unit(p.dy) + 0.5) * bounds.height / 65536,
  );
}

final class Pair {
  Pair(
    this.async, {
    double loss = 0,
    bool reorder = false,
    HostOptions options = const HostOptions(),
    ViewerOptions viewerOptions = const ViewerOptions(
      platform: PeerPlatform.windows,
    ),
  }) {
    links = MemoryInputLink.pair(
      loss: loss,
      reorder: reorder,
      random: Random(7),
    );
    session = RemoteInputHost(platform: platform).enable(
      link: links.host,
      surface: const SharedSurface.display(1),
      options: options,
    );
    viewer = RemoteInputViewer(link: links.viewer, options: viewerOptions);
    viewer.stateChanges.listen(viewerStates.add);
    async.flushMicrotasks();
  }

  final FakeAsync async;
  final FakeHostPlatform platform = FakeHostPlatform();
  late final ({MemoryInputLink host, MemoryInputLink viewer}) links;
  late final ControlSession session;
  late final RemoteInputViewer viewer;
  final List<SessionState> viewerStates = [];

  List<InjectedEvent> get events => platform.injector.events;

  void settle([Duration d = const Duration(milliseconds: 20)]) {
    async
      ..flushMicrotasks()
      ..elapse(d);
  }
}

void main() {
  tearDown(RemoteInputHost.stopAll);

  test('handshakes and mirrors the host state', () {
    fakeAsync((async) {
      final p = Pair(async);
      expect(p.session.state, const SessionActive());
      expect(p.viewer.state, const SessionActive());
      expect(p.viewer.surface!.pixelSize, const Size(1920, 1080));
      expect(p.session.viewerPlatform, PeerPlatform.windows);

      p.session.pause();
      p.settle();
      expect(p.viewer.state, const SessionPaused(PauseReason.byHost));
      p.session.resume();
      p.settle();
      expect(p.viewer.state, const SessionActive());

      p.session.stop();
      p.settle();
      expect(p.viewer.state, const SessionStopped(StopReason.byHost));
      expect(p.viewerStates, [
        const SessionWaiting(),
        const SessionActive(),
        const SessionPaused(PauseReason.byHost),
        const SessionActive(),
        const SessionStopped(StopReason.byHost),
      ]);
    });
  });

  test('sends nothing until the host says active', () {
    fakeAsync((async) {
      final links = MemoryInputLink.pair();
      final viewer = RemoteInputViewer(link: links.viewer);
      viewer
        ..pointerMove(const Offset(0.5, 0.5))
        ..key(usageA, KeyAction.down)
        ..text('hi');
      async.flushMicrotasks();
      expect(links.viewer.reliable.sentCount, 0);
      expect(links.viewer.unreliable.sentCount, 0);
      expect(viewer.stats.droppedWhileInactive, 3);
    });
  });

  test('clicks, types and scrolls end to end', () {
    fakeAsync((async) {
      final p = Pair(async);
      const at = Offset(0.25, 0.75);
      p.viewer
        ..click(at, clickCount: 1)
        ..key(usageA, KeyAction.down)
        ..key(usageA, KeyAction.up)
        ..text('héllo 👋')
        ..wheel(at, dy: 120.4);
      p.settle();
      final q = landing(display, at);
      expect(p.events, [
        InjectedButton(q, PointerButton.left, down: true),
        InjectedButton(q, PointerButton.left, down: false),
        const InjectedKey(usageA, down: true),
        const InjectedKey(usageA, down: false),
        const InjectedText('héllo 👋'),
        InjectedWheel(q, dx: 0, dy: 120, unit: WheelUnit.pixel),
      ]);
    });
  });

  test('clamps points to the surface', () {
    fakeAsync((async) {
      final p = Pair(async);
      p.viewer.click(const Offset(-0.5, 1.5));
      p.settle();
      expect(
        (p.events.first as InjectedButton).point,
        landing(display, const Offset(0, 1)),
      );
    });
  });

  test('coalesces moves to one per moveInterval', () {
    fakeAsync((async) {
      final p = Pair(async);
      final before = p.links.viewer.unreliable.sentCount;
      for (var i = 0; i < 10; i++) {
        p.viewer.pointerMove(Offset(i / 10, 0.5));
      }
      p.settle(const Duration(milliseconds: 9));
      expect(p.links.viewer.unreliable.sentCount - before, 2);
      expect(p.viewer.stats.movesCoalesced, 8);
      expect(
        p.events.last,
        InjectedMove(landing(display, const Offset(0.9, 0.5))),
      );
    });
  });

  test('a button drops the move pending before it', () {
    fakeAsync((async) {
      final p = Pair(async);
      p.viewer.pointerMove(const Offset(0.1, 0.1));
      p.viewer.pointerMove(const Offset(0.2, 0.2)); // pending
      p.viewer.pointerButton(
        const Offset(0.3, 0.3),
        PointerButton.left,
        down: true,
      );
      p.settle();
      expect(p.events, [
        InjectedMove(landing(display, const Offset(0.1, 0.1))),
        InjectedButton(
          landing(display, const Offset(0.3, 0.3)),
          PointerButton.left,
          down: true,
        ),
      ]);
    });
  });

  test('drags report held buttons', () {
    fakeAsync((async) {
      final p = Pair(async);
      p.viewer.pointerButton(
        const Offset(0.1, 0.1),
        PointerButton.left,
        down: true,
      );
      p.viewer.pointerMove(const Offset(0.5, 0.5));
      p.settle();
      p.viewer.pointerButton(
        const Offset(0.5, 0.5),
        PointerButton.left,
        down: false,
      );
      p.settle();
      expect(
        p.events[1],
        InjectedMove(
          landing(display, const Offset(0.5, 0.5)),
          heldButtons: {PointerButton.left},
        ),
      );
      expect(p.viewer.heldButtons, isEmpty);
    });
  });

  test('splits long text into messages the host types in full', () {
    fakeAsync((async) {
      final p = Pair(async);
      final text = 'é' * 900; // 1800 bytes: two messages
      final before = p.links.viewer.reliable.sentCount;
      p.viewer.text(text);
      expect(p.links.viewer.reliable.sentCount - before, 2);
      p.settle(const Duration(seconds: 5));
      expect(
        p.events.whereType<InjectedText>().map((e) => e.text).join(),
        text,
      );
    });
  });

  test('sendShortcut presses in order and releases in reverse', () {
    fakeAsync((async) {
      final p = Pair(async);
      p.viewer.sendShortcut([HidModifier.controlLeft, usageC]);
      p.settle();
      expect(p.events, [
        const InjectedKey(HidModifier.controlLeft, down: true),
        const InjectedKey(usageC, down: true),
        const InjectedKey(usageC, down: false),
        const InjectedKey(HidModifier.controlLeft, down: false),
      ]);
    });
  });

  test('a Mac viewer copy-pastes on a Windows host with Control', () {
    fakeAsync((async) {
      final p = Pair(
        async,
        viewerOptions: const ViewerOptions(platform: PeerPlatform.macos),
      );
      p.viewer.sendShortcut([HidModifier.metaLeft, usageC]);
      p.settle();
      expect(
        p.events.first,
        const InjectedKey(HidModifier.controlLeft, down: true),
      );
    });
  });

  test('releaseAll releases on the host', () {
    fakeAsync((async) {
      final p = Pair(async);
      p.viewer
        ..key(usageA, KeyAction.down)
        ..pointerButton(const Offset(0.5, 0.5), PointerButton.right, down: true)
        ..releaseAll();
      p.settle();
      expect(p.events.skip(2), [
        const InjectedKey(usageA, down: false),
        InjectedButton(
          landing(display, const Offset(0.5, 0.5)),
          PointerButton.right,
          down: false,
        ),
      ]);
      expect(p.viewer.heldButtons, isEmpty);
    });
  });

  test('close() says goodbye, and the host stops', () {
    fakeAsync((async) {
      final p = Pair(async);
      p.viewer.close();
      p.settle();
      expect(p.viewer.state, const SessionStopped(StopReason.viewerClosed));
      expect(p.session.state, const SessionStopped(StopReason.viewerLeft));
    });
  });

  test('stops when the link closes', () {
    fakeAsync((async) {
      final p = Pair(async);
      p.links.viewer.close();
      p.settle();
      expect(p.viewer.state, const SessionStopped(StopReason.linkClosed));
      expect(p.session.state, const SessionStopped(StopReason.linkClosed));
    });
  });

  test('measures the round trip, and its pings keep held keys alive', () {
    fakeAsync((async) {
      final p = Pair(async);
      p.viewer.key(usageA, KeyAction.down);
      p.settle(const Duration(seconds: 12));
      expect(p.viewer.stats.roundTripTime, Duration.zero);
      expect(p.events, [const InjectedKey(usageA, down: true)]);
    });
  });

  test('leaves a host with no common version', () {
    fakeAsync((async) {
      final links = MemoryInputLink.pair();
      final viewer = RemoteInputViewer(link: links.viewer);
      final sent = <WireMessage>[];
      links.host.reliable.messages.listen(
        (b) => sent.add((decodeMessage(b) as Decoded).message),
      );
      final nonce = Uint8List(16)..[0] = 1;
      links.host.reliable.send(
        encodeMessage(
          HostHello(
            minVersion: 2,
            maxVersion: 3,
            nonce: nonce,
            hostPlatform: PeerPlatform.macos,
            capabilities: 0,
            surfaceEpoch: 0,
            surfaceWidth: 1,
            surfaceHeight: 1,
          ),
          sessionTag: sessionTagOf(nonce),
        ),
      );
      async.flushMicrotasks();
      expect(viewer.state, const SessionStopped(StopReason.unsupportedVersion));
      expect((sent.single as Bye).reason, ByeReason.unsupportedVersion);
    });
  });

  test('over a lossy, reordering link, clicks land where aimed', () {
    fakeAsync((async) {
      final p = Pair(async, loss: 0.2, reorder: true);
      final random = Random(1);
      final targets = <Offset>[];
      for (var i = 0; i < 50; i++) {
        // A burst of moves, then a click somewhere else.
        for (var j = 0; j < 20; j++) {
          p.viewer.pointerMove(
            Offset(random.nextDouble(), random.nextDouble()),
          );
          async.elapse(const Duration(milliseconds: 3));
        }
        final target = Offset(random.nextDouble(), random.nextDouble());
        targets.add(target);
        p.viewer.click(target);
        async.elapse(const Duration(milliseconds: 3));
      }
      p.settle(const Duration(seconds: 2));
      final buttons = p.events.whereType<InjectedButton>().toList();
      expect(buttons, hasLength(100));
      for (var i = 0; i < 50; i++) {
        final q = landing(display, targets[i]);
        expect(buttons[2 * i].point, q);
        expect(buttons[2 * i + 1].point, q);
      }
      // No move was injected between a click's press and release.
      for (var i = 0; i < p.events.length - 1; i++) {
        final e = p.events[i];
        if (e is InjectedButton && e.down) {
          expect(p.events[i + 1], isA<InjectedButton>());
        }
      }
      expect(p.session.state, const SessionActive());
    });
  });

  test('a viewer that subscribes late still handshakes', () {
    fakeAsync((async) {
      final links = MemoryInputLink.pair();
      final platform = FakeHostPlatform(platform: PeerPlatform.macos);
      final session = RemoteInputHost(platform: platform)
          .enable(link: links.host, surface: const SharedSurface.display(1));
      async.flushMicrotasks(); // the first HostHello goes nowhere
      final viewer = RemoteInputViewer(link: links.viewer);
      async.elapse(const Duration(milliseconds: 1100));
      expect(viewer.state, const SessionActive());
      expect(session.state, const SessionActive());
      expect(viewer.hostPlatform, PeerPlatform.macos);
    });
  });

  test('gives up on a host that goes quiet', () {
    fakeAsync((async) {
      final links = MemoryInputLink.pair();
      final viewer = RemoteInputViewer(link: links.viewer);
      final nonce = Uint8List(16)..[0] = 9;
      links.host.reliable.send(
        encodeMessage(
          HostHello(
            minVersion: 1,
            maxVersion: 1,
            nonce: nonce,
            hostPlatform: PeerPlatform.windows,
            capabilities: 0,
            surfaceEpoch: 0,
            surfaceWidth: 100,
            surfaceHeight: 100,
          ),
          sessionTag: sessionTagOf(nonce),
        ),
      );
      async.elapse(const Duration(seconds: 9));
      expect(viewer.state, const SessionWaiting());
      async.elapse(const Duration(seconds: 3));
      expect(viewer.state, const SessionStopped(StopReason.timedOut));
    });
  });

  test('keeps round-trip percentiles', () {
    fakeAsync((async) {
      final p = Pair(async);
      p.settle(const Duration(seconds: 5));
      expect(p.viewer.stats.roundTripP50, Duration.zero);
      expect(p.viewer.stats.roundTripP95, Duration.zero);
    });
  });

  test('a shortcut can skip the Command/Control mapping', () {
    fakeAsync((async) {
      final p = Pair(
        async,
        viewerOptions: const ViewerOptions(platform: PeerPlatform.macos),
      );
      p.viewer.sendShortcut([HidModifier.metaLeft], mapModifiers: false);
      p.settle();
      expect(p.events, [
        const InjectedKey(HidModifier.metaLeft, down: true),
        const InjectedKey(HidModifier.metaLeft, down: false),
      ]);
    });
  });

  test('survives a link that starts closed', () {
    fakeAsync((async) {
      final links = MemoryInputLink.pair(open: false);
      final viewer = RemoteInputViewer(link: links.viewer);
      final session = RemoteInputHost(platform: FakeHostPlatform())
          .enable(link: links.host, surface: const SharedSurface.display(1));
      async.flushMicrotasks();
      expect(viewer.state, const SessionWaiting());
      links.host.open();
      async.elapse(const Duration(milliseconds: 50));
      expect(viewer.state, const SessionActive());
      expect(session.state, const SessionActive());
    });
  });

  test('a viewer that times out tells the host, after a grace ping', () {
    fakeAsync((async) {
      final links = MemoryInputLink.pair();
      final viewer = RemoteInputViewer(link: links.viewer);
      final fromViewer = <WireMessage>[];
      links.host.reliable.messages.listen(
        (b) => fromViewer.add((decodeMessage(b) as Decoded).message),
      );
      final nonce = Uint8List(16)..[0] = 3;
      links.host.reliable.send(
        encodeMessage(
          HostHello(
            minVersion: 1,
            maxVersion: 1,
            nonce: nonce,
            hostPlatform: PeerPlatform.windows,
            capabilities: 0,
            surfaceEpoch: 0,
            surfaceWidth: 100,
            surfaceHeight: 100,
          ),
          sessionTag: sessionTagOf(nonce),
        ),
      );
      async.elapse(const Duration(milliseconds: 11500)); // first quiet ping
      expect(viewer.state, const SessionWaiting());
      expect(fromViewer.whereType<Bye>(), isEmpty);
      async.elapse(const Duration(seconds: 1)); // the grace ping
      expect(viewer.state, const SessionStopped(StopReason.timedOut));
      expect(fromViewer.whereType<Bye>(), hasLength(1));
    });
  });

  test('cuts text past maxTextBytes and says so', () {
    fakeAsync((async) {
      final p = Pair(
        async,
        viewerOptions: const ViewerOptions(
          platform: PeerPlatform.windows,
          maxTextBytes: 2048,
        ),
      );
      expect(p.viewer.text('x' * 2048), isTrue);
      expect(p.viewer.text('y' * 3000), isFalse);
      expect(p.viewer.stats.textTruncated, 1);
      p.settle(const Duration(seconds: 30));
      final typed = p.events
          .whereType<InjectedText>()
          .map((e) => e.text)
          .join();
      expect(typed, 'x' * 2048 + 'y' * 2048);
    });
  });

  test('sendShortcut keeps modifiers already held on the host', () {
    fakeAsync((async) {
      final p = Pair(async);
      p.viewer.key(
        HidModifier.shiftLeft,
        KeyAction.down,
        modifiers: KeyModifiers.shift,
      );
      p.viewer.sendShortcut([
        HidModifier.controlLeft,
        usageC,
      ], heldModifiers: KeyModifiers.shift);
      p.settle();
      expect(
        p.events,
        isNot(contains(const InjectedKey(HidModifier.shiftLeft, down: false))),
      );
    });
  });

  test('splitUtf8 never splits a code point', () {
    final text = 'a€😀' * 300;
    final parts = splitUtf8(text, 1024);
    expect(parts.join(), text);
    for (final part in parts) {
      expect(utf8.encode(part).length, lessThanOrEqualTo(1024));
    }
    expect(splitUtf8('', 10), isEmpty);
  });
}
