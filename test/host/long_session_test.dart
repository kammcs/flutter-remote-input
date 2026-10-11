// Long sessions (RIN-18, roadmap M7): an hour of input, the seq wrap, sleep
// and wake as clock jumps, display and window changes mid-session, and an
// hour of pauses, all in fake time. What only real machines can show is in
// docs/checkpoint.md, "Long sessions".
import 'dart:math';
import 'dart:ui';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/src/protocol/messages.dart';
import 'package:remote_input/src/protocol/serial.dart';
import 'package:remote_input/testing.dart';

import '../support/raw_viewer.dart';
import 'session_test.dart' show display, point, usageA, usageB;

/// Where normalized [p] lands on [bounds], as the viewer and host compute
/// it together.
Offset landing(Rect bounds, Offset p) {
  int unit(double v) => (v * 65536).floor().clamp(0, 65535);
  return Offset(
    bounds.left + (unit(p.dx) + 0.5) * bounds.width / 65536,
    bounds.top + (unit(p.dy) + 0.5) * bounds.height / 65536,
  );
}

/// The keys and buttons [events] leave held: each press until its release.
({Set<int> keys, Set<PointerButton> buttons}) heldBy(
  Iterable<InjectedEvent> events,
) {
  final keys = <int>{};
  final buttons = <PointerButton>{};
  for (final e in events) {
    switch (e) {
      case InjectedKey(:final usage, :final down):
        down ? keys.add(usage) : keys.remove(usage);
      case InjectedButton(:final button, :final down):
        down ? buttons.add(button) : buttons.remove(button);
      case _:
        break;
    }
  }
  return (keys: keys, buttons: buttons);
}

bool isRelease(InjectedEvent e) =>
    (e is InjectedKey && !e.down) || (e is InjectedButton && !e.down);

/// Runs [body] in fake time with a wall clock the test can [jump], as the
/// wall clock does across sleep (forward) or a time sync (back), while
/// fake_async's timers, like the OS's monotonic ones, don't see the jump.
void fakeWallClock(
  void Function(FakeAsync async, void Function(Duration) jump) body,
) {
  fakeAsync((async) {
    var offset = Duration.zero;
    final fake = clock;
    withClock(
      Clock(() => fake.now().add(offset)),
      () => body(async, (d) => offset += d),
    );
  });
}

/// A host session and a real [RemoteInputViewer] over a lossless link.
final class Live {
  Live(
    this.async, {
    FakeHostPlatform? platform,
    SharedSurface surface = const SharedSurface.display(1),
    HostOptions options = const HostOptions(),
    ViewerOptions viewerOptions = const ViewerOptions(
      platform: PeerPlatform.windows,
    ),
  }) : platform = platform ?? FakeHostPlatform() {
    session = RemoteInputHost(platform: this.platform)
        .enable(link: links.host, surface: surface, options: options);
    session.stateChanges.listen(hostStates.add);
    viewer = RemoteInputViewer(link: links.viewer, options: viewerOptions);
    viewer.stateChanges.listen(viewerStates.add);
    async.flushMicrotasks();
  }

  final FakeAsync async;
  final FakeHostPlatform platform;
  final links = MemoryInputLink.pair();
  late final ControlSession session;
  late final RemoteInputViewer viewer;
  final List<SessionState> hostStates = [];
  final List<SessionState> viewerStates = [];

  RecordingInjector get injector => platform.injector;
  List<InjectedEvent> get events => injector.events;

  void settle([Duration d = const Duration(milliseconds: 20)]) {
    async
      ..flushMicrotasks()
      ..elapse(d);
  }

  int dropped(DropReason r) => session.stats.dropped[r] ?? 0;
}

/// A [RawViewer] whose seq wraps at 2^32, as the real viewer's does.
final class WrappingViewer extends RawViewer {
  WrappingViewer(super.link);

  @override
  int next() {
    final s = seq;
    seq = seqNext(seq);
    return s;
  }
}

/// A session driven by a [WrappingViewer], handshake done.
({ControlSession session, WrappingViewer viewer, FakeHostPlatform platform})
wrapRig(FakeAsync async, {bool lossy = false}) {
  final pair = MemoryInputLink.pair(
    loss: lossy ? 0.1 : 0,
    reorder: lossy,
    random: Random(18),
  );
  final platform = FakeHostPlatform();
  final viewer = WrappingViewer(pair.viewer);
  final session = RemoteInputHost(platform: platform)
      .enable(link: pair.host, surface: const SharedSurface.display(1));
  async.flushMicrotasks();
  viewer.hello();
  async.flushMicrotasks();
  return (session: session, viewer: viewer, platform: platform);
}

/// A person at the viewer: the pointer always moving (at 60 Hz, and at
/// 250 Hz every tenth minute), a key tapped every 2 s, Shift plus a key
/// every 7 s, a click about every 5 s, a one-second drag every 30 s, a
/// scroll about every 3 s and a few words typed every 10 s.
final class Person {
  Person(this.live);

  final Live live;

  /// Milliseconds since the person sat down.
  int t = 0;

  /// Where the pointer is aimed, normalized.
  Offset aim = const Offset(0.5, 0.5);

  /// Called each tick before the person acts, with [t].
  void Function(int t)? beforeTick;

  bool _shift = false;
  bool _dragging = false;

  /// Key presses sent.
  int keyDowns = 0;

  /// Key releases sent.
  int keyUps = 0;

  /// Scrolls sent.
  int wheels = 0;

  /// Where each button press was aimed, in order.
  final List<Offset> pressAims = [];

  /// The text typed.
  final StringBuffer typed = StringBuffer();

  RemoteInputViewer get _viewer => live.viewer;

  int get _modifiers => _shift ? KeyModifiers.shift : KeyModifiers.none;

  void _key(int usage, KeyAction action) {
    if (!_viewer.state.isActive) return;
    _viewer.key(usage, action, modifiers: _modifiers);
    action == KeyAction.up ? keyUps++ : keyDowns++;
  }

  void _act() {
    final active = _viewer.state.isActive;
    switch (t % 2000) {
      case 0:
        _key(usageA, KeyAction.down);
      case 80:
        _key(usageA, KeyAction.up);
    }
    switch (t % 7040) {
      case 400:
        _shift = true;
        _key(HidModifier.shiftLeft, KeyAction.down);
      case 416:
        _key(usageB, KeyAction.down);
      case 480:
        _key(usageB, KeyAction.up);
      case 496:
        _shift = false;
        _key(HidModifier.shiftLeft, KeyAction.up);
    }
    if (t % 4800 == 2400 && !_dragging && active) {
      _viewer.click(aim);
      pressAims.add(aim);
    }
    switch (t % 30000) {
      case 10000 when active:
        _viewer.pointerButton(aim, PointerButton.left, down: true);
        pressAims.add(aim);
        _dragging = true;
      case 10960:
        _viewer.pointerButton(aim, PointerButton.left, down: false);
        _dragging = false;
    }
    if (t % 3200 == 1600 && active) {
      _viewer.wheel(aim, dy: 120);
      wheels++;
    }
    if (t % 10000 == 5008 && active) {
      const words = 'the quick brown fox ';
      _viewer.text(words);
      typed.write(words);
    }
    aim = Offset(0.5 + 0.45 * sin(t / 1700), 0.5 + 0.45 * sin(t / 1100 + 1));
    _viewer.pointerMove(aim);
  }

  /// Carries on for [d].
  void run(Duration d) {
    final end = t + d.inMilliseconds;
    while (t < end) {
      final step = (t ~/ 60000) % 10 == 9 ? 4 : 16;
      beforeTick?.call(t);
      _act();
      live.async.elapse(Duration(milliseconds: step));
      t += step;
    }
  }
}

void main() {
  tearDown(RemoteInputHost.stopAll);

  test('an hour of continuous input: nothing held, nothing lost, no drift', () {
    fakeAsync((async) {
      final live = Live(
        async,
        viewerOptions: const ViewerOptions(
          platform: PeerPlatform.windows,
          moveInterval: Duration(milliseconds: 4),
        ),
      );
      expect(live.viewer.state, const SessionActive());
      final person = Person(live)..run(const Duration(hours: 1));
      live.settle(const Duration(milliseconds: 100));

      final events = live.events;
      final stats = live.session.stats;
      expect(live.session.state, const SessionActive());
      expect(live.viewer.state, const SessionActive());
      expect(live.hostStates, [const SessionWaiting(), const SessionActive()]);

      // Nothing held.
      final held = heldBy(events);
      expect(held.keys, isEmpty);
      expect(held.buttons, isEmpty);

      // Every press, release, scroll and character arrived, where aimed.
      final keys = events.whereType<InjectedKey>();
      expect(person.keyDowns, greaterThan(2000));
      expect(keys.where((e) => e.down), hasLength(person.keyDowns));
      expect(keys.where((e) => !e.down), hasLength(person.keyUps));
      expect(
        events
            .whereType<InjectedButton>()
            .where((e) => e.down)
            .map((e) => e.point),
        [for (final a in person.pressAims) landing(display, a)],
      );
      expect(events.whereType<InjectedWheel>(), hasLength(person.wheels));
      expect(
        events.whereType<InjectedText>().map((e) => e.text).join(),
        person.typed.toString(),
      );

      // No drift: the last move landed where the viewer last aimed.
      expect(
        events.whereType<InjectedMove>().last.point,
        landing(display, person.aim),
      );

      // The counts add up: every message the viewer sent was received, and
      // every move was injected or coalesced into a newer one.
      final sentReliable = live.links.viewer.reliable.sentCount;
      final sentMoves = live.links.viewer.unreliable.sentCount;
      expect(live.viewer.stats.sent, sentReliable + sentMoves);
      expect(stats.received, sentReliable + sentMoves);
      expect(stats.injected, events.length);
      expect(stats.violations, isEmpty);
      expect(stats.ignored, 0);
      expect(stats.dropped.keys, everyElement(DropReason.coalesced));
      expect(
        events.whereType<InjectedMove>().length +
            live.dropped(DropReason.coalesced),
        sentMoves,
      );
      expect(sentMoves, greaterThan(200000));

      // Nothing backed up on either side.
      expect(live.links.viewer.reliable.bufferedAmount, 0);
      expect(live.links.viewer.unreliable.bufferedAmount, 0);
      expect(live.links.host.reliable.bufferedAmount, 0);
      expect(live.viewer.stats.movesSkippedForBackpressure, 0);
      expect(live.viewer.stats.droppedWhileInactive, 0);
      expect(live.viewer.stats.roundTripP95, Duration.zero);
    });
  });

  group('the seq wrap', () {
    test('input keeps flowing across 2^32, on both channels', () {
      fakeAsync((async) {
        final r = wrapRig(async);
        final v = r.viewer..seq = seqModulus - 30;
        final expected = <InjectedEvent>[];
        for (var i = 0; i < 10; i++) {
          final x = 1000 + i * 6000;
          final y = 2000 + i * 5000;
          final p = point(display, x, y);
          final q = point(display, x + 500, y + 500);
          void pace() => async
            ..flushMicrotasks()
            ..elapse(const Duration(milliseconds: 5));
          v.move(x, y);
          pace();
          v
            ..button(x, y, PointerButton.left, down: true)
            ..move(x + 500, y + 500, buttons: PointerButton.left.mask);
          pace();
          v
            ..button(x + 500, y + 500, PointerButton.left, down: false)
            ..key(usageA, KeyAction.down)
            ..key(usageA, KeyAction.up);
          pace();
          expected.addAll([
            InjectedMove(p),
            InjectedButton(p, PointerButton.left, down: true),
            InjectedMove(q, heldButtons: {PointerButton.left}),
            InjectedButton(q, PointerButton.left, down: false),
            const InjectedKey(usageA, down: true),
            const InjectedKey(usageA, down: false),
          ]);
        }
        expect(v.seq, 30); // It wrapped.
        expect(r.platform.injector.events, expected);
        expect(r.session.stats.dropped, isEmpty);
        expect(r.session.stats.violations, isEmpty);
      });
    });

    test('a move after the wrap waits for the click before it, and a stale '
        'one or a replay from before it is refused', () {
      fakeAsync((async) {
        final r = wrapRig(async);
        final v = r.viewer..seq = 0xFFFFFFFF;
        // The viewer pressed (seq 0xFFFFFFFF), then moved (seq 0); the move
        // arrives first.
        v.move(
          5000,
          5000,
          seq: 0,
          reliableSeq: 0xFFFFFFFF,
          buttons: PointerButton.left.mask,
        );
        async
          ..flushMicrotasks()
          ..elapse(const Duration(milliseconds: 10));
        expect(r.platform.injector.events, isEmpty);
        v.button(100, 100, PointerButton.left, down: true);
        async.flushMicrotasks();
        expect(r.platform.injector.events, [
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

        // A move from before the wrap, late: dropped.
        v.move(
          9000,
          9000,
          seq: 0xFFFFFFFE,
          reliableSeq: 0xFFFFFFFE,
          buttons: PointerButton.left.mask,
        );
        async
          ..flushMicrotasks()
          ..elapse(const Duration(milliseconds: 10));
        expect(r.session.stats.dropped[DropReason.staleMove], 1);

        // A reliable message from before the wrap, replayed: a violation.
        v.send(
          KeyMessage(
            0xFFFFFFF0,
            usage: usageA,
            action: KeyAction.down,
            modifiers: 0,
          ),
        );
        async.flushMicrotasks();
        expect(r.session.stats.violations[ViolationKind.replayed], 1);

        v.seq = 1;
        v.key(usageA, KeyAction.down);
        async.flushMicrotasks();
        expect(
          r.platform.injector.events.last,
          const InjectedKey(usageA, down: true),
        );
      });
    });

    test('over a lossy, reordering link the pointer never goes back across '
        'the wrap', () {
      fakeAsync((async) {
        final r = wrapRig(async, lossy: true);
        final v = r.viewer..seq = seqModulus - 1000;
        // x grows with seq, so a pointer that went back would show.
        for (var i = 0; i < 2000; i++) {
          final x = 10 + i * 30;
          if (i % 20 == 10) {
            v
              ..button(x, 30000, PointerButton.left, down: true)
              ..button(x, 30000, PointerButton.left, down: false);
          } else {
            v.move(x, 30000);
          }
          async
            ..flushMicrotasks()
            ..elapse(const Duration(milliseconds: 2));
        }
        async.elapse(const Duration(seconds: 1));
        expect(v.seq, lessThan(1500)); // It wrapped.
        final xs = [
          for (final e in r.platform.injector.events)
            switch (e) {
              InjectedMove(:final point) => point.dx,
              InjectedButton(:final point) => point.dx,
              _ => throw StateError('unexpected event'),
            },
        ];
        for (var i = 1; i < xs.length; i++) {
          expect(xs[i], greaterThanOrEqualTo(xs[i - 1]));
        }
        final buttons = r.platform.injector.events.whereType<InjectedButton>();
        expect(buttons, hasLength(200)); // The reliable channel loses none.
        expect(heldBy(r.platform.injector.events).buttons, isEmpty);
        expect(r.session.stats.violations, isEmpty);
        expect(r.session.stats.dropped[DropReason.staleMove], greaterThan(0));
      });
    });

    test('the surface epoch wraps at 16 bits', () {
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
                scaleFactor: 1,
                isPrimary: false,
              ),
            ],
          ),
        );
        final live = Live(async, platform: platform);
        for (var i = 1; i <= 0x10000; i++) {
          live.session.changeSurface(SharedSurface.display(i.isOdd ? 2 : 1));
        }
        live.settle();
        expect(live.session.surfaceEpoch, 0);
        expect(live.viewer.surface!.epoch, 0);
        live.viewer.click(const Offset(0.5, 0.5));
        live.settle();
        expect(
          live.events.first,
          InjectedButton(
            landing(display, const Offset(0.5, 0.5)),
            PointerButton.left,
            down: true,
          ),
        );
      });
    });
  });

  group('sleep and wake', () {
    test('an expiry that passed during sleep stops the session at the first '
        'message after wake, before anything is injected', () {
      fakeWallClock((async, jump) {
        final live = Live(
          async,
          options: HostOptions(
            expiresAt: clock.now().add(const Duration(minutes: 30)),
          ),
        );
        live.viewer
          ..key(
            HidModifier.shiftLeft,
            KeyAction.down,
            modifiers: KeyModifiers.shift,
          )
          ..pointerButton(
            const Offset(0.5, 0.5),
            PointerButton.left,
            down: true,
          );
        live.settle(const Duration(minutes: 10));
        expect(live.session.state, const SessionActive());
        live.injector.clear();

        // The machine sleeps for two hours: the wall clock jumps, timers
        // (monotonic) don't move. On wake, the viewer's next ping arrives
        // long before the expiry timer fires, 20 minutes after wake.
        jump(const Duration(hours: 2));
        live.settle(const Duration(seconds: 1));
        expect(live.session.state, const SessionStopped(StopReason.expired));
        expect(live.events, [
          const InjectedKey(HidModifier.shiftLeft, down: false),
          InjectedButton(
            landing(display, const Offset(0.5, 0.5)),
            PointerButton.left,
            down: false,
          ),
        ]);
        live.settle();
        expect(live.viewer.state, const SessionStopped(StopReason.expired));
      });
    });

    test('input that arrives first after wake is not injected', () {
      fakeWallClock((async, jump) {
        final pair = MemoryInputLink.pair();
        final platform = FakeHostPlatform();
        final viewer = RawViewer(pair.viewer);
        final session = RemoteInputHost(platform: platform).enable(
          link: pair.host,
          surface: const SharedSurface.display(1),
          options: HostOptions(
            expiresAt: clock.now().add(const Duration(minutes: 30)),
          ),
        );
        async.flushMicrotasks();
        viewer.hello();
        viewer.key(usageA, KeyAction.down);
        async.flushMicrotasks();
        platform.injector.clear();
        jump(const Duration(hours: 2));
        viewer
          ..move(100, 100)
          ..button(100, 100, PointerButton.left, down: true)
          ..key(usageB, KeyAction.down)
          ..text('late');
        async.flushMicrotasks();
        expect(session.state, const SessionStopped(StopReason.expired));
        expect(platform.injector.events, [
          const InjectedKey(usageA, down: false),
        ]);
      });
    });

    test('the expiry timer still fires if the wall clock goes back', () {
      fakeWallClock((async, jump) {
        final live = Live(
          async,
          options: HostOptions(
            expiresAt: clock.now().add(const Duration(minutes: 10)),
          ),
        );
        jump(const Duration(hours: -1));
        live.settle(const Duration(minutes: 10));
        expect(live.session.state, const SessionStopped(StopReason.expired));
      });
    });

    test('held input is released heartbeatTimeout after wake when the viewer '
        'is gone', () {
      fakeWallClock((async, jump) {
        final pair = MemoryInputLink.pair();
        final platform = FakeHostPlatform();
        final viewer = RawViewer(pair.viewer);
        final session = RemoteInputHost(platform: platform)
            .enable(link: pair.host, surface: const SharedSurface.display(1));
        async.flushMicrotasks();
        viewer
          ..hello()
          ..key(
            HidModifier.controlLeft,
            KeyAction.down,
            modifiers: KeyModifiers.control,
          )
          ..button(300, 300, PointerButton.right, down: true);
        async.flushMicrotasks();
        expect(platform.injector.events, hasLength(2));

        jump(const Duration(hours: 2));
        async.elapse(const Duration(seconds: 4));
        expect(platform.injector.events, hasLength(2));
        async.elapse(const Duration(seconds: 2));
        expect(platform.injector.events.skip(2), [
          const InjectedKey(HidModifier.controlLeft, down: false),
          InjectedButton(
            point(display, 300, 300),
            PointerButton.right,
            down: false,
          ),
        ]);
        expect(heldBy(platform.injector.events).keys, isEmpty);
        expect(session.state, const SessionActive());
      });
    });

    test("the viewer's pings keep a live host across a jump, and its round "
        'trips stay sane', () {
      fakeWallClock((async, jump) {
        final live = Live(async);
        live.viewer.key(usageA, KeyAction.down);
        live.settle(const Duration(seconds: 3));
        jump(const Duration(hours: 2));
        live.settle(const Duration(seconds: 15));
        expect(live.viewer.state, const SessionActive());
        expect(live.session.state, const SessionActive());
        expect(live.viewer.stats.roundTripP95, Duration.zero);
        // Its pings kept the held key alive (the viewer's job to release).
        expect(live.events, [const InjectedKey(usageA, down: true)]);
      });
    });

    test('the pointer keeps moving when the wall clock goes back', () {
      fakeWallClock((async, jump) {
        final live = Live(async);
        for (var i = 0; i < 5; i++) {
          live.viewer.pointerMove(Offset(0.1 * i, 0.5));
          live.settle(const Duration(milliseconds: 16));
        }
        expect(live.events.whereType<InjectedMove>(), hasLength(5));

        // A time sync after wake sets the clock back an hour.
        jump(const Duration(hours: -1));
        for (var i = 0; i < 5; i++) {
          live.viewer.pointerMove(Offset(0.5, 0.1 * i));
          live.settle(const Duration(milliseconds: 16));
        }
        expect(live.events.whereType<InjectedMove>(), hasLength(10));
        expect(
          live.events.last,
          InjectedMove(landing(display, const Offset(0.5, 0.4))),
        );
      });
    });
  });

  group('display and window changes', () {
    test('a display resized or moved to negative coordinates maps at the '
        'next event, in the same epoch', () {
      fakeAsync((async) {
        final platform = FakeHostPlatform();
        final live = Live(async, platform: platform);
        live.viewer.pointerMove(const Offset(0.25, 0.75));
        live.settle();
        expect(
          live.events.last,
          InjectedMove(landing(display, const Offset(0.25, 0.75))),
        );

        // Rearranged left of and above a new primary, and at 2560 × 1440.
        const moved = Rect.fromLTWH(-2560, -1440, 2560, 1440);
        platform.surfaces.displayList = [
          const DisplayInfo(
            id: 1,
            bounds: moved,
            scaleFactor: 1,
            isPrimary: false,
          ),
          const DisplayInfo(
            id: 2,
            bounds: display,
            scaleFactor: 1,
            isPrimary: true,
          ),
        ];
        live.viewer.pointerButton(
          const Offset(0.1, 0.1),
          PointerButton.left,
          down: true,
        );
        live.viewer.pointerMove(const Offset(0.9, 0.9));
        live.settle();
        live.viewer.pointerButton(
          const Offset(0.9, 0.9),
          PointerButton.left,
          down: false,
        );
        live.settle();
        expect(live.events.skip(1), [
          InjectedButton(
            landing(moved, const Offset(0.1, 0.1)),
            PointerButton.left,
            down: true,
          ),
          InjectedMove(
            landing(moved, const Offset(0.9, 0.9)),
            heldButtons: {PointerButton.left},
          ),
          InjectedButton(
            landing(moved, const Offset(0.9, 0.9)),
            PointerButton.left,
            down: false,
          ),
        ]);
        // The same surface: no new epoch. The viewer lays out by the video's
        // frame size, which shows the change (design §3.3).
        expect(live.session.surfaceEpoch, 0);
        expect(live.viewer.surface!.epoch, 0);
        expect(live.dropped(DropReason.staleEpoch), 0);
      });
    });

    test('a removed display stops the session at the next pointer event, '
        'releasing held input', () {
      fakeAsync((async) {
        final platform = FakeHostPlatform();
        final live = Live(async, platform: platform);
        live.viewer
          ..key(
            HidModifier.shiftLeft,
            KeyAction.down,
            modifiers: KeyModifiers.shift,
          )
          ..pointerButton(
            const Offset(0.5, 0.5),
            PointerButton.left,
            down: true,
          );
        live.settle();
        live.injector.clear();
        platform.surfaces.displayList = [];
        live.viewer.pointerMove(const Offset(0.6, 0.6));
        live.settle();
        expect(
          live.session.state,
          const SessionStopped(StopReason.surfaceGone),
        );
        expect(live.events, [
          const InjectedKey(HidModifier.shiftLeft, down: false),
          InjectedButton(
            landing(display, const Offset(0.5, 0.5)),
            PointerButton.left,
            down: false,
          ),
        ]);
        expect(live.viewer.state, const SessionStopped(StopReason.surfaceGone));
      });
    });

    test('moving the session to another display: input in flight for the '
        'old one is dropped, then the viewer follows', () {
      fakeAsync((async) {
        const second = Rect.fromLTWH(1920, -300, 1280, 1024);
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
                bounds: second,
                scaleFactor: 1,
                isPrimary: false,
              ),
            ],
          ),
        );
        final live = Live(async, platform: platform);
        live.viewer.pointerMove(const Offset(0.5, 0.5));
        live.settle();
        live.injector.clear();

        // The viewer clicks before it hears of the change.
        live.session.changeSurface(const SharedSurface.display(2));
        live.viewer.click(const Offset(0.5, 0.5));
        live.viewer.pointerMove(const Offset(0.7, 0.7));
        live.settle();
        expect(live.events, isEmpty);
        expect(live.dropped(DropReason.staleEpoch), 3);
        expect(live.viewer.surface!.epoch, 1);
        expect(live.viewer.surface!.pixelSize, const Size(1280, 1024));

        live.viewer.click(const Offset(0.5, 0.5));
        live.settle();
        final p = landing(second, const Offset(0.5, 0.5));
        expect(live.events, [
          InjectedButton(p, PointerButton.left, down: true),
          InjectedButton(p, PointerButton.left, down: false),
        ]);
      });
    });

    test('a window moved, resized, minimized and restored', () {
      fakeAsync((async) {
        final platform = FakeHostPlatform();
        const first = Rect.fromLTWH(100, 100, 800, 600);
        const moved = Rect.fromLTWH(-900, 50, 1024, 768);
        const restored = Rect.fromLTWH(200, 200, 640, 480);
        platform.surfaces.windows[42] = SurfaceGeometry(
          bounds: first,
          pixelSize: first.size,
        );
        final live = Live(
          async,
          platform: platform,
          surface: const SharedSurface.window(42),
        );
        live.viewer.pointerMove(const Offset(0.5, 0.5));
        live.settle();
        expect(
          live.events.last,
          InjectedMove(landing(first, const Offset(0.5, 0.5))),
        );

        platform.surfaces.windows[42] = SurfaceGeometry(
          bounds: moved,
          pixelSize: moved.size,
        );
        live.viewer.pointerButton(
          const Offset(0.1, 0.1),
          PointerButton.left,
          down: true,
        );
        live.settle();
        final down = landing(moved, const Offset(0.1, 0.1));
        expect(
          live.events.last,
          InjectedButton(down, PointerButton.left, down: true),
        );

        // Minimized mid-drag: blocked, and the button is released.
        platform.surfaces.windows[42] = SurfaceGeometry(
          bounds: moved,
          pixelSize: moved.size,
          isHidden: true,
        );
        live.injector.clear();
        live.viewer.pointerMove(const Offset(0.2, 0.2));
        live.settle();
        expect(
          live.session.state,
          const SessionBlocked(BlockReason.surfaceHidden),
        );
        expect(live.events, [
          InjectedButton(down, PointerButton.left, down: false),
        ]);
        expect(
          live.viewer.state,
          const SessionBlocked(BlockReason.surfaceHidden),
        );
        expect(live.viewer.heldButtons, isEmpty);
        live.viewer.pointerMove(const Offset(0.3, 0.3));
        live.settle(const Duration(seconds: 5));
        expect(live.events, hasLength(1));

        // Restored elsewhere: active again within one poll.
        platform.surfaces.windows[42] = SurfaceGeometry(
          bounds: restored,
          pixelSize: restored.size,
        );
        live.settle(const Duration(milliseconds: 300));
        expect(live.session.state, const SessionActive());
        expect(live.viewer.state, const SessionActive());
        live.viewer.pointerMove(const Offset(0.5, 0.5));
        live.settle();
        expect(
          live.events.last,
          InjectedMove(landing(restored, const Offset(0.5, 0.5))),
        );
        expect(heldBy(live.events).buttons, isEmpty);
      });
    });
  });

  group('the shared window closing with input held', () {
    const bounds = Rect.fromLTWH(0, 0, 1000, 800);
    final triggers = <String, void Function(RemoteInputViewer)>{
      'a move': (v) => v.pointerMove(const Offset(0.9, 0.9)),
      'a key repeat': (v) =>
          v.key(usageA, KeyAction.repeat, modifiers: KeyModifiers.shift),
      'the button release': (v) => v.pointerButton(
        const Offset(0.9, 0.9),
        PointerButton.left,
        down: false,
      ),
      'a scroll': (v) => v.wheel(const Offset(0.5, 0.5), dy: 3),
      'text': (v) => v.text('x'),
    };
    for (final MapEntry(key: name, value: trigger) in triggers.entries) {
      test('stops at $name, and releases everything', () {
        fakeAsync((async) {
          final platform = FakeHostPlatform();
          platform.surfaces.windows[7] = SurfaceGeometry(
            bounds: bounds,
            pixelSize: bounds.size,
          );
          final live = Live(
            async,
            platform: platform,
            surface: const SharedSurface.window(7),
          );
          live.viewer
            ..key(
              HidModifier.shiftLeft,
              KeyAction.down,
              modifiers: KeyModifiers.shift,
            )
            ..key(usageA, KeyAction.down, modifiers: KeyModifiers.shift)
            ..pointerButton(
              const Offset(0.5, 0.5),
              PointerButton.left,
              down: true,
            );
          live.settle();
          expect(live.events, hasLength(3));
          live.injector.clear();

          platform.surfaces.windows.remove(7);
          trigger(live.viewer);
          live.settle();
          expect(
            live.session.state,
            const SessionStopped(StopReason.surfaceGone),
          );
          expect(live.events, [
            const InjectedKey(HidModifier.shiftLeft, down: false),
            const InjectedKey(usageA, down: false),
            InjectedButton(
              landing(bounds, const Offset(0.5, 0.5)),
              PointerButton.left,
              down: false,
            ),
          ]);
          expect(
            live.viewer.state,
            const SessionStopped(StopReason.surfaceGone),
          );
        });
      });
    }

    test('closed while minimized, it stops within one poll, unprompted', () {
      fakeAsync((async) {
        final platform = FakeHostPlatform();
        platform.surfaces.windows[7] = SurfaceGeometry(
          bounds: bounds,
          pixelSize: bounds.size,
        );
        final live = Live(
          async,
          platform: platform,
          surface: const SharedSurface.window(7),
        );
        live.viewer.key(usageA, KeyAction.down);
        live.settle();
        platform.surfaces.windows[7] = SurfaceGeometry(
          bounds: bounds,
          pixelSize: bounds.size,
          isHidden: true,
        );
        live.viewer.pointerMove(const Offset(0.5, 0.5));
        live.settle();
        expect(
          live.session.state,
          const SessionBlocked(BlockReason.surfaceHidden),
        );
        expect(heldBy(live.events).keys, isEmpty);
        platform.surfaces.windows.remove(7);
        live.settle(const Duration(milliseconds: 300));
        expect(
          live.session.state,
          const SessionStopped(StopReason.surfaceGone),
        );
      });
    });
  });

  test('an hour of pauses for local input: nothing held across a pause, '
      'nothing injected while paused, resumed after localIdle', () {
    fakeAsync((async) {
      late final Live live;
      var injectedWhilePaused = 0;
      final injector = RecordingInjector(
        onInject: (_) {
          if (live.session.state is SessionPaused) injectedWhilePaused++;
          return InjectResult.injected;
        },
      );
      live = Live(async, platform: FakeHostPlatform(injector: injector));
      final start = clock.now();
      int sinceStart() => clock.now().difference(start).inMilliseconds;

      final pausedAt = <int>[];
      final resumedAt = <int>[];
      final heldAtPause = <int>[];
      live.session.stateChanges.listen((s) {
        if (s is SessionPaused) {
          pausedAt.add(sinceStart());
          final held = heldBy(live.events);
          heldAtPause.add(held.keys.length + held.buttons.length);
        } else if (s is SessionActive && pausedAt.isNotEmpty) {
          resumedAt.add(sinceStart());
        }
      });

      // Every three minutes the person at the host uses their mouse for
      // about a second.
      final person = Person(live)
        ..beforeTick = (t) {
          if (const {90000, 90400, 90800}.contains(t % 180000)) {
            live.platform.localActivity.simulateInput();
          }
        };
      person.run(const Duration(hours: 1));
      live.settle(const Duration(seconds: 2));

      expect(pausedAt, hasLength(20));
      expect(resumedAt, hasLength(20));
      for (var i = 0; i < 20; i++) {
        expect(pausedAt[i], 90000 + i * 180000);
        expect(resumedAt[i], 90800 + 1500 + i * 180000);
      }
      expect(injectedWhilePaused, 0);
      expect(heldAtPause, everyElement(0));
      expect(live.viewerStates.whereType<SessionPaused>(), hasLength(20));

      // Input resumed after each pause: moves were injected after the last.
      expect(live.events.last, isA<InjectedMove>());
      final held = heldBy(live.events);
      expect(held.keys, isEmpty);
      expect(held.buttons, isEmpty);
      expect(live.session.state, const SessionActive());
      expect(live.viewer.state, const SessionActive());
      expect(live.session.stats.violations, isEmpty);
      expect(
        live.session.stats.dropped.keys,
        everyElement(
          isIn(const {
            DropReason.coalesced,
            DropReason.inactive,
            DropReason.notHeld,
          }),
        ),
      );
    });
  });
}
