// The Linux HostPlatform (docs/design.md §7.5), over the LinuxNative
// interface: XTest on X11, the RemoteDesktop portal with libei on Wayland. No
// dart:ffi here: linux_platform.dart plugs in the FFI implementation, and
// tests plug in a fake.

import 'dart:async';
import 'dart:ui' show Offset, Rect, Size;

import 'package:clock/clock.dart';

import '../../keys/key_tables.g.dart';
import '../../protocol/wire_types.dart';
import '../../surface.dart';
import '../platform.dart';
import 'linux_activity.dart';
import 'linux_native.dart';

/// The Linux [HostPlatform].
///
/// The backend follows the session: Wayland when the desktop is a Wayland
/// one (even if the app itself runs under XWayland, whose XTest reaches
/// only XWayland windows), X11 otherwise.
final class LinuxHostPlatform implements HostPlatform, HostRevocation {
  /// Creates the platform over [native]. [revoked] hears each end of a
  /// Wayland portal session (`RemoteInputPortal.closed`);
  /// [contentSizeOf] gives a window stream's content size
  /// (`RemoteInputPortal.updateContentSize`).
  LinuxHostPlatform(
    this._native, {
    Stream<void>? revoked,
    Size? Function(int displayId)? contentSizeOf,
  }) : backend = _native.backend,
       _revoked = revoked ?? const Stream.empty() {
    final target = LinuxPointerTarget();
    _target = target;
    if (backend == LinuxBackend.wayland) {
      injector = LinuxWaylandInjector(_native, target);
      surfaces = LinuxWaylandSurfaceResolver(
        _native,
        target,
        contentSizeOf: contentSizeOf,
      );
    } else {
      injector = LinuxX11Injector(_native);
      surfaces = LinuxX11SurfaceResolver(_native);
    }
    localActivity = LinuxLocalActivity(_native);
    secureContext = LinuxSecureContext(_native, backend);
  }

  final LinuxNative _native;
  final Stream<void> _revoked;
  late final LinuxPointerTarget _target;

  /// The session's backend.
  final LinuxBackend backend;

  @override
  PeerPlatform get platform => PeerPlatform.linux;

  @override
  Stream<void> get revoked => _revoked;

  /// In order:
  /// - [HostUnavailableReason.unsupportedPlatform] without an X11 or
  ///   Wayland session, when X11 has no XTest or XInput 2, or when Wayland
  ///   support wasn't built in;
  /// - on Wayland, [HostUnavailableReason.waylandNotAllowed] without
  ///   [allowWayland], then [HostUnavailableReason.permissionDenied] while
  ///   no portal session is open (`RemoteInputPortal.start`);
  /// - [HostUnavailableReason.elevatedHost] when running as root, unless
  ///   [allowElevatedHost].
  @override
  HostUnavailableReason? checkAvailable({
    bool allowElevatedHost = false,
    bool allowWayland = false,
  }) {
    _target.region = 0;
    switch (backend) {
      case LinuxBackend.none:
        return HostUnavailableReason.unsupportedPlatform;
      case LinuxBackend.x11:
        if (_native.x11Open() != 0) {
          return HostUnavailableReason.unsupportedPlatform;
        }
      case LinuxBackend.wayland:
        if (!_native.hasWayland) {
          return HostUnavailableReason.unsupportedPlatform;
        }
        if (!allowWayland) return HostUnavailableReason.waylandNotAllowed;
        if (!_native.wlConnected()) {
          return HostUnavailableReason.permissionDenied;
        }
    }
    if (!allowElevatedHost && _native.euid == 0) {
      return HostUnavailableReason.elevatedHost;
    }
    return null;
  }

  @override
  late final InputInjector injector;

  @override
  late final SurfaceResolver surfaces;

  @override
  late final LinuxLocalActivity localActivity;

  @override
  late final LinuxSecureContext secureContext;
}

/// Shared by the Wayland injector and resolver: which libei region the
/// injector posts into (the one the session's surface resolved to last),
/// and where it last put the pointer.
final class LinuxPointerTarget {
  /// The region's id, or 0 for the desktop's regions (a [RectSurface] in
  /// the desktop's logical pixels).
  int region = 0;

  /// Where the injector last put the pointer, in the region's coordinates.
  Offset? pointer;
}

/// Linux evdev key codes the injectors press for text.
abstract final class _Evdev {
  static const int enter = 28;
  static const int tab = 15;
}

/// The Linux key code for USB HID [usage], or `null`.
int? linuxKeyCode(int usage) => hidToLinuxKeyCode[usage];

/// Splits [text] for typing: line breaks (`\r\n`, `\r`, `\n`) become
/// [_Evdev.enter], tabs [_Evdev.tab] (as negative numbers, keys), and the
/// rest code points.
List<int> linuxTextSteps(String text) {
  final out = <int>[];
  final runes = text.runes.toList();
  for (var i = 0; i < runes.length; i++) {
    final r = runes[i];
    if (r == 0x0D) {
      if (i + 1 < runes.length && runes[i + 1] == 0x0A) i++;
      out.add(-_Evdev.enter);
    } else if (r == 0x0A) {
      out.add(-_Evdev.enter);
    } else if (r == 0x09) {
      out.add(-_Evdev.tab);
    } else {
      out.add(r);
    }
  }
  return out;
}

/// Wheel deltas as whole notches (X11's buttons 4 to 7) or 120ths of a
/// notch (libei), keeping fractions between calls.
///
/// A notch is three lines, as Windows' default and Chromium's 100 pixels:
/// a wire line is a third of a notch and a wire pixel 3/100 of one. The
/// wire's positive dy scrolls down (reveals what's below), as X11's button
/// 5 and libei's positive values do.
final class LinuxWheelConverter {
  /// Creates a converter whose whole units are [unitsPerNotch] to a notch
  /// (1 for X11 buttons, 120 for libei's discrete scroll).
  LinuxWheelConverter({this.unitsPerNotch = 1});

  /// How many output units make a notch.
  final int unitsPerNotch;

  double _x = 0;
  double _y = 0;

  /// The `(horizontal, vertical)` whole units for wire deltas [dx], [dy] in
  /// pixels or lines.
  (int, int) convert({required int dx, required int dy, required bool pixels}) {
    _x = _accumulate(_x, dx, pixels);
    _y = _accumulate(_y, dy, pixels);
    final x = _whole(_x);
    final y = _whole(_y);
    _x -= x;
    _y -= y;
    return (x, y);
  }

  double _accumulate(double acc, int delta, bool pixels) {
    if (delta == 0) return acc;
    // A reversal starts afresh rather than cancelling the remainder.
    if (acc != 0 && (acc < 0) != (delta < 0)) acc = 0;
    final notches = pixels ? delta / 100 : delta / 3;
    return acc + notches * unitsPerNotch;
  }

  static int _whole(double v) => (v * 1e6).round() ~/ 1000000;
}

InjectResult _result(int status) => switch (status) {
  LinuxStatus.ok => InjectResult.injected,
  LinuxStatus.permissionDenied => InjectResult.permissionDenied,
  LinuxStatus.unmapped => InjectResult.unmappedKey,
  _ => InjectResult.failed,
};

/// X11 buttons for [PointerButton]s: back and forward are 8 and 9.
int _x11Button(PointerButton b) => switch (b) {
  PointerButton.left => 1,
  PointerButton.middle => 2,
  PointerButton.right => 3,
  PointerButton.back => 8,
  PointerButton.forward => 9,
};

/// evdev buttons (`BTN_LEFT`...) for [PointerButton]s.
int _evdevButton(PointerButton b) => switch (b) {
  PointerButton.left => 0x110,
  PointerButton.right => 0x111,
  PointerButton.middle => 0x112,
  PointerButton.back => 0x113,
  PointerButton.forward => 0x114,
};

/// Posts input with XTest from the package's own X connection, so the X
/// server marks it as the XTEST device's, which the local-activity monitor
/// leaves out.
///
/// - The pointer goes to the root-window pixel containing the point.
///   Buttons and the wheel move it there first.
/// - Keys by evdev code (X keycode = code + 8). Repeats are dropped: the X
///   server repeats a held key itself.
/// - Text: a character the keyboard layout has is typed with its key (and
///   Shift or AltGr), under the current group and Caps Lock. Any other is
///   bound to a spare keycode (one with no keysyms; never rebound within a
///   second of its last use, since X clients read the keymap when they read
///   the event, so a character that would need one sooner is skipped and
///   reported as [InjectResult.unmappedKey]) and pressed. Line breaks and
///   tabs press Enter and Tab. The spare keycodes are unbound
///   [textRestoreDelay] after the last text.
final class LinuxX11Injector implements InputInjector {
  /// Creates an injector over [native].
  LinuxX11Injector(
    this._native, {
    this.textRestoreDelay = const Duration(milliseconds: 1500),
  });

  final LinuxNative _native;

  /// How long after the last text the spare keycodes are unbound.
  final Duration textRestoreDelay;

  final LinuxWheelConverter _wheel = LinuxWheelConverter();
  Timer? _restore;

  InjectResult _moveTo(Offset point) =>
      _result(_native.x11Move(point.dx.floor(), point.dy.floor()));

  @override
  InjectResult movePointer(
    Offset point, {
    required Set<PointerButton> heldButtons,
  }) => _moveTo(point);

  @override
  InjectResult pointerButton(
    Offset point,
    PointerButton button, {
    required bool down,
    required int clickCount,
  }) {
    final moved = _moveTo(point);
    // A release is posted wherever the pointer is, so nothing stays down.
    if (moved != InjectResult.injected && down) return moved;
    return _result(_native.x11Button(_x11Button(button), down: down));
  }

  @override
  InjectResult wheel(
    Offset point, {
    required int dx,
    required int dy,
    required WheelUnit unit,
  }) {
    final moved = _moveTo(point);
    if (moved != InjectResult.injected) return moved;
    final (h, v) = _wheel.convert(
      dx: dx,
      dy: dy,
      pixels: unit == WheelUnit.pixel,
    );
    var r = InjectResult.injected;
    void notches(int n, int positive, int negative) {
      final button = n > 0 ? positive : negative;
      for (var i = 0; i < n.abs() && r == InjectResult.injected; i++) {
        r = _result(_native.x11Button(button, down: true));
        if (r == InjectResult.injected) {
          r = _result(_native.x11Button(button, down: false));
        }
      }
    }

    notches(v, 5, 4);
    notches(h, 7, 6);
    return r;
  }

  @override
  InjectResult key(int usage, {required bool down, bool repeat = false}) {
    final code = linuxKeyCode(usage);
    if (code == null) return InjectResult.unmappedKey;
    if (down && repeat) return InjectResult.injected;
    return _result(_native.x11Key(code, down: down));
  }

  @override
  InjectResult text(String text) {
    var result = InjectResult.injected;
    for (final step in linuxTextSteps(text)) {
      InjectResult r;
      if (step < 0) {
        r = _result(_native.x11Key(-step, down: true));
        if (r == InjectResult.injected) {
          r = _result(_native.x11Key(-step, down: false));
        }
      } else {
        r = _result(_native.x11Text(step));
      }
      if (r == InjectResult.unmappedKey) {
        result = r;
        continue;
      }
      if (r != InjectResult.injected) {
        result = r;
        break;
      }
    }
    _restore?.cancel();
    _restore = Timer(textRestoreDelay, () {
      _restore = null;
      _native.x11TextRestore();
    });
    return result;
  }
}

/// Posts input with libei through the RemoteDesktop portal's EIS.
///
/// - The pointer: absolute motion in the region of the session's surface
///   (a monitor's region in the desktop's logical pixels, or a window
///   stream's, from 0, 0 at the window). Buttons and the wheel move it
///   there first.
/// - The wheel: libei's smooth scroll for pixels, discrete steps (120 a
///   notch) for lines.
/// - Keys by evdev code. Repeats are dropped: Wayland clients repeat a held
///   key themselves.
/// - Text with the compositor's keymap (Shift and AltGr as needed); a
///   character it can't type is skipped, and the call returns
///   [InjectResult.unmappedKey].
final class LinuxWaylandInjector implements InputInjector {
  /// Creates an injector over [native], posting into [target]'s region.
  LinuxWaylandInjector(this._native, this._target);

  final LinuxNative _native;
  final LinuxPointerTarget _target;
  final LinuxWheelConverter _wheel = LinuxWheelConverter(unitsPerNotch: 120);

  InjectResult _moveTo(Offset point) {
    final r = _result(_native.wlMove(_target.region, point.dx, point.dy));
    if (r == InjectResult.injected) _target.pointer = point;
    return r;
  }

  @override
  InjectResult movePointer(
    Offset point, {
    required Set<PointerButton> heldButtons,
  }) => _moveTo(point);

  @override
  InjectResult pointerButton(
    Offset point,
    PointerButton button, {
    required bool down,
    required int clickCount,
  }) {
    final moved = _moveTo(point);
    if (moved != InjectResult.injected && down) return moved;
    return _result(_native.wlButton(_evdevButton(button), down: down));
  }

  @override
  InjectResult wheel(
    Offset point, {
    required int dx,
    required int dy,
    required WheelUnit unit,
  }) {
    final moved = _moveTo(point);
    if (moved != InjectResult.injected) return moved;
    if (unit == WheelUnit.pixel) {
      return _result(
        _native.wlScroll(dx.toDouble(), dy.toDouble(), discrete: false),
      );
    }
    final (h, v) = _wheel.convert(dx: dx, dy: dy, pixels: false);
    if (h == 0 && v == 0) return InjectResult.injected;
    return _result(
      _native.wlScroll(h.toDouble(), v.toDouble(), discrete: true),
    );
  }

  @override
  InjectResult key(int usage, {required bool down, bool repeat = false}) {
    final code = linuxKeyCode(usage);
    if (code == null) return InjectResult.unmappedKey;
    if (down && repeat) return InjectResult.injected;
    return _result(_native.wlKey(code, down: down));
  }

  @override
  InjectResult text(String text) {
    var result = InjectResult.injected;
    for (final step in linuxTextSteps(text)) {
      InjectResult r;
      if (step < 0) {
        r = _result(_native.wlKey(-step, down: true));
        if (r == InjectResult.injected) {
          r = _result(_native.wlKey(-step, down: false));
        }
      } else {
        r = _result(_native.wlText(step));
      }
      if (r == InjectResult.unmappedKey) {
        result = r;
        continue;
      }
      if (r != InjectResult.injected) return r;
    }
    return result;
  }
}

/// Displays and windows on X11, in root-window pixels.
///
/// Window bounds, the window under a point and the active window are read
/// from the X server at every check (one round trip each, about 0.1 ms
/// locally), so [refreshWindows] does nothing. Monitors (RandR 1.5) are
/// cached for [displayCacheLifetime].
final class LinuxX11SurfaceResolver implements SurfaceResolver {
  /// Creates a resolver over [native].
  LinuxX11SurfaceResolver(
    this._native, {
    this.displayCacheLifetime = const Duration(seconds: 1),
  });

  final LinuxNative _native;

  /// How long the monitor list is reused.
  final Duration displayCacheLifetime;

  final Stopwatch _watch = clock.stopwatch()..start();
  List<DisplayInfo>? _displays;
  Duration? _displaysAt;

  List<DisplayInfo> _readDisplays() {
    final at = _displaysAt;
    final now = _watch.elapsed;
    final cached = _displays;
    if (cached != null &&
        at != null &&
        now >= at &&
        now - at < displayCacheLifetime) {
      return cached;
    }
    _displaysAt = now;
    return _displays = [
      for (final m in _native.x11Monitors())
        DisplayInfo(
          id: m.id,
          bounds: m.bounds,
          scaleFactor: 1,
          isPrimary: m.isPrimary,
        ),
    ];
  }

  @override
  Future<List<DisplayInfo>> displays() async =>
      List.unmodifiable(_readDisplays());

  @override
  SurfaceGeometry? resolve(SharedSurface surface) {
    switch (surface) {
      case DisplaySurface(:final displayId):
        for (final d in _readDisplays()) {
          if (d.id == displayId) {
            return SurfaceGeometry(bounds: d.bounds, pixelSize: d.pixelSize);
          }
        }
        return null;
      case WindowSurface(:final handle):
        final w = _native.x11Window(handle);
        if (w == null) return null;
        return SurfaceGeometry(
          bounds: w.bounds,
          pixelSize: w.bounds.size,
          isHidden: !w.shown,
        );
      case RectSurface s:
        return s.isClosed
            ? null
            : SurfaceGeometry(bounds: s.bounds, pixelSize: s.pixelSize);
    }
  }

  /// Whether the topmost window at [point] is [surface]'s: the window's own
  /// X client (its menus, popups and other windows) or a window transient
  /// for it (a dialog, even another process's), as Windows' owner chain.
  @override
  bool isOnSurface(SharedSurface surface, Offset point) {
    if (surface is! WindowSurface) return true;
    return _native.x11OnWindow(
          surface.handle,
          point.dx.floor(),
          point.dy.floor(),
        ) ??
        false;
  }

  /// Whether the active window (`_NET_ACTIVE_WINDOW`) is [surface]'s
  /// client's, or transient for it.
  @override
  bool hasKeyboardFocus(SharedSurface surface) {
    if (surface is! WindowSurface) return true;
    return _native.x11HasFocus(surface.handle) ?? false;
  }

  /// Whether the topmost window at [point] is this process's: made on its
  /// GDK connection, or with its `_NET_WM_PID`. Unknown counts as yes.
  @override
  bool isOwnWindowAt(Offset point) =>
      _native.x11OwnWindowAt(point.dx.floor(), point.dy.floor()) ?? true;

  /// Whether the active window is this process's. Unknown counts as yes.
  @override
  bool isOwnAppInFront() => _native.x11OwnAppInFront() ?? true;

  @override
  void refreshWindows() {}
}

/// Displays on Wayland: the libei regions of the portal session, in the
/// compositor's logical pixels.
///
/// A monitor's region sits where the monitor is on the desktop; a window
/// stream's region starts at 0, 0 at the window's top-left corner, sized
/// as the stream's largest size until its content size is given
/// (`RemoteInputPortal.updateContentSize`).
///
/// Wayland tells no client where windows are, so window surfaces
/// ([WindowSurface]) aren't supported (a window share is a portal stream,
/// a [DisplaySurface]), nothing occludes a point ([isOnSurface] is always
/// true) and keyboard focus isn't checked ([hasKeyboardFocus] is always
/// true): gaps the app opts into (`HostOptions.allowWayland`).
final class LinuxWaylandSurfaceResolver implements SurfaceResolver {
  /// Creates a resolver over [native] that sets [target]'s region.
  /// [contentSizeOf] gives a window stream's content size.
  LinuxWaylandSurfaceResolver(
    this._native,
    this._target, {
    Size? Function(int displayId)? contentSizeOf,
  }) : _contentSizeOf = contentSizeOf; // ignore: prefer_initializing_formals

  final LinuxNative _native;
  final LinuxPointerTarget _target;
  final Size? Function(int displayId)? _contentSizeOf;

  int? _generation;
  List<LinuxDisplayRecord> _regions = const [];

  List<LinuxDisplayRecord> _read() {
    final g = _native.wlGeneration();
    if (g != _generation) {
      _generation = g;
      _regions = _native.wlRegions();
    }
    return _regions;
  }

  Rect _boundsOf(LinuxDisplayRecord r) {
    final size = r.mappingId.isEmpty ? null : _contentSizeOf?.call(r.id);
    if (size == null || size.isEmpty) return r.bounds;
    return Rect.fromLTWH(
      r.bounds.left,
      r.bounds.top,
      size.width.clamp(1, r.bounds.width),
      size.height.clamp(1, r.bounds.height),
    );
  }

  @override
  Future<List<DisplayInfo>> displays() async {
    final regions = _read();
    return List.unmodifiable([
      for (final (i, r) in regions.indexed)
        DisplayInfo(
          id: r.id,
          bounds: _boundsOf(r),
          scaleFactor: r.scale,
          isPrimary: i == 0,
        ),
    ]);
  }

  @override
  SurfaceGeometry? resolve(SharedSurface surface) {
    switch (surface) {
      case DisplaySurface(:final displayId):
        for (final r in _read()) {
          if (r.id != displayId) continue;
          _target.region = r.id;
          final b = _boundsOf(r);
          return SurfaceGeometry(bounds: b, pixelSize: b.size * r.scale);
        }
        return null;
      case WindowSurface():
        return null;
      case RectSurface s:
        _target.region = 0;
        return s.isClosed
            ? null
            : SurfaceGeometry(bounds: s.bounds, pixelSize: s.pixelSize);
    }
  }

  @override
  bool isOnSurface(SharedSurface surface, Offset point) => true;

  @override
  bool hasKeyboardFocus(SharedSurface surface) => true;

  /// Whether GTK says the pointer is over one of this process's windows
  /// and [point] is where the package last put the pointer: a press or
  /// wheel there would reach the host app. A point elsewhere is let
  /// through, since where it lands can't be known before the pointer gets
  /// there, so moves are never stuck. Unknown counts as yes.
  @override
  bool isOwnWindowAt(Offset point) {
    final over = _native.wlPointerOverOwnWindow();
    if (over == null) return true;
    if (!over) return false;
    final at = _target.pointer;
    return at == null || (at - point).distance < 2;
  }

  /// Whether one of this process's windows has focus. Unknown counts as
  /// yes.
  @override
  bool isOwnAppInFront() => _native.wlOwnAppInFront() ?? true;

  @override
  void refreshWindows() {}
}

/// The Linux secure-context checks: the session's lock state from logind
/// (`blocked(sessionInactive)` while locked or while another session is in
/// front), and on Wayland the compositor pausing the devices.
final class LinuxSecureContext implements SecureContextProbe {
  /// Creates the probe over [native].
  LinuxSecureContext(this._native, this._backend);

  final LinuxNative _native;
  final LinuxBackend _backend;

  @override
  BlockReason? check(InputKind kind, {Offset? point}) {
    switch (_native.sessionState()) {
      case LinuxSessionState.locked:
      case LinuxSessionState.inactive:
        return BlockReason.sessionInactive;
      case LinuxSessionState.active:
      case LinuxSessionState.unknown:
        break;
    }
    if (_backend == LinuxBackend.wayland && _native.wlPaused()) {
      return BlockReason.sessionInactive;
    }
    return null;
  }
}
