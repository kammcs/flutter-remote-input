// The macOS host's native calls, as an interface: implemented over dart:ffi
// in macos_ffi.dart, and by fakes in tests. No dart:ffi here.

import 'dart:ui' show Offset, Rect;

import '../../surface.dart';

/// What a native post call returned (`RemoteInputStatus` in
/// `RemoteInputNative.swift`).
abstract final class MacosStatus {
  /// The event was posted.
  static const int ok = 0;

  /// The Accessibility permission is missing or was revoked.
  static const int permissionDenied = 1;

  /// The event couldn't be created.
  static const int failed = 2;
}

/// What `CGSessionCopyCurrentDictionary` says about the user's session.
abstract final class MacosSessionState {
  /// On the console and unlocked: input can be injected.
  static const int active = 0;

  /// Not on the console: fast user switching or the login window.
  static const int notOnConsole = 1;

  /// The screen is locked.
  static const int locked = 2;

  /// No window-server session at all.
  static const int none = 3;
}

/// A window above the shared one, from the window list.
final class MacosWindowRecord {
  /// Creates a [MacosWindowRecord].
  const MacosWindowRecord({
    required this.ownerPid,
    required this.layer,
    required this.alpha,
    required this.bounds,
  });

  /// The process that owns it (`kCGWindowOwnerPID`).
  final int ownerPid;

  /// Its window level (`kCGWindowLayer`): 0 for normal windows.
  final int layer;

  /// Its opacity (`kCGWindowAlpha`).
  final double alpha;

  /// Its bounds in global display points (`kCGWindowBounds`).
  final Rect bounds;
}

/// A window's bounds and the windows above it, from the window list.
final class MacosWindowInfo {
  /// Creates a [MacosWindowInfo].
  const MacosWindowInfo({
    required this.bounds,
    required this.onScreen,
    required this.ownerPid,
    required this.scale,
    this.above = const [],
  });

  /// Its bounds in global display points, including the title bar.
  final Rect bounds;

  /// Whether it's on screen (`kCGWindowIsOnscreen`): false when minimized,
  /// hidden, or on another Space.
  final bool onScreen;

  /// The process that owns it.
  final int ownerPid;

  /// The backing scale of the display under its centre.
  final double scale;

  /// The on-screen windows above it, front to back. Empty when it's off
  /// screen.
  final List<MacosWindowRecord> above;
}

/// Counts of input events by kind, as the local-activity monitor reads
/// them. Each count wraps at 2^32, like
/// `CGEventSourceCounterForEventType`.
final class MacosActivityCounts {
  /// Creates [MacosActivityCounts].
  const MacosActivityCounts({
    this.keyDowns = 0,
    this.flagsChanged = 0,
    this.buttonDowns = 0,
    this.scrolls = 0,
    this.moves = 0,
  });

  /// Key downs, not counting autorepeats.
  final int keyDowns;

  /// Modifier key presses and releases (`kCGEventFlagsChanged`).
  final int flagsChanged;

  /// Mouse button downs, any button.
  final int buttonDowns;

  /// Scroll-wheel events.
  final int scrolls;

  /// Pointer moves and drags.
  final int moves;
}

/// One poll of the local-activity monitor.
final class MacosActivitySnapshot {
  /// Creates a [MacosActivitySnapshot].
  const MacosActivitySnapshot({
    required this.hid,
    required this.own,
    required this.pointer,
  });

  /// The HID system's counts (`kCGEventSourceStateHIDSystemState`):
  /// hardware input.
  final MacosActivityCounts hid;

  /// The counts of events this package posted.
  final MacosActivityCounts own;

  /// Where the pointer is, in global display points.
  final Offset pointer;
}

/// The native calls the macOS host makes. All are synchronous.
abstract interface class MacosNative {
  /// Whether this process may post events. With [fresh], asks the OS now
  /// (about 12 ms); otherwise answers from a cache refreshed in the
  /// background every second.
  bool postAccess({required bool fresh});

  /// Posts a mouse event of `CGEventType` [type] at [point]. Returns a
  /// [MacosStatus].
  int postMouse(
    int type,
    Offset point, {
    required int button,
    required int clickState,
    required int flags,
  });

  /// Posts a scroll event at [point]. Returns a [MacosStatus].
  int postScroll(
    Offset point, {
    required int unit,
    required int wheel1,
    required int wheel2,
    required int flags,
  });

  /// Posts a key event for virtual key [keyCode]. Returns a [MacosStatus].
  int postKey(
    int keyCode, {
    required bool down,
    required bool autorepeat,
    required int flags,
  });

  /// Types up to 20 UTF-16 code [units] as one key down and up. Returns a
  /// [MacosStatus].
  int postText(List<int> units);

  /// Where the pointer is, or `null` if it can't be read.
  Offset? cursorLocation();

  /// The active displays.
  List<DisplayInfo> displays();

  /// Changes after each display reconfiguration (0 if not tracked).
  int displayGeneration();

  /// Window [windowId] and the windows above it, or `null` if it's gone.
  MacosWindowInfo? windowInfo(int windowId);

  /// The frontmost app's process id, or -1.
  int frontmostPid();

  /// Whether Secure Event Input is on.
  bool secureInput();

  /// The session's state, a [MacosSessionState].
  int sessionState();

  /// A snapshot for the local-activity monitor.
  MacosActivitySnapshot activitySnapshot();
}
