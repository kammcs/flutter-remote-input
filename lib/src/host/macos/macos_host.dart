// The macOS HostPlatform (docs/design.md §7.3), over the MacosNative
// interface. No dart:ffi here: macos_platform.dart plugs in the FFI
// implementation, and tests plug in a fake.

import 'dart:async';
import 'dart:ui' show Offset;

import 'package:clock/clock.dart';

import '../../keys.dart';
import '../../protocol/wire_types.dart';
import '../../surface.dart';
import '../host_types.dart';
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
  /// [allowElevatedHost] has no effect: elevation is a Windows check.
  @override
  HostUnavailableReason? checkAvailable({bool allowElevatedHost = false}) =>
      _native.postAccess(fresh: true)
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

/// The pop-up menu window level (`kCGPopUpMenuWindowLevel`): open menus,
/// the menu bar's and status items' included.
const int macPopUpMenuWindowLevel = 101;

/// Whether the frontmost window at [point] in [windows] (on screen, front
/// to back) belongs to process [ownPid], so the viewer would operate the
/// host app itself: its consent dialog or its Stop button (review H1).
///
/// - **Levels 0–19** with alpha above 0, as [macosIsOccluded] counts them:
///   the frontmost one containing [point] decides.
/// - **Levels 20 and up: only the host's own windows count** (RIN-47).
///   Its open menus (pop-up menu level, 101: the menu bar's menus, its
///   status item's menu, context menus) and any other window it shows up
///   there are its own, unless AppKit says the window ignores mouse events
///   ([MacosWindowRecord.clickThrough]): a click-through border at
///   `.statusBar` over the shared surface must not block every click.
///   Other processes' windows at those levels are skipped as before: the
///   Dock, Notification Center, the menu bar and the cursor are
///   full-screen, mostly transparent windows above everything.
///
/// A click-through window of another app above the host's own window (one
/// that ignores mouse events but isn't transparent) hides it from this
/// check, because the window list can't tell which of another process's
/// windows take clicks.
bool macosIsOwnWindowAt(
  Offset point,
  List<MacosWindowRecord> windows,
  int ownPid,
) {
  for (final w in windows) {
    if (w.layer < 0 || w.alpha <= 0) continue;
    if (w.layer >= macDockWindowLevel) {
      if (w.ownerPid == ownPid && !w.clickThrough && w.bounds.contains(point)) {
        return true;
      }
      continue;
    }
    if (w.bounds.contains(point)) return w.ownerPid == ownPid;
  }
  return false;
}

/// Whether process [ownPid] has a menu open in [windows] (the on-screen
/// list): a window of its own at pop-up menu level or above, with alpha
/// above 0, that takes clicks (RIN-47). An open menu takes the keyboard
/// (arrows, Return, type-to-select) without its app being the frontmost
/// one, as a status item's menu does.
bool macosOwnMenuOpen(List<MacosWindowRecord> windows, int ownPid) {
  for (final w in windows) {
    if (w.ownerPid == ownPid &&
        w.layer >= macPopUpMenuWindowLevel &&
        w.alpha > 0 &&
        !w.clickThrough) {
      return true;
    }
  }
  return false;
}

/// Whether one of [panelPids] (apps whose non-activating panels take
/// keystrokes: Spotlight) shows a window in [windows], the on-screen list,
/// at any level, so keys typed now would go to that panel instead of the
/// frontmost app (review M4).
///
/// A panel's window level isn't checked: Spotlight's couldn't be read
/// without opening it, and it shows no other window. Its bounds aren't
/// either: keys go to the panel wherever it is.
bool macosKeyboardPanelOpen(
  List<MacosWindowRecord> windows,
  List<int> panelPids,
) {
  for (final w in windows) {
    if (w.alpha > 0 && panelPids.contains(w.ownerPid)) return true;
  }
  return false;
}

/// Displays and windows on macOS, in global display points.
///
/// Window bounds and the windows above a shared window are read with
/// `CGWindowListCopyWindowInfo` (about 0.13 ms for one window and 0.1 to
/// 0.3 ms for the windows above it, measured on macOS 27) and cached for
/// [windowCacheLifetime], so pointer moves at 250 Hz cost at most 20 reads
/// a second (open question 4). The whole on-screen list, for
/// [isOwnWindowAt], is cached the same way (0.3 to 0.6 ms a read). A button
/// press drops both caches first ([refreshWindows], RIN-56), so a window
/// that appeared within the cache's lifetime can't take a click. Displays
/// are cached until the display configuration changes, or for
/// [displayCacheLifetime].
final class MacosSurfaceResolver implements SurfaceResolver {
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

  Duration? _screenAt;
  List<MacosWindowRecord>? _screen;

  Duration? _panelsAt;
  List<int> _panelPids = const [];

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

  /// Whether [surface]'s window is on screen, its app is
  /// `NSWorkspace.frontmostApplication`, and no keyboard panel (Spotlight)
  /// is open: such a panel takes keystrokes without becoming the frontmost
  /// app (review M4, [macosKeyboardPanelOpen]).
  @override
  bool hasKeyboardFocus(SharedSurface surface) {
    if (surface is! WindowSurface) return true;
    final info = _windowInfo(surface.handle);
    return info != null &&
        info.onScreen &&
        _native.frontmostPid() == info.ownerPid &&
        !_keyboardPanelOpen();
  }

  bool _keyboardPanelOpen() {
    final at = _panelsAt;
    final List<int> pids;
    if (at != null && !_expired(at, windowCacheLifetime)) {
      pids = _panelPids;
    } else {
      _panelsAt = _watch.elapsed;
      pids = _panelPids = _native.keyboardPanelPids();
    }
    // Usually nothing to look for: Spotlight starts on demand.
    if (pids.isEmpty) return false;
    final windows = _onScreenWindows();
    if (windows == null) return true;
    return macosKeyboardPanelOpen(windows, pids);
  }

  /// Whether the window at [point] is this process's own
  /// ([macosIsOwnWindowAt]): the frontmost one among levels 0–19 with alpha
  /// above 0 (as for occlusion: [macosIsOccluded]), or one of its own
  /// windows at level 20 and up that takes clicks, such as an open menu
  /// (RIN-47). The on-screen window list is cached for
  /// [windowCacheLifetime], like a shared window's. If the list can't be
  /// read, the answer is true: the point might be on the host's own
  /// controls.
  @override
  bool isOwnWindowAt(Offset point) {
    final windows = _onScreenWindows();
    if (windows == null) return true;
    return macosIsOwnWindowAt(point, windows, _native.ownPid);
  }

  /// Whether keys typed now would go to this process: it's
  /// `NSWorkspace.frontmostApplication`, or one of its menus is open
  /// ([macosOwnMenuOpen], RIN-47), as a status item's menu is without its
  /// app in front. If the window list can't be read, the answer is true.
  @override
  bool isOwnAppInFront() {
    final own = _native.ownPid;
    if (_native.frontmostPid() == own) return true;
    final windows = _onScreenWindows();
    if (windows == null) return true;
    return macosOwnMenuOpen(windows, own);
  }

  /// Drops the cached window info and on-screen list (RIN-56): the session
  /// calls this before checking a button press, so a window that appeared
  /// over the shared one within [windowCacheLifetime] can't take the click.
  /// Moves keep the cache. The reads cost about 0.5 ms each (the window
  /// with the windows above it, and the on-screen list), so about 1 ms a
  /// press on a window share, measured on macOS 27. The keyboard-panel
  /// processes and the display list keep their caches.
  @override
  void refreshWindows() {
    _windowAt = null;
    _screenAt = null;
  }

  List<MacosWindowRecord>? _onScreenWindows() {
    final at = _screenAt;
    if (at != null && !_expired(at, windowCacheLifetime)) return _screen;
    _screenAt = _watch.elapsed;
    return _screen = _native.onScreenWindows();
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
///
/// **Health (RIN-45).** [isMonitoring] is true only while the counters are
/// polled and every input to them is sound, so a monitor that can't see
/// local input blocks injection rather than failing open:
/// - the device watch armed (RIN-41);
/// - the pointer's location could be read at the last poll;
/// - the HID counters are live: not all zero (a session that has seen no
///   input at all since boot reads all zeros only until the first one);
/// - they aren't frozen ([MacosCounterHealth]): the pointer didn't keep
///   moving, unexplained, while the HID move counter stayed flat.
///
/// When the monitor recovers from being unhealthy, it emits once, since
/// input in the gap may have gone unseen (as on Windows). A poll that's
/// only late doesn't make it unhealthy: under load that would block
/// sessions with nobody at the machine (RIN-39's lesson), and [checkNow]
/// covers keys, buttons and scrolls between polls.
///
/// **Lost devices (RIN-41).** Each poll also reads the native device
/// watch's count of keyboards and pointing devices removed (I/O Registry
/// notifications, no permission), and emits on [devicesLost] when it grew.
///
/// **Checked before each event (RIN-42).** [checkNow] reads the device
/// count and a snapshot, and counts a hardware key, modifier, button or
/// scroll since the last read. Movement is left to the poll, whose rules
/// need its timing ([MacosActivityDetector.checkDiscrete]).
final class MacosLocalActivity
    implements
        LocalActivityMonitor,
        LocalDeviceMonitor,
        LocalActivityCheck,
        LocalInputDiagnostics {
  /// Creates a monitor over [native], polling every [pollInterval] (10 ms,
  /// for a pause within the 100 ms target).
  MacosLocalActivity(
    this._native, {
    this.pollInterval = const Duration(milliseconds: 10),
    MacosActivityDetector? detector,
    MacosCounterHealth? health,
  }) : _detector = detector ?? MacosActivityDetector(),
       _health = health ?? MacosCounterHealth();

  final MacosNative _native;
  final MacosActivityDetector _detector;
  final MacosCounterHealth _health;

  /// How often the counters are read.
  final Duration pollInterval;

  late final StreamController<void> _controller = StreamController.broadcast(
    onListen: _start,
    onCancel: _stop,
  );
  final StreamController<void> _devices = StreamController.broadcast();
  Timer? _timer;
  Stopwatch? _watch;
  int _devicesLost = -1;
  bool _pointerReadable = false;
  bool _countersLive = false;
  bool _healthy = false;
  Duration? _lastPoll;

  // Diagnostics: counts only.
  int _monitorGaps = 0;
  int _unreadablePolls = 0;
  int _longestGapMs = 0;

  @override
  Stream<void> get activity => _controller.stream;

  /// Each poll that sees keyboards or pointing devices removed since the
  /// last one (RIN-41). Watched while [activity] has a listener.
  @override
  Stream<void> get devicesLost => _devices.stream;

  /// Whether the counters are being polled and were sound at the last poll
  /// (see the class comment). As of the last poll, so reading it costs
  /// nothing.
  @override
  bool get isMonitoring => _timer != null && _healthy;

  /// Tells the monitor the package put the pointer at [point].
  void noteInjectedPointer(Offset point) {
    _detector.noteInjectedPointer(point);
    _health.noteInjectedPointer(point);
  }

  void _start() {
    _detector.reset();
    _health.reset();
    _watch = clock.stopwatch()..start();
    _lastPoll = null;
    // A baseline: removals before monitoring started don't count.
    _devicesLost = _native.devicesLost();
    _poll(starting: true);
    _timer = Timer.periodic(pollInterval, (_) => _poll());
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _watch = null;
    _devicesLost = -1;
    _healthy = false;
    _detector.reset();
    _health.reset();
  }

  /// Reads the device count and the counters now (RIN-42). A removed device
  /// or a hardware key, modifier, button or scroll since the last read
  /// counts, and is consumed.
  @override
  bool checkNow() {
    if (!isMonitoring) return false;
    if (_readDevices()) return true;
    final watch = _watch;
    if (watch == null) return false;
    return _detector.checkDiscrete(_native.activitySnapshot(), watch.elapsed);
  }

  /// Reads the device watch's count, and emits on [devicesLost] if it grew.
  /// Returns whether it did.
  bool _readDevices() {
    final lost = _native.devicesLost();
    final deviceLost = lost >= 0 && _devicesLost >= 0 && lost != _devicesLost;
    _devicesLost = lost;
    if (deviceLost) _devices.add(null);
    return deviceLost;
  }

  void _poll({bool starting = false}) {
    final watch = _watch;
    if (watch == null) return;
    final now = watch.elapsed;
    final lastPoll = _lastPoll;
    if (lastPoll != null) {
      final gap = (now - lastPoll).inMilliseconds;
      if (gap > _longestGapMs) _longestGapMs = gap;
    }
    _lastPoll = now;

    _readDevices();
    final snapshot = _native.activitySnapshot();
    _pointerReadable = snapshot.pointerReadable;
    if (!_pointerReadable) _unreadablePolls++;
    final hid = snapshot.hid;
    _countersLive =
        _countersLive ||
        hid.keyDowns != 0 ||
        hid.flagsChanged != 0 ||
        hid.buttonDowns != 0 ||
        hid.scrolls != 0 ||
        hid.moves != 0;
    _health.update(snapshot, _native.displayGeneration(), now);

    final wasHealthy = _healthy;
    _healthy =
        _devicesLost >= 0 &&
        _pointerReadable &&
        _countersLive &&
        !_health.countersStale;
    if (!_healthy) {
      // Nothing is judged from an unsound snapshot; the detector takes a
      // new baseline when the monitor recovers.
      _detector.reset();
      return;
    }
    var local = _detector.update(snapshot, now);
    if (!wasHealthy && !starting) {
      // Back after a gap whose input may have gone unseen.
      _monitorGaps++;
      local = true;
    }
    if (local) _controller.add(null);
  }

  @override
  LocalInputCounts get localInputCounts => LocalInputCounts(
    counted: Map.unmodifiable({
      if (_monitorGaps > 0) LocalInputSource.monitorGap: _monitorGaps,
    }),
    stalls: 0,
    longestGapMs: _longestGapMs,
    details: Map.unmodifiable(
      {
        'staleCounterTrips': _health.trips,
        'unexplainedPointerMoves': _health.unexplainedMoves,
        'pointerUnreadablePolls': _unreadablePolls,
        'devicesLost': _devicesLost,
      }..removeWhere((_, v) => v <= 0),
    ),
  );
}
