// Local input on macOS (docs/design.md §6.3, open question 2): pure logic
// over polled snapshots, so it's unit-tested on any OS.
//
// The monitor polls the HID system's event counters
// (`CGEventSourceCounterForEventType(kCGEventSourceStateHIDSystemState, …)`)
// about every 10 ms. A key down, a modifier change, a button down or a
// scroll counted since the last poll is local input. Moves count only once
// the pointer is more than a threshold away from where it last was, or
// from where the package last put it, to ignore sensor jitter.
//
// Why the HID state: `CGEventSource.h` says that table "reflects the
// combined state of all hardware event sources posting from the HID
// system", while the package posts from its own private-state source, whose
// "independent state table" tracks only its own events. So the package's
// events are expected not to appear in the HID counts, and no Input
// Monitoring permission is needed. That's verified on a device by
// example/integration_test/macos_injection_test.dart; if it turns out
// wrong, [MacosActivityDetector.ownEventsReachHidState] subtracts the
// package's own events instead.

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
  /// movement before small movements stop adding up. With
  /// [ownEventsReachHidState], the package's own posted events are
  /// subtracted from the HID counts, each for up to [ownEventWindow].
  MacosActivityDetector({
    this.moveThreshold = 4,
    this.anchorReset = const Duration(milliseconds: 250),
    this.ownEventsReachHidState = false,
    this.ownEventWindow = const Duration(milliseconds: 250),
  });

  /// How far the pointer must move, in points, to count as local input.
  final double moveThreshold;

  /// How long without local pointer movement before the reference point
  /// follows the pointer, so jitter spread over time doesn't add up.
  final Duration anchorReset;

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

    final keysOrButtons = local[0] + local[1] + local[2] + local[3];
    if (keysOrButtons > 0) {
      _anchor = snapshot.pointer;
      return true;
    }
    if (local[4] > 0) {
      // Measured from the anchor: where the pointer was before this burst
      // of movement (set below while it was still), or where the package
      // last put it. Small moves add up until they pass the threshold.
      _lastLocalMove = now;
      final anchor = _anchor ??= snapshot.pointer;
      if ((snapshot.pointer - anchor).distance > moveThreshold) {
        _anchor = snapshot.pointer;
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
