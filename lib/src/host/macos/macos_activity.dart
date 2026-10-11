// Local input on macOS (docs/design.md §6.3, open question 2): pure logic
// over polled snapshots, so it's unit-tested on any OS.
//
// The monitor polls the HID system's event counters
// (`CGEventSourceCounterForEventType(kCGEventSourceStateHIDSystemState, …)`)
// about every 10 ms. A key down, a modifier change, a button down or a
// scroll counted since the last poll is local input. Pointer movement
// counts in either of two ways:
//
// - **Sustained hardware moves** (review M2): at least
//   [MacosActivityDetector.minMoveEvents] HID moves within
//   [MacosActivityDetector.moveWindow], seen in at least two polls,
//   wherever the pointer is. The package's own moves aren't in the HID
//   counts, so this works while a viewer streams moves at 250 Hz, which
//   keep putting the pointer back where the viewer wants it.
// - **Distance:** the pointer is more than a threshold from where it last
//   was, or from where the package last put it. This catches slow movement
//   that reports too few events for the first rule, while the viewer isn't
//   moving the pointer.
//
// Why the HID state: `CGEventSource.h` says that table "reflects the
// combined state of all hardware event sources posting from the HID
// system", while the package posts from its own private-state source, whose
// "independent state table" tracks only its own events. So the package's
// events are expected not to appear in the HID counts, and no Input
// Monitoring permission is needed. That's verified on a device by
// example/integration_test/macos_injection_test.dart; if it turns out
// wrong, [MacosActivityDetector.ownEventsReachHidState] subtracts the
// package's own events instead, for both movement rules.

import 'dart:collection';
import 'dart:ui' show Offset;

import 'macos_native.dart';

/// Decides, poll by poll, whether the person at the Mac used their own
/// keyboard or mouse.
final class MacosActivityDetector {
  /// Creates a detector.
  ///
  /// [moveThreshold] is how far, in points, the pointer must move to count
  /// (`docs/design.md` §6.3: 4). [anchorReset] is how long without local
  /// movement before small movements stop adding up. [minMoveEvents]
  /// hardware moves within [moveWindow] count as local movement wherever
  /// the pointer is. With [ownEventsReachHidState], the package's own
  /// posted events are subtracted from the HID counts, each for up to
  /// [ownEventWindow].
  MacosActivityDetector({
    this.moveThreshold = 4,
    this.anchorReset = const Duration(milliseconds: 250),
    this.minMoveEvents = 3,
    this.moveWindow = const Duration(milliseconds: 100),
    this.ownEventsReachHidState = false,
    this.ownEventWindow = const Duration(milliseconds: 250),
  });

  /// How far the pointer must move, in points, to count as local input.
  final double moveThreshold;

  /// How long without local pointer movement before the reference point
  /// follows the pointer, so jitter spread over time doesn't add up.
  final Duration anchorReset;

  /// How many hardware pointer moves within [moveWindow], seen in at least
  /// two polls, count as local movement wherever the pointer is.
  ///
  /// A mouse reports at 125 to 1000 Hz while it moves, and a trackpad at
  /// about 60 to 120 Hz, so a deliberate movement reaches 3 within about
  /// 25 ms (a 125 Hz mouse) to 50 ms (a slow trackpad), inside the 100 ms
  /// target. A single report from a bumped desk or a resting hand doesn't,
  /// and requiring two polls ignores a short burst from a 1000 Hz mouse
  /// that lands in one poll.
  final int minMoveEvents;

  /// The window [minMoveEvents] are counted in.
  final Duration moveWindow;

  /// Whether events the package posts appear in the HID system's counts.
  /// Expected false (see the file comment); true subtracts them.
  final bool ownEventsReachHidState;

  /// How long one of the package's own events may take to appear in the
  /// HID counts, when [ownEventsReachHidState] is true.
  final Duration ownEventWindow;

  MacosActivitySnapshot? _last;
  Offset? _anchor;
  Offset? _injectedPoint;
  Duration? _lastLocalMove;
  final ListQueue<(Duration, int)> _recentMoves = ListQueue();
  final List<ListQueue<(Duration, int)>> _pending = List.generate(
    5,
    (_) => ListQueue(),
  );

  /// Tells the detector the package put the pointer at [point] (a move,
  /// a button or the move before a scroll), so that isn't local movement.
  void noteInjectedPointer(Offset point) => _injectedPoint = point;

  /// Forgets the previous snapshot, for when monitoring stops.
  void reset() {
    _last = null;
    _anchor = null;
    _injectedPoint = null;
    _lastLocalMove = null;
    _recentMoves.clear();
    for (final q in _pending) {
      q.clear();
    }
  }

  /// Takes the snapshot polled at [now] and returns whether there was local
  /// input since the previous one. The first snapshot only sets the
  /// baseline.
  bool update(MacosActivitySnapshot snapshot, Duration now) {
    final last = _last;
    _last = snapshot;
    if (last == null) {
      _anchor = snapshot.pointer;
      _injectedPoint = null;
      return false;
    }
    final hid = _deltas(snapshot.hid, last.hid);
    final own = _deltas(snapshot.own, last.own);
    final local = List<int>.filled(5, 0);
    for (var i = 0; i < 5; i++) {
      local[i] = ownEventsReachHidState
          ? _subtractOwn(i, hid[i], own[i], now)
          : hid[i];
    }

    final injected = _injectedPoint;
    if (injected != null) {
      _anchor = injected;
      _injectedPoint = null;
    }

    final moves = local[4];
    final sustained = _noteMoves(moves, now);

    final keysOrButtons = local[0] + local[1] + local[2] + local[3];
    if (keysOrButtons > 0 || sustained) {
      _anchor = snapshot.pointer;
      if (moves > 0) _lastLocalMove = now;
      _recentMoves.clear();
      return true;
    }
    if (moves > 0) {
      // Measured from the anchor: where the pointer was before this burst
      // of movement (set below while it was still), or where the package
      // last put it. Small moves add up until they pass the threshold.
      _lastLocalMove = now;
      final anchor = _anchor ??= snapshot.pointer;
      if ((snapshot.pointer - anchor).distance > moveThreshold) {
        _anchor = snapshot.pointer;
        _recentMoves.clear();
        return true;
      }
      return false;
    }
    final lastMove = _lastLocalMove;
    if (lastMove == null || now - lastMove > anchorReset) {
      _anchor = snapshot.pointer;
    }
    return false;
  }

  /// Whether [snapshot], read between polls, shows a hardware key down, a
  /// modifier change, a button down or a scroll since the last snapshot
  /// (RIN-42). Those are local input on their own, so they're checked
  /// before every injected event. If there is one, it's consumed: those
  /// counts in the baseline move on, and the movement state is kept, so
  /// movement is still judged by [update] at the poll's cadence. False
  /// before the first snapshot, and with [ownEventsReachHidState], whose
  /// subtraction needs the poll's timing.
  bool checkDiscrete(MacosActivitySnapshot snapshot) {
    final last = _last;
    if (last == null || ownEventsReachHidState) return false;
    final hid = _deltas(snapshot.hid, last.hid);
    if (hid[0] + hid[1] + hid[2] + hid[3] == 0) return false;
    MacosActivityCounts keepMoves(MacosActivityCounts now, int moves) =>
        MacosActivityCounts(
          keyDowns: now.keyDowns,
          flagsChanged: now.flagsChanged,
          buttonDowns: now.buttonDowns,
          scrolls: now.scrolls,
          moves: moves,
        );
    _last = MacosActivitySnapshot(
      hid: keepMoves(snapshot.hid, last.hid.moves),
      own: keepMoves(snapshot.own, last.own.moves),
      pointer: last.pointer,
    );
    return true;
  }

  /// Records [moves] hardware moves seen at [now], and returns whether the
  /// moves within [moveWindow] are sustained movement.
  bool _noteMoves(int moves, Duration now) {
    if (moves > 0) _recentMoves.add((now, moves));
    while (_recentMoves.isNotEmpty &&
        now - _recentMoves.first.$1 > moveWindow) {
      _recentMoves.removeFirst();
    }
    if (_recentMoves.length < 2) return false;
    var total = 0;
    for (final (_, count) in _recentMoves) {
      total += count;
    }
    return total >= minMoveEvents;
  }

  int _subtractOwn(int kind, int hid, int own, Duration now) {
    final queue = _pending[kind];
    if (own > 0) queue.add((now, own));
    while (queue.isNotEmpty && now - queue.first.$1 > ownEventWindow) {
      queue.removeFirst();
    }
    var remaining = hid;
    while (remaining > 0 && queue.isNotEmpty) {
      final (at, count) = queue.removeFirst();
      if (count > remaining) {
        queue.addFirst((at, count - remaining));
        remaining = 0;
      } else {
        remaining -= count;
      }
    }
    return remaining;
  }

  static List<int> _deltas(MacosActivityCounts a, MacosActivityCounts b) => [
    _wrap(a.keyDowns - b.keyDowns),
    _wrap(a.flagsChanged - b.flagsChanged),
    _wrap(a.buttonDowns - b.buttonDowns),
    _wrap(a.scrolls - b.scrolls),
    _wrap(a.moves - b.moves),
  ];

  static int _wrap(int delta) => delta & 0xFFFFFFFF;
}

/// Whether the HID system's counters still see the hardware (RIN-45,
/// `docs/design.md` §6.3): pure logic over polled snapshots, so it's
/// unit-tested on any OS.
///
/// Local input wins on macOS rests on those counters
/// ([MacosActivityDetector]). If they stopped moving for physical input (a
/// macOS change, the App Sandbox, a session state never seen), the monitor
/// would see nothing and fail open, silently. Counters that read zero are
/// easy to spot; counters that are non-zero but frozen are the real
/// failure. So each poll compares two things that should agree: where the
/// pointer is, and the HID move counter.
///
/// **The rule.** The pointer moved more than [jumpThreshold] points since
/// the last poll, the HID move counter didn't advance, and nothing
/// explains it. Explained are:
/// - **the package's own posts:** its own event counters advanced since the
///   last poll, or the pointer is within [injectedSlack] of where the
///   package last put it (a post the counters showed a poll earlier). The
///   package's events never reach the HID counters, so without this every
///   viewer move would look like a frozen counter;
/// - **a display reconfiguration:** the display generation changed within
///   [reconfigurationGrace], which may move the pointer onto a display that
///   remains.
///
/// One such sample could be a race (an event counted after the counters
/// were read, but before the pointer was), so it takes [strikes] of them
/// within [window], with no HID movement between. Then [countersStale] is
/// true until the counter advances again, which takes a physical move.
///
/// **False positives, accepted (fail closed):** other software that moves
/// the pointer without HID events (another remote-control tool, an app
/// that warps it) looks the same; the session is then blocked until the
/// presenter moves their own mouse.
final class MacosCounterHealth {
  /// Creates a health check.
  MacosCounterHealth({
    this.jumpThreshold = 4,
    this.injectedSlack = 2,
    this.strikes = 2,
    this.window = const Duration(seconds: 1),
    this.reconfigurationGrace = const Duration(milliseconds: 500),
  });

  /// How far, in points, the pointer must move between two polls to need
  /// explaining.
  final double jumpThreshold;

  /// How close, in points, the pointer must be to where the package last
  /// put it for that to explain it.
  final double injectedSlack;

  /// How many unexplained moves within [window] make the counters stale.
  final int strikes;

  /// The window [strikes] are counted in.
  final Duration window;

  /// How long after a display reconfiguration a pointer jump is explained.
  final Duration reconfigurationGrace;

  MacosActivitySnapshot? _last;
  Offset? _injectedPoint;
  int? _generation;
  Duration? _reconfiguredAt;
  final ListQueue<Duration> _unexplained = ListQueue();
  bool _stale = false;
  int _trips = 0;
  int _unexplainedMoves = 0;

  /// Whether the HID counters look frozen: [strikes] unexplained pointer
  /// moves, and no HID move since.
  bool get countersStale => _stale;

  /// How many times the counters were judged stale, for diagnostics.
  int get trips => _trips;

  /// Pointer moves seen without HID moves or an explanation, for
  /// diagnostics.
  int get unexplainedMoves => _unexplainedMoves;

  /// Tells the check the package put the pointer at [point].
  void noteInjectedPointer(Offset point) => _injectedPoint = point;

  /// Forgets the previous snapshot and any strikes, for when monitoring
  /// stops or the pointer couldn't be read. A stale verdict stays until a
  /// HID move clears it.
  void reset() {
    _last = null;
    _generation = null;
    _reconfiguredAt = null;
    _unexplained.clear();
  }

  /// Takes the snapshot polled at [now], with the display configuration's
  /// [generation] read in the same poll. Returns whether this poll cleared
  /// a stale verdict.
  bool update(MacosActivitySnapshot snapshot, int generation, Duration now) {
    if (!snapshot.pointerReadable) {
      reset();
      return false;
    }
    final last = _last;
    final lastGeneration = _generation;
    _last = snapshot;
    _generation = generation;
    if (lastGeneration != null && generation != lastGeneration) {
      _reconfiguredAt = now;
    }
    if (last == null) return false;

    if (_wrap(snapshot.hid.moves - last.hid.moves) > 0) {
      // The counters see the hardware.
      _unexplained.clear();
      if (_stale) {
        _stale = false;
        return true;
      }
      return false;
    }
    if ((snapshot.pointer - last.pointer).distance <= jumpThreshold) {
      return false;
    }
    if (_explained(snapshot, last, now)) return false;
    _unexplainedMoves++;
    _unexplained.add(now);
    while (_unexplained.isNotEmpty && now - _unexplained.first > window) {
      _unexplained.removeFirst();
    }
    if (!_stale && _unexplained.length >= strikes) {
      _stale = true;
      _trips++;
    }
    return false;
  }

  bool _explained(
    MacosActivitySnapshot snapshot,
    MacosActivitySnapshot last,
    Duration now,
  ) {
    final own = snapshot.own;
    final before = last.own;
    final posted =
        _wrap(own.moves - before.moves) +
        _wrap(own.buttonDowns - before.buttonDowns) +
        _wrap(own.scrolls - before.scrolls);
    if (posted > 0) return true;
    final injected = _injectedPoint;
    if (injected != null &&
        (snapshot.pointer - injected).distance <= injectedSlack) {
      return true;
    }
    final reconfigured = _reconfiguredAt;
    return reconfigured != null && now - reconfigured <= reconfigurationGrace;
  }

  static int _wrap(int delta) => delta & 0xFFFFFFFF;
}
