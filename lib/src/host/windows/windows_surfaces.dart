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
///   window when `WindowFromPoint`'s root window ([isSharedWindow]) is the
///   shared window, is owned by it (its dialogs, and their popups), or is a
///   menu, tooltip or popup of the shared window's own thread. Matching is
///   by window ownership, not process, so sharing one File Explorer window
///   doesn't admit the taskbar, the desktop or another Explorer window, and
///   sharing one browser window doesn't admit the browser's other windows.
///   Keys go to it while the foreground window passes the same test.
/// - **The host app's own windows** ([isOwnWindowAt], [isOwnAppInFront]):
///   the root window under the point, or the foreground window, belongs to
///   this process.
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

  /// The most owners [isSharedWindow] follows from a window: owner chains
  /// are short (a dialog of a dialog), and this bounds a malformed one.
  static const int maxOwnerDepth = 16;

  @override
  bool isOnSurface(SharedSurface surface, Offset point) {
    if (surface is! WindowSurface) return true;
    return isSharedWindow(_windowAt(point), surface.handle);
  }

  @override
  bool hasKeyboardFocus(SharedSurface surface) {
    if (surface is! WindowSurface) return true;
    return isSharedWindow(_api.foregroundWindow(), surface.handle);
  }

  @override
  bool isOwnWindowAt(Offset point) => _isOwn(_windowAt(point));

  @override
  bool isOwnAppInFront() => _isOwn(_api.foregroundWindow());

  int _windowAt(Offset point) =>
      _api.windowFromPoint(desktopPixel(point.dx), desktopPixel(point.dy));

  /// Whether [hwnd]'s root window belongs to this process.
  bool _isOwn(int hwnd) {
    if (hwnd == 0) return false;
    final pid = _api.processIdOfWindow(_topLevel(hwnd));
    return pid != 0 && pid == _api.currentProcessId;
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

  /// Whether input to window [hwnd] (the window under a point, or the
  /// foreground window) goes to the shared window [shared]. Its root
  /// window must be:
  ///
  /// 1. the shared window (or, if [shared] is a child, its root window);
  /// 2. owned by it, directly or through other owned windows
  ///    (`GW_OWNER`): its dialogs, and their popups and tooltips;
  /// 3. or, if it has no owner, a menu (class `#32768`), or a `WS_POPUP`
  ///    tool window without a taskbar button (`WS_EX_TOOLWINDOW` and not
  ///    `WS_EX_APPWINDOW`), created by the shared window's own thread:
  ///    menus, tooltips and drop-downs that aren't owned.
  ///
  /// Anything else is another window, even of the same process: another
  /// Explorer window, the taskbar or the desktop when an Explorer window is
  /// shared, or the browser's other windows. A window owned by some other
  /// window isn't matched by thread. Ownership can cross processes, so a
  /// window another process opened for the shared one, owned by it,
  /// counts.
  bool isSharedWindow(int hwnd, int shared) {
    if (hwnd == 0 || shared == 0) return false;
    if (hwnd == shared) return true;
    final target = _topLevel(shared);
    final root = _topLevel(hwnd);
    if (root == target) return true;
    var owner = _api.ownerWindow(root);
    if (owner != 0) {
      for (var i = 0; owner != 0 && i < maxOwnerDepth; i++) {
        if (owner == target) return true;
        owner = _api.ownerWindow(owner);
      }
      return false;
    }
    final thread = _api.threadIdOfWindow(root);
    if (thread == 0 || thread != _api.threadIdOfWindow(target)) return false;
    if (_api.windowClassName(root) == WindowStyle.menuClass) return true;
    if (_api.windowStyle(root) & WindowStyle.popup == 0) return false;
    final ex = _api.windowExStyle(root);
    return ex & WindowStyle.exToolWindow != 0 &&
        ex & WindowStyle.exAppWindow == 0;
  }

  /// [hwnd]'s root window (`GA_ROOT`), or [hwnd] where it has none.
  int _topLevel(int hwnd) {
    final root = _api.rootWindow(hwnd);
    return root == 0 ? hwnd : root;
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
