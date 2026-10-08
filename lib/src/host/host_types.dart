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

/// What the host's local-input monitor counted as local input
/// (`docs/design.md` §6.3). Counted in `LocalInputCounts.counted`.
enum LocalInputSource {
  /// A key the package didn't inject.
  key,

  /// A mouse button or wheel notch the package didn't inject.
  button,

  /// A burst of pointer movement past the platform's threshold that the
  /// package didn't inject.
  move,

  /// A stall of the monitor during which the OS recorded input the monitor
  /// never saw.
  missed,

  /// The monitor coming back after its hooks were out, so input in the gap
  /// went unseen.
  monitorGap,
}

/// Why the host's local-input monitor reported local input, for
/// diagnostics: counts and timings only, never what was typed or where
/// (`docs/design.md` §6.6). Since the monitor's native code loaded, so
/// across sessions: compare two readings for one session.
final class LocalInputCounts {
  /// Creates a [LocalInputCounts].
  const LocalInputCounts({
    required this.counted,
    required this.stalls,
    required this.longestGapMs,
    this.details = const {},
  });

  /// Local input, by source. Sources with none are absent.
  final Map<LocalInputSource, int> counted;

  /// Stalls of the monitor's thread, whether or not they hid input. Only
  /// [LocalInputSource.missed] counts as local input.
  final int stalls;

  /// The longest gap between two heartbeats of the monitor's thread, in
  /// milliseconds (about 100 when it's never delayed).
  final int longestGapMs;

  /// Platform-specific counters for diagnosing what counted, by name. Not
  /// a stable API: names may change between versions. On Windows, mouse
  /// moves by origin (`injectedMove.ours`, `physicalMove.noTag`, ...: the
  /// injected flag, then the event's tag) and `largestUntaggedStepPx`, a
  /// distance. Counts and distances only, never positions.
  final Map<String, int> details;

  /// All local input.
  int get total => counted.values.fold(0, (a, b) => a + b);

  @override
  String toString() =>
      'LocalInputCounts(${[for (final e in counted.entries) '${e.key.name}: ${e.value}'].join(', ')}, '
      'stalls: $stalls, longestGapMs: $longestGapMs'
      '${[for (final e in details.entries) ', ${e.key}: ${e.value}'].join()})';
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
    this.localInput,
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

  /// What the local-input monitor counted, and why: for finding what
  /// paused a session with `PauseReason.localInput`. `null` where the
  /// platform's monitor doesn't break it down (macOS, for now).
  final LocalInputCounts? localInput;

  /// All dropped input.
  int get totalDropped => dropped.values.fold(0, (a, b) => a + b);

  /// All violations.
  int get totalViolations => violations.values.fold(0, (a, b) => a + b);
}
