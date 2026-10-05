// The macOS HostPlatform (docs/design.md §7.3), over the MacosNative
// interface. No dart:ffi here: macos_platform.dart plugs in the FFI
// implementation, and tests plug in a fake.

import 'dart:async';
import 'dart:ui' show Offset;

import 'package:clock/clock.dart';

import '../../keys.dart';
import '../../protocol/wire_types.dart';
import '../../surface.dart';
import '../platform.dart';
import 'macos_activity.dart';
import 'macos_events.dart';
import 'macos_native.dart';

/// The macOS [HostPlatform]: `CGEventPost` from a private event source,
/// Core Graphics geometry, and the Secure Event Input, session and
/// local-activity checks.
final class MacosHostPlatform implements HostPlatform {
  /// Creates the platform over [native].
  MacosHostPlatform(this._native) {
    localActivity = MacosLocalActivity(_native);
    injector = MacosInputInjector(
      _native,
      onPointer: localActivity.noteInjectedPointer,
    );
    surfaces = MacosSurfaceResolver(_native);
    secureContext = MacosSecureContext(_native);
  }

  final MacosNative _native;

  @override
  PeerPlatform get platform => PeerPlatform.macos;

  /// [HostUnavailableReason.permissionDenied] without the Accessibility
  /// permission. Asks the OS each time, which takes about 12 ms.
  @override
  HostUnavailableReason? checkAvailable() => _native.postAccess(fresh: true)
      ? null
      : HostUnavailableReason.permissionDenied;

  @override
  late final MacosInputInjector injector;

  @override
  late final MacosSurfaceResolver surfaces;

  @override
  late final MacosLocalActivity localActivity;

  @override
  late final MacosSecureContext secureContext;
}

/// The result of a native post call.
InjectResult macosInjectResult(int status) => switch (status) {
  MacosStatus.ok => InjectResult.injected,
  MacosStatus.permissionDenied => InjectResult.permissionDenied,
  _ => InjectResult.failed,
};

/// Posts input with `CGEventPost` at the HID tap, from the package's
/// private event source, tagged in `kCGEventSourceUserData`.
///
/// Every event carries modifier flags computed from the modifier keys this
/// injector holds, never the local user's (open question 10).
final class MacosInputInjector implements InputInjector {
  /// Creates an injector over [native]. [onPointer] hears each point the
  /// pointer is put at, for the local-activity monitor.
  MacosInputInjector(this._native, {this.onPointer});

  final MacosNative _native;

  /// Hears each point the injector puts the pointer at.
  final void Function(Offset point)? onPointer;
  final Set<int> _heldModifiers = {};
  final Set<PointerButton> _heldButtons = {};

  /// How far, in points, the pointer may be from a scroll's point before
  /// it's moved there first: scroll events go to the window under the
  /// pointer.
  static const double scrollMoveTolerance = 0.5;

  int get _flags => macModifierFlags(_heldModifiers);

  @override
  InjectResult movePointer(
    Offset point, {
    required Set<PointerButton> heldButtons,
  }) {
    final move = macMoveEvent(heldButtons);
    final r = macosInjectResult(
      _native.postMouse(
        move.type,
        point,
        button: move.button,
        clickState: 0,
        flags: _flags,
      ),
    );
    if (r == InjectResult.injected) onPointer?.call(point);
    return r;
  }

  @override
  InjectResult pointerButton(
    Offset point,
    PointerButton button, {
    required bool down,
    required int clickCount,
  }) {
    final r = macosInjectResult(
      _native.postMouse(
        macButtonEventType(button, down: down),
        point,
        button: macButtonNumber(button),
        clickState: clickCount < 1 ? 1 : clickCount,
        flags: _flags,
      ),
    );
    if (down) {
      if (r == InjectResult.injected) _heldButtons.add(button);
    } else {
      _heldButtons.remove(button);
    }
    if (r == InjectResult.injected) onPointer?.call(point);
    return r;
  }

  @override
  InjectResult wheel(
    Offset point, {
    required int dx,
    required int dy,
    required WheelUnit unit,
  }) {
    final at = _native.cursorLocation();
    if (at == null || (at - point).distance > scrollMoveTolerance) {
      final moved = movePointer(point, heldButtons: _heldButtons);
      if (moved != InjectResult.injected) return moved;
    }
    final wheels = macWheels(dx: dx, dy: dy);
    return macosInjectResult(
      _native.postScroll(
        point,
        unit: macScrollUnit(unit),
        wheel1: wheels.wheel1,
        wheel2: wheels.wheel2,
        flags: _flags,
      ),
    );
  }

  @override
  InjectResult key(int usage, {required bool down, bool repeat = false}) {
    final keyCode = macKeyCode(usage);
    if (keyCode == null) return InjectResult.unmappedKey;
    final isModifier = HidModifier.isModifier(usage);
    // Modifier keys don't repeat on a Mac keyboard.
    if (isModifier && down && repeat) return InjectResult.injected;
    // A modifier's own event carries the flags as they are after it, as a
    // keyboard's flagsChanged event does.
    final after = {..._heldModifiers};
    if (isModifier) down ? after.add(usage) : after.remove(usage);
    final r = macosInjectResult(
      _native.postKey(
        keyCode,
        down: down,
        autorepeat: repeat && down,
        flags: macModifierFlags(after),
      ),
    );
    if (isModifier && (r == InjectResult.injected || !down)) {
      _heldModifiers
        ..clear()
        ..addAll(after);
    }
    return r;
  }

  @override
  InjectResult text(String text) {
    for (final chunk in macTextChunks(text)) {
      final r = macosInjectResult(_native.postText(chunk));
      if (r != InjectResult.injected) return r;
    }
    return InjectResult.injected;
  }
}

/// Window levels from the Dock's up (`kCGDockWindowLevel`): the Dock,
/// Notification Center, the menu bar, status items, pop-up menus, overlays
/// and the cursor.
const int macDockWindowLevel = 20;

/// Whether [point] on [window] is covered by another window, so input there
/// would land on that window instead (`docs/design.md` §6.4).
///
/// Open question 5. A window above counts only if:
/// - **another process owns it.** Menus, pop-ups, sheets and dialogs of the
///   shared window's own app count as the shared window, so its menus work.
///   (So do the app's other windows.)
/// - **its level is below the Dock's** (0–19: normal windows, floating
///   panels, torn-off menus, modal panels). The Dock and Notification
///   Center keep full-screen, mostly transparent windows above everything,
///   and the menu bar and cursor are windows too; the window list doesn't
///   say which of their pixels take clicks, so counting them would block
///   every point. The cost: clicks on the Dock or a notification banner
///   over the shared window aren't caught.
/// - **it isn't fully transparent** (alpha above 0).
bool macosIsOccluded(Offset point, MacosWindowInfo window) {
  for (final other in window.above) {
    if (other.ownerPid == window.ownerPid) continue;
    if (other.layer < 0 || other.layer >= macDockWindowLevel) continue;
    if (other.alpha <= 0) continue;
    if (other.bounds.contains(point)) return true;
  }
  return false;
}

/// Displays and windows on macOS, in global display points.
///
/// Window bounds and the windows above a shared window are read with
/// `CGWindowListCopyWindowInfo` (about 0.13 ms for one window and 0.1 to
/// 0.3 ms for the windows above it, measured on macOS 27) and cached for
/// [windowCacheLifetime], so pointer moves at 250 Hz cost at most 20 reads
/// a second (open question 4). Displays are cached until the display
/// configuration changes, or for [displayCacheLifetime].
final class MacosSurfaceResolver implements SurfaceResolver {
  // TODO(review H1): own-process checks; stubs until the macOS fix lands.
  @override
  bool isOwnWindowAt(Offset point) => false;

  @override
  bool isOwnAppInFront() => false;

  /// Creates a resolver over [native].
  MacosSurfaceResolver(
    this._native, {
    this.windowCacheLifetime = const Duration(milliseconds: 50),
    this.displayCacheLifetime = const Duration(seconds: 1),
  });

  final MacosNative _native;

  /// How long a window's bounds and occluders are reused.
  final Duration windowCacheLifetime;

  /// How long the display list is reused when the configuration doesn't
  /// change.
  final Duration displayCacheLifetime;

  final Stopwatch _watch = clock.stopwatch()..start();

  int? _windowId;
  Duration? _windowAt;
  MacosWindowInfo? _window;

  List<DisplayInfo>? _displays;
  Duration? _displaysAt;
  int? _displaysGeneration;

  @override
  Future<List<DisplayInfo>> displays() async =>
      List.unmodifiable(_readDisplays());

  @override
  SurfaceGeometry? resolve(SharedSurface surface) => switch (surface) {
    DisplaySurface(:final displayId) => _displayGeometry(displayId),
    WindowSurface(:final handle) => _windowGeometry(handle),
    RectSurface s =>
      s.isClosed
          ? null
          : SurfaceGeometry(bounds: s.bounds, pixelSize: s.pixelSize),
  };

  @override
  bool isOnSurface(SharedSurface surface, Offset point) {
    if (surface is! WindowSurface) return true;
    final info = _windowInfo(surface.handle);
    return info != null && info.onScreen && !macosIsOccluded(point, info);
  }

  @override
  bool hasKeyboardFocus(SharedSurface surface) {
    if (surface is! WindowSurface) return true;
    final info = _windowInfo(surface.handle);
    return info != null &&
        info.onScreen &&
        _native.frontmostPid() == info.ownerPid;
  }

  SurfaceGeometry? _displayGeometry(int id) {
    final generation = _native.displayGeneration();
    final at = _displaysAt;
    final cached = _displays;
    final List<DisplayInfo> list;
    if (cached == null ||
        at == null ||
        generation != _displaysGeneration ||
        _expired(at, displayCacheLifetime)) {
      list = _readDisplays();
    } else {
      list = cached;
    }
    for (final d in list) {
      if (d.id == id) {
        return SurfaceGeometry(bounds: d.bounds, pixelSize: d.pixelSize);
      }
    }
    return null;
  }

  List<DisplayInfo> _readDisplays() {
    _displaysGeneration = _native.displayGeneration();
    _displaysAt = _watch.elapsed;
    return _displays = _native.displays();
  }

  SurfaceGeometry? _windowGeometry(int handle) {
    final info = _windowInfo(handle);
    if (info == null) return null;
    return SurfaceGeometry(
      bounds: info.bounds,
      pixelSize: info.bounds.size * info.scale,
      isHidden: !info.onScreen,
    );
  }

  MacosWindowInfo? _windowInfo(int handle) {
    if (handle < 0 || handle > 0xFFFFFFFF) return null;
    final at = _windowAt;
    if (_windowId == handle &&
        at != null &&
        !_expired(at, windowCacheLifetime)) {
      return _window;
    }
    _windowId = handle;
    _windowAt = _watch.elapsed;
    return _window = _native.windowInfo(handle);
  }

  bool _expired(Duration at, Duration lifetime) {
    final age = _watch.elapsed - at;
    return age < Duration.zero || age >= lifetime;
  }
}

/// Secure Event Input and an inactive session (`docs/design.md` §6.5).
///
/// `IsSecureEventInputEnabled()` is read on every check (it's nearly free);
/// the session dictionary costs about 0.12 ms and is cached for
/// [sessionCacheLifetime].
final class MacosSecureContext implements SecureContextProbe {
  /// Creates a probe over [native].
  MacosSecureContext(
    this._native, {
    this.sessionCacheLifetime = const Duration(milliseconds: 100),
  });

  final MacosNative _native;

  /// How long the session state is reused.
  final Duration sessionCacheLifetime;

  final Stopwatch _watch = clock.stopwatch()..start();
  Duration? _sessionAt;
  bool _sessionInactive = false;

  @override
  BlockReason? check(InputKind kind, {Offset? point}) {
    if (_isSessionInactive()) return BlockReason.sessionInactive;
    if (kind == InputKind.keyboard && _native.secureInput()) {
      return BlockReason.secureInput;
    }
    return null;
  }

  bool _isSessionInactive() {
    final at = _sessionAt;
    final now = _watch.elapsed;
    if (at == null ||
        now - at >= sessionCacheLifetime ||
        now - at < Duration.zero) {
      _sessionAt = now;
      _sessionInactive = _native.sessionState() != MacosSessionState.active;
    }
    return _sessionInactive;
  }
}

/// Local input on macOS, by polling the HID system's event counters while
/// [activity] has a listener (`docs/design.md` §6.3; see
/// [MacosActivityDetector]).
final class MacosLocalActivity implements LocalActivityMonitor {
  // The HID counters are always readable.
  @override
  bool get isMonitoring => true;

  /// Creates a monitor over [native], polling every [pollInterval] (10 ms,
  /// for a pause within the 100 ms target).
  MacosLocalActivity(
    this._native, {
    this.pollInterval = const Duration(milliseconds: 10),
    MacosActivityDetector? detector,
  }) : _detector = detector ?? MacosActivityDetector();

  final MacosNative _native;
  final MacosActivityDetector _detector;

  /// How often the counters are read.
  final Duration pollInterval;

  late final StreamController<void> _controller = StreamController.broadcast(
    onListen: _start,
    onCancel: _stop,
  );
  Timer? _timer;
  Stopwatch? _watch;

  @override
  Stream<void> get activity => _controller.stream;

  /// Tells the monitor the package put the pointer at [point].
  void noteInjectedPointer(Offset point) =>
      _detector.noteInjectedPointer(point);

  void _start() {
    _detector.reset();
    _watch = clock.stopwatch()..start();
    _poll();
    _timer = Timer.periodic(pollInterval, (_) => _poll());
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _watch = null;
    _detector.reset();
  }

  void _poll() {
    final watch = _watch;
    if (watch == null) return;
    if (_detector.update(_native.activitySnapshot(), watch.elapsed)) {
      _controller.add(null);
    }
  }
}
