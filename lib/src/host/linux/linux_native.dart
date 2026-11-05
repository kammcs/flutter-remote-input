// The Linux host's native calls, as an interface: implemented over dart:ffi
// in linux_ffi.dart (linux/remote_input_native.h), and by fakes in tests.
// No dart:ffi here.

import 'dart:ui' show Rect;

/// What a native post call returned (`RI_*` in `remote_input_native.h`).
abstract final class LinuxStatus {
  /// The event was posted.
  static const int ok = 0;

  /// Wayland: no portal session, or it has closed.
  static const int permissionDenied = 1;

  /// The event couldn't be posted.
  static const int failed = 2;

  /// Wayland: a character the keyboard layout can't type.
  static const int unmapped = 3;

  /// Wayland: the compositor paused the devices (the screen locked, say).
  static const int paused = 4;
}

/// Which session the host injects into.
enum LinuxBackend {
  /// Neither X11 nor Wayland.
  none,

  /// X11, through XTest.
  x11,

  /// Wayland, through the RemoteDesktop portal and libei.
  wayland,
}

/// The user's session, from logind.
enum LinuxSessionState {
  /// In front and unlocked.
  active,

  /// The screen is locked.
  locked,

  /// Another session is in front (user switching).
  inactive,

  /// logind couldn't be read: treated as active.
  unknown,
}

/// The local-activity monitor's reasons, in `RI_REASON_*` order.
enum LinuxActivityReason {
  /// A key from a physical keyboard.
  key,

  /// A button or wheel notch from a physical device.
  button,

  /// Physical pointer movement past 4 pixels of travel (X11).
  move,

  /// Wayland: the desktop's idle time reset with no post of the package's
  /// to explain it.
  idle,

  /// The monitor thread ran more than 200 ms late. Not local input.
  stall,
}

/// What `XWindow` says about an X11 window.
final class LinuxWindow {
  /// Creates a [LinuxWindow].
  const LinuxWindow({required this.bounds, required this.shown});

  /// Its client area in root-window pixels.
  final Rect bounds;

  /// Whether it's mapped and not minimized.
  final bool shown;
}

/// An X11 monitor, or a Wayland libei region.
final class LinuxDisplayRecord {
  /// Creates a [LinuxDisplayRecord].
  const LinuxDisplayRecord({
    required this.id,
    required this.bounds,
    this.scale = 1.0,
    this.isPrimary = false,
    this.mappingId = '',
  });

  /// X11: the monitor's name atom. Wayland: the region's id for this portal
  /// session (1, 2, ...).
  final int id;

  /// X11: root pixels. Wayland: the compositor's logical pixels; a window
  /// stream's region starts at 0, 0.
  final Rect bounds;

  /// The region's physical scale (Wayland), else 1.
  final double scale;

  /// Whether it's the primary monitor (X11).
  final bool isPrimary;

  /// Wayland: the ScreenCast stream's mapping id, or empty for a region of
  /// the whole desktop.
  final String mappingId;
}

/// The native calls the Linux host makes. All are synchronous.
abstract interface class LinuxNative {
  /// The session's backend.
  LinuxBackend get backend;

  /// Whether Wayland support was built in.
  bool get hasWayland;

  /// The effective user id.
  int get euid;

  /// This process's id.
  int get pid;

  /// The user's session state.
  LinuxSessionState sessionState();

  // --- X11 ---

  /// Opens the X connection: 0 ok, 1 no display, 2 no XTest, 3 no XInput 2.
  int x11Open();

  /// Moves the pointer to root pixel ([x], [y]).
  int x11Move(int x, int y);

  /// Presses or releases X button [button].
  int x11Button(int button, {required bool down});

  /// Presses or releases the key at evdev code [code].
  int x11Key(int code, {required bool down});

  /// Types code point [codepoint] through a spare keycode.
  int x11Text(int codepoint);

  /// Unbinds the spare keycodes [x11Text] bound.
  void x11TextRestore();

  /// The monitors.
  List<LinuxDisplayRecord> x11Monitors();

  /// Window [xid], or `null` if it's gone.
  LinuxWindow? x11Window(int xid);

  /// Whether root pixel ([x], [y]) shows window [xid] (its client's windows
  /// and dialogs): `null` if unknown.
  bool? x11OnWindow(int xid, int x, int y);

  /// Whether window [xid]'s client has focus: `null` if unknown.
  bool? x11HasFocus(int xid);

  /// Whether the topmost window at ([x], [y]) is this process's: `null` if
  /// unknown.
  bool? x11OwnWindowAt(int x, int y);

  /// Whether this process's window is active: `null` if unknown.
  bool? x11OwnAppInFront();

  // --- Wayland ---

  /// Whether a portal session is connected with its devices resumed.
  bool wlConnected();

  /// Whether the compositor paused a device the session needs.
  bool wlPaused();

  /// Grows each time the portal session, its devices or regions change.
  int wlGeneration();

  /// The absolute pointers' regions.
  List<LinuxDisplayRecord> wlRegions();

  /// Moves the pointer to ([x], [y]) in region [region] (0: the desktop).
  int wlMove(int region, double x, double y);

  /// Presses or releases evdev button [button].
  int wlButton(int button, {required bool down});

  /// Scrolls by ([dx], [dy]) logical pixels, or by 120ths of a notch when
  /// [discrete].
  int wlScroll(double dx, double dy, {required bool discrete});

  /// Presses or releases the key at evdev code [code].
  int wlKey(int code, {required bool down});

  /// Types code point [codepoint] with the compositor's keymap.
  int wlText(int codepoint);

  /// Whether one of this process's windows has focus: `null` if unknown.
  bool? wlOwnAppInFront();

  /// Whether the pointer is over one of this process's windows, as GTK last
  /// heard: `null` if unknown.
  bool? wlPointerOverOwnWindow();

  // --- The local-activity monitor ---

  /// Starts the monitor thread. Whether it's watching.
  bool activityStart();

  /// Stops it.
  void activityStop();

  /// Local input so far: a counter that only grows.
  int activityCount();

  /// Whether the thread's sources are healthy.
  bool activityHealthy();

  /// Milliseconds since the thread's loop last ran, or -1.
  int activityHeartbeatAgeMs();

  /// How many times [reason] was counted.
  int activityReason(LinuxActivityReason reason);

  /// The longest gap between two runs of the thread's loop, in ms.
  int activityLongestGapMs();

  /// Keyboards and pointing devices removed so far, or -1 if udev couldn't
  /// be read.
  int activityDevicesLost();
}
