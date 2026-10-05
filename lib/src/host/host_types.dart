/// A key press, as a `KeyFilter` sees it.
final class KeyPress {
  /// Creates a [KeyPress].
  const KeyPress({required this.usage, required this.heldModifiers});

  /// The key's USB HID usage (`page << 16 | id`), after modifier mapping.
  final int usage;

  /// The HID usages of the modifier keys the session holds (left and right
  /// Control, Shift, Alt and Meta: `0x700E0`–`0x700E7`), after mapping.
  final Set<int> heldModifiers;
}

/// Why the host dropped an input message instead of injecting it. Counted
/// in `SessionStats.dropped`.
enum DropReason {
  /// Input before the handshake finished.
  notReady,

  /// The session was paused, blocked or stopped.
  inactive,

  /// A pointer move older than a pointer event already applied.
  staleMove,

  /// Aimed at an earlier surface.
  staleEpoch,

  /// A move replaced by a newer one before it was injected.
  coalesced,

  /// A move whose held buttons disagree with the host's, because the
  /// button event it follows hasn't arrived yet.
  inconsistentMove,

  /// On a window surface, the point is on another window.
  occluded,

  /// On a window surface, the window isn't in front for keys.
  notFocused,

  /// Keyboard input while `HostOptions.allowKeyboard` is false.
  keyboardDisabled,

  /// The app's `KeyFilter` dropped it.
  filtered,

  /// More keys held than `InputLimits.maxHeldKeys`.
  tooManyKeys,

  /// A release or repeat of a key or button the session doesn't hold, or a
  /// press of one it already holds.
  notHeld,

  /// A key with no mapping on this platform.
  unmapped,

  /// Over the host app's own windows, or keys while it's in front
  /// (`HostOptions.protectHostWindows`).
  hostWindow,

  /// The OS refused it, or the surface's bounds were unusable.
  failed,
}

/// Messages counted as protocol violations (`docs/design.md` §6.4). More
/// than 50 in 10 seconds stop the session.
enum ViolationKind {
  /// Longer than `InputLimits.maxMessageBytes`.
  oversized,

  /// Couldn't be decoded.
  malformed,

  /// A session tag or nonce that isn't this session's.
  wrongSession,

  /// A reliable message whose sequence number isn't after the last one.
  replayed,

  /// On the wrong channel (anything but a move on the unreliable one).
  wrongChannel,

  /// A message only a host sends.
  wrongDirection,
}

/// A session's counters. Counts and timings only: never what was typed or
/// where (`docs/design.md` §6.6).
final class SessionStats {
  /// Creates a [SessionStats].
  const SessionStats({
    required this.received,
    required this.injected,
    required this.ignored,
    required this.dropped,
    required this.violations,
  });

  /// Messages received from the viewer.
  final int received;

  /// OS events posted (a text message posts one per chunk).
  final int injected;

  /// Unknown extension messages ignored.
  final int ignored;

  /// Dropped input, by reason. Reasons with no drops are absent.
  final Map<DropReason, int> dropped;

  /// Violations, by kind. Kinds with none are absent.
  final Map<ViolationKind, int> violations;

  /// All dropped input.
  int get totalDropped => dropped.values.fold(0, (a, b) => a + b);

  /// All violations.
  int get totalViolations => violations.values.fold(0, (a, b) => a + b);
}
