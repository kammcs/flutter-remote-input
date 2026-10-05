/// Values that travel on the wire, with their codes (`docs/design.md` §5).
///
/// Changing a code is a protocol change: the golden-byte tests pin them.
library;

/// The version of the wire protocol this package speaks
/// (`docs/design.md` §5). A host and a viewer agree on it in their
/// handshake.
const int remoteInputProtocolVersion = 1;

/// A mouse button, as the viewer pressed it.
enum PointerButton {
  /// The primary button.
  left(1),

  /// The secondary button.
  right(2),

  /// The middle button (or wheel click).
  middle(3),

  /// The "back" side button (X1 on Windows).
  back(4),

  /// The "forward" side button (X2 on Windows).
  forward(5);

  const PointerButton(this.code);

  /// The button's code on the wire.
  final int code;

  /// The button's bit in a `buttons` bitmask.
  int get mask => 1 << (code - 1);

  /// The button with [code], or `null` if there is none.
  static PointerButton? fromCode(int code) =>
      code >= 1 && code <= values.length ? values[code - 1] : null;

  /// The buttons set in [mask], in code order.
  static Set<PointerButton> fromMask(int mask) => {
    for (final b in values)
      if (mask & b.mask != 0) b,
  };

  /// The bitmask of [buttons].
  static int maskOf(Iterable<PointerButton> buttons) =>
      buttons.fold(0, (m, b) => m | b.mask);
}

/// What happened to a key.
enum KeyAction {
  /// Released.
  up(0),

  /// Pressed.
  down(1),

  /// Held long enough for the viewer's OS to repeat it.
  repeat(2);

  const KeyAction(this.code);

  /// The action's code on the wire.
  final int code;

  /// The action with [code], or `null` if there is none.
  static KeyAction? fromCode(int code) =>
      code >= 0 && code < values.length ? values[code] : null;
}

/// The unit of a wheel delta.
enum WheelUnit {
  /// Pixels (logical pixels on the viewer): trackpads and smooth scrolling.
  pixel(0),

  /// Lines, as a notched mouse wheel scrolls.
  line(1);

  const WheelUnit(this.code);

  /// The unit's code on the wire.
  final int code;

  /// The unit with [code], or `null` if there is none.
  static WheelUnit? fromCode(int code) =>
      code >= 0 && code < values.length ? values[code] : null;
}

/// The operating system at one end of a session, as the handshake reports
/// it.
///
/// A viewer in a browser reports the OS the browser runs on, because that
/// decides its keyboard's shortcuts; the handshake's `web` capability bit
/// says it's a browser.
enum PeerPlatform {
  /// Not known (or a code from a newer version).
  unknown(0),

  /// Windows.
  windows(1),

  /// macOS.
  macos(2),

  /// Linux.
  linux(3),

  /// iOS or iPadOS.
  ios(4),

  /// Android.
  android(5),

  /// Fuchsia.
  fuchsia(6);

  const PeerPlatform(this.code);

  /// The platform's code on the wire.
  final int code;

  /// Whether the platform's shortcuts use Command rather than Control.
  bool get isApple => this == macos || this == ios;

  /// The platform with [code]; [unknown] for codes this version doesn't
  /// know.
  static PeerPlatform fromCode(int code) =>
      code >= 0 && code < values.length ? values[code] : unknown;
}

/// Why a session is paused: injection is suspended, and resumes by itself or
/// when the app says so.
enum PauseReason {
  /// The person at the host touched their own mouse or keyboard
  /// (`docs/design.md` §6.3).
  localInput(1),

  /// The host app called `ControlSession.pause`.
  byHost(2),

  /// A reason this version doesn't know, from a newer host.
  other(255);

  const PauseReason(this.code);

  /// The reason's code on the wire.
  final int code;

  /// The reason with [code]; [other] for codes this version doesn't know.
  static PauseReason fromCode(int code) =>
      values.firstWhere((r) => r.code == code, orElse: () => other);
}

/// Why a session is blocked: the OS can't or shouldn't take the input now
/// (`docs/design.md` §6.5). It resumes when the condition clears.
enum BlockReason {
  /// The target belongs to a process at a higher integrity level (Windows
  /// UIPI: an app run as administrator, Task Manager).
  elevatedTarget(1),

  /// The secure desktop is showing (Windows: UAC, Ctrl+Alt+Del, the lock
  /// screen).
  secureDesktop(2),

  /// Secure Event Input is on (macOS: a password field has focus). Blocks
  /// keys only; the pointer continues.
  secureInput(3),

  /// The user's session isn't active (macOS: the login window, the lock
  /// screen, fast user switching).
  sessionInactive(4),

  /// The shared window is minimized or hidden.
  surfaceHidden(5),

  /// The shared window isn't in front, so keys would go to another window.
  /// Blocks keys only; the pointer continues.
  windowNotInFront(6),

  /// Local input can't be detected right now (Windows: the input hooks
  /// aren't installed), so nothing is injected until it can.
  localInputUnmonitored(7),

  /// The host app itself is in front, so keys would go to its own windows
  /// (its consent dialog, its Stop button). Blocks keys only.
  hostAppInFront(8),

  /// A reason this version doesn't know, from a newer host.
  other(255);

  const BlockReason(this.code);

  /// The reason's code on the wire.
  final int code;

  /// Whether this blocks pointer input as well as keys.
  bool get blocksPointer =>
      this != secureInput && this != windowNotInFront && this != hostAppInFront;

  /// The reason with [code]; [other] for codes this version doesn't know.
  static BlockReason fromCode(int code) =>
      values.firstWhere((r) => r.code == code, orElse: () => other);
}

/// Why a session stopped. A stopped session is over; control needs a new
/// one.
enum StopReason {
  /// The host app called `ControlSession.stop`.
  byHost(1),

  /// The host app called `RemoteInputHost.stopAll`.
  stopAll(2),

  /// The link closed.
  linkClosed(3),

  /// `HostOptions.expiresAt` passed.
  expired(4),

  /// The shared surface went away (its window closed, its display was
  /// removed, or the app closed it).
  surfaceGone(5),

  /// Too many malformed, replayed or misdirected messages
  /// (`docs/design.md` §6.4).
  protocolViolation(6),

  /// More input than the limits allow, for longer than the queue holds.
  flooding(7),

  /// The viewer said goodbye.
  viewerLeft(8),

  /// The OS permission to inject is missing or was revoked (macOS
  /// Accessibility).
  permissionDenied(9),

  /// The viewer's app closed its `RemoteInputViewer` (viewer side only).
  viewerClosed(10),

  /// The two ends share no protocol version.
  unsupportedVersion(11),

  /// The host said goodbye without a reason (viewer side only).
  hostLeft(12),

  /// Nothing arrived from the host for `ViewerOptions.hostTimeout` (viewer
  /// side only): it crashed, slept, or lost its network.
  timedOut(13),

  /// A reason this version doesn't know, from a newer host.
  other(255);

  const StopReason(this.code);

  /// The reason's code on the wire.
  final int code;

  /// The reason with [code]; [other] for codes this version doesn't know.
  static StopReason fromCode(int code) =>
      values.firstWhere((r) => r.code == code, orElse: () => other);
}

/// Logical modifier bits, as a `Key` message carries the viewer's modifier
/// state (`docs/design.md` §5.4). Combine with `|`.
abstract final class KeyModifiers {
  /// No modifier.
  static const int none = 0;

  /// Shift (either side).
  static const int shift = 1 << 0;

  /// Control (either side).
  static const int control = 1 << 1;

  /// Alt, or Option on Apple keyboards (either side).
  static const int alt = 1 << 2;

  /// Meta: Command on Apple keyboards, the Windows key elsewhere (either
  /// side).
  static const int meta = 1 << 3;

  /// Not a modifier but a flag: the host applies no modifier mapping
  /// (`ModifierMapping`) to this key, so a Mac viewer can send the Windows
  /// key itself. Hosts that don't know it ignore it.
  static const int unmapped = 1 << 15;
}

/// Capability bits in the handshake (`HostHello.capabilities`,
/// `Hello.capabilities`). None are defined for hosts in v1.
abstract final class ViewerCapabilities {
  /// The viewer runs in a web browser.
  static const int web = 1 << 0;
}
