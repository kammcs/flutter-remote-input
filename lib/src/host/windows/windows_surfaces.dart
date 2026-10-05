import 'dart:ui' show Offset, Rect;

import '../../surface.dart';
import '../platform.dart';
import 'input_records.dart' show desktopPixel;
import 'win32_api.dart';

/// The Windows [SurfaceResolver] (`docs/design.md` §3.2, §6.4).
///
/// - **Displays:** `EnumDisplayMonitors` and `GetMonitorInfoW`, in physical
///   pixels of the virtual screen, so `scaleFactor` is 1. A display's id is
///   the number in its device name (`\\.\DISPLAY2` is 2), which normally
///   stays the same for a monitor while the app runs, through other
///   monitors being added or removed; [fallbackDisplayIdBase] plus the index where a name
///   has no number. Its bounds are read again with `GetMonitorInfoW` for
///   every event, so a resolution change takes effect at once.
/// - **Windows:** `DWMWA_EXTENDED_FRAME_BOUNDS` for every event (the frame
///   as drawn, without the invisible resize borders), and hidden while
///   minimized, invisible or cloaked (on another virtual desktop).
/// - **Occlusion and focus** (open question 5): a point is on the shared
///   window when `WindowFromPoint`'s root window is the shared window, or
///   belongs to the same process: its menus, popups, tooltips and dialogs
///   count as the shared window, since they're part of the app the viewer
///   was given. Keys go to it while the foreground window passes the same
///   test.
final class WindowsSurfaceResolver implements SurfaceResolver {
  /// Creates a resolver on [api].
  WindowsSurfaceResolver(this._api);

  final Win32Api _api;

  /// Display id to the monitor last seen with it.
  final Map<int, WinMonitor> _displays = {};

  /// Display ids for monitors whose device name has no number start here.
  static const int fallbackDisplayIdBase = 0x10000;

  @override
  Future<List<DisplayInfo>> displays() async => [
    for (final (id, m) in _enumerate())
      DisplayInfo(
        id: id,
        bounds: _rect(m.bounds),
        scaleFactor: 1,
        isPrimary: m.isPrimary,
      ),
  ];

  @override
  SurfaceGeometry? resolve(SharedSurface surface) => switch (surface) {
    DisplaySurface(:final displayId) => _display(displayId),
    WindowSurface(:final handle) => _window(handle),
    RectSurface s =>
      s.isClosed
          ? null
          : SurfaceGeometry(bounds: s.bounds, pixelSize: s.pixelSize),
  };

  @override
  bool isOnSurface(SharedSurface surface, Offset point) {
    if (surface is! WindowSurface) return true;
    final hit = _api.windowFromPoint(
      desktopPixel(point.dx),
      desktopPixel(point.dy),
    );
    return _belongsTo(hit, surface.handle);
  }

  @override
  bool hasKeyboardFocus(SharedSurface surface) {
    if (surface is! WindowSurface) return true;
    return _belongsTo(_api.foregroundWindow(), surface.handle);
  }

  // --- Displays -------------------------------------------------------------

  List<(int, WinMonitor)> _enumerate() {
    final monitors = _api.monitors();
    _displays.clear();
    final out = <(int, WinMonitor)>[];
    for (var i = 0; i < monitors.length; i++) {
      final m = monitors[i];
      final id = displayIdOf(m.deviceName) ?? fallbackDisplayIdBase + i;
      _displays[id] = m;
      out.add((id, m));
    }
    return out;
  }

  SurfaceGeometry? _display(int id) {
    final known = _displays[id];
    var m = known == null ? null : _api.monitor(known.handle);
    if (m == null || m.deviceName != known!.deviceName) {
      // Unknown, or the configuration changed: enumerate again.
      m = null;
      for (final (i, found) in _enumerate()) {
        if (i == id) m = found;
      }
      if (m == null) return null;
    }
    _displays[id] = m;
    final bounds = _rect(m.bounds);
    return SurfaceGeometry(bounds: bounds, pixelSize: bounds.size);
  }

  // --- Windows --------------------------------------------------------------

  SurfaceGeometry? _window(int hwnd) {
    if (hwnd == 0 || !_api.isWindow(hwnd)) return null;
    final b = _api.windowBounds(hwnd);
    final hidden =
        b == null ||
        _api.isIconic(hwnd) ||
        !_api.isWindowVisible(hwnd) ||
        _api.isCloaked(hwnd);
    final bounds = b == null ? Rect.zero : _rect(b);
    return SurfaceGeometry(
      bounds: bounds,
      pixelSize: bounds.size,
      isHidden: hidden,
    );
  }

  /// Whether [hwnd] is the shared window [shared], one of its children, or
  /// a window of the same process.
  bool _belongsTo(int hwnd, int shared) {
    if (hwnd == 0) return false;
    if (hwnd == shared) return true;
    final root = _api.rootWindow(hwnd);
    final sharedRoot = _api.rootWindow(shared);
    if (root != 0 && root == (sharedRoot == 0 ? shared : sharedRoot)) {
      return true;
    }
    final pid = _api.processIdOfWindow(root == 0 ? hwnd : root);
    return pid != 0 && pid == _api.processIdOfWindow(shared);
  }
}

/// The display number in a monitor's device name (`\\.\DISPLAY2` is 2), or
/// `null` if it has none.
int? displayIdOf(String deviceName) {
  final match = RegExp(r'DISPLAY(\d+)$').firstMatch(deviceName.toUpperCase());
  final n = match == null ? null : int.tryParse(match.group(1)!);
  return n == null ||
          n <= 0 ||
          n >= WindowsSurfaceResolver.fallbackDisplayIdBase
      ? null
      : n;
}

Rect _rect(WinRect r) => Rect.fromLTRB(
  r.left.toDouble(),
  r.top.toDouble(),
  r.right.toDouble(),
  r.bottom.toDouble(),
);
