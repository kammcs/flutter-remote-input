import 'dart:ui' show Offset;

import '../protocol/wire_types.dart';
import '../surface.dart';
import 'host_types.dart' show LocalInputCounts;

/// The OS services a host needs, one implementation per platform
/// (`docs/design.md` §7.1).
///
/// The package provides them on Windows and macOS. Tests use the fakes in
/// `testing.dart`; another package could implement them for a platform this
/// one doesn't support.
abstract interface class HostPlatform {
  /// The host's OS, as the handshake reports it.
  PeerPlatform get platform;

  /// Why the host can't inject now, or `null` if it can. Checked when a
  /// session is enabled.
  HostUnavailableReason? checkAvailable();

  /// Posts OS input events.
  InputInjector get injector;

  /// Displays, window bounds, occlusion and focus.
  SurfaceResolver get surfaces;

  /// Physical input this package didn't inject, or `null` where it can't be
  /// detected yet. Without it, local input doesn't pause a session.
  LocalActivityMonitor? get localActivity;

  /// Elevated and secure contexts, or `null` where they can't be detected
  /// yet.
  SecureContextProbe? get secureContext;
}

/// Why a host can't inject.
enum HostUnavailableReason {
  /// This platform has no injector (web, phones, Linux:
  /// `docs/design.md` §2.2).
  unsupportedPlatform,

  /// The OS permission to post input is missing (macOS Accessibility).
  permissionDenied,

  /// The process isn't per-monitor DPI aware (Windows), so its coordinates
  /// would be virtualized.
  dpiUnaware,
}

/// Thrown by `RemoteInputHost` when the host can't inject.
final class HostUnavailableException implements Exception {
  /// Creates a [HostUnavailableException].
  const HostUnavailableException(this.reason);

  /// Why.
  final HostUnavailableReason reason;

  @override
  String toString() => 'HostUnavailableException(${reason.name})';
}

/// What an [InputInjector] call did.
enum InjectResult {
  /// The OS took the event.
  injected,

  /// The OS refused it because the target is elevated (Windows UIPI).
  elevatedTarget,

  /// The OS refused it because the permission is missing or was revoked.
  permissionDenied,

  /// The key has no mapping on this platform; nothing was posted.
  unmappedKey,

  /// The OS refused it for another reason.
  failed,
}

/// Posts OS input events at desktop coordinates ([SharedSurface]).
///
/// Calls are synchronous: the session checks its stop flag immediately
/// before each one (`docs/design.md` §6.2). Implementations tag the events
/// they post, so a [LocalActivityMonitor] can tell them apart.
abstract interface class InputInjector {
  /// Moves the pointer to [point]. [heldButtons] are the buttons the session
  /// holds, so a platform that distinguishes drags (macOS) can post one.
  InjectResult movePointer(
    Offset point, {
    required Set<PointerButton> heldButtons,
  });

  /// Presses or releases [button] at [point]. [clickCount] is 2 for the
  /// second press of a double click.
  InjectResult pointerButton(
    Offset point,
    PointerButton button, {
    required bool down,
    required int clickCount,
  });

  /// Scrolls at [point]. Deltas are already clamped to the session's limits.
  InjectResult wheel(
    Offset point, {
    required int dx,
    required int dy,
    required WheelUnit unit,
  });

  /// Presses, repeats or releases the key at USB HID [usage]
  /// (`page << 16 | id`).
  InjectResult key(int usage, {required bool down, bool repeat = false});

  /// Types [text] by Unicode, whatever the keyboard layout.
  InjectResult text(String text);
}

/// Reports physical input at the host that the package didn't inject
/// (`docs/design.md` §6.3).
abstract interface class LocalActivityMonitor {
  /// An event for each burst of local input: a key, a button, or pointer
  /// movement past the platform's threshold. Monitoring runs while the
  /// stream has a listener.
  Stream<void> get activity;

  /// Whether local input is being detected right now (the Windows hooks are
  /// installed and alive). Read before every injected event, so it must be
  /// cheap. While it's false, the session blocks with
  /// `BlockReason.localInputUnmonitored`: no injection without local-input
  /// detection (`docs/design.md` §6.3).
  bool get isMonitoring;
}

/// A [LocalActivityMonitor] that can say why it reported local input. A
/// separate interface, so monitors without it still implement
/// [LocalActivityMonitor] alone.
abstract interface class LocalInputDiagnostics {
  /// The counts so far. Cheap: read on demand, never polled.
  LocalInputCounts get localInputCounts;
}

/// The kind of input a check is for.
enum InputKind {
  /// Pointer moves, buttons and the wheel.
  pointer,

  /// Keys and text.
  keyboard,
}

/// Detects contexts the package must not inject into
/// (`docs/design.md` §6.5).
abstract interface class SecureContextProbe {
  /// Why [kind] input can't be injected now, or `null` if it can. [point]
  /// is where a pointer event would land, for checks that depend on the
  /// window under it.
  BlockReason? check(InputKind kind, {Offset? point});
}

/// Displays, window bounds, occlusion and focus, in desktop coordinates.
abstract interface class SurfaceResolver {
  /// The host's displays.
  Future<List<DisplayInfo>> displays();

  /// Where [surface] is now, or `null` if it's gone. Called before every
  /// pointer event, so it must be quick (cached where the OS call isn't).
  /// Never called for a [RectSurface].
  SurfaceGeometry? resolve(SharedSurface surface);

  /// Whether [point] is on [surface], rather than on another window over
  /// it. Always true for displays and [RectSurface]s.
  bool isOnSurface(SharedSurface surface, Offset point);

  /// Whether keys typed now go to [surface]: its window is in front. Always
  /// true for displays and [RectSurface]s.
  bool hasKeyboardFocus(SharedSurface surface);

  /// Whether the window under [point] belongs to the host app's own
  /// process, so a viewer can't click its consent dialog or Stop button
  /// (`HostOptions.protectHostWindows`).
  bool isOwnWindowAt(Offset point);

  /// Whether the host app's own process is in front, so keys typed now would
  /// go to it.
  bool isOwnAppInFront();
}
