// LinuxNative over dart:ffi: the plugin's C functions
// (linux/remote_input_native.h), looked up in the plugin's shared library,
// which the app's runner has already loaded (docs/design.md §7.5). Only
// imported from linux_platform.dart, which only native (non-web) builds
// compile.

import 'dart:convert' show utf8;
import 'dart:ffi';
import 'dart:ui' show Rect;

import 'package:ffi/ffi.dart' show calloc;

import 'linux_native.dart';

typedef _I32C = Int32 Function();
typedef _I32 = int Function();
typedef _I64C = Int64 Function();
typedef _VoidC = Void Function();
typedef _Void = void Function();
typedef _I32I32 = int Function(int);
typedef _I32I32I32C = Int32 Function(Int32, Int32);
typedef _I32I32I32 = int Function(int, int);
typedef _TextC = Int32 Function(Uint32);
typedef _WindowC = Int32 Function(
  Uint64,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Int32>,
);
typedef _Window = int Function(
  int,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Int32>,
);
typedef _XidC = Int32 Function(Uint64);
typedef _XidPointC = Int32 Function(Uint64, Int32, Int32);
typedef _XidPoint = int Function(int, int, int);
typedef _MonitorsC = Int32 Function(
  Int32,
  Pointer<Int64>,
  Pointer<Int32>,
  Pointer<Int32>,
);
typedef _Monitors = int Function(
  int,
  Pointer<Int64>,
  Pointer<Int32>,
  Pointer<Int32>,
);
typedef _RegionsC = Int32 Function(
  Int32,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Uint8>,
);
typedef _Regions = int Function(
  int,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Uint8>,
);
typedef _MoveC = Int32 Function(Int32, Double, Double);
typedef _Move = int Function(int, double, double);
typedef _ScrollC = Int32 Function(Double, Double, Int32);
typedef _Scroll = int Function(double, double, int);

/// The plugin's library: loaded already by the runner, which links it.
const String _library = 'libremote_input_plugin.so';

/// The most displays or regions read at once.
const int _maxDisplays = 32;

/// [LinuxNative] over the plugin's C functions.
final class FfiLinuxNative implements LinuxNative {
  FfiLinuxNative._(DynamicLibrary lib)
    : _backend = lib.lookupFunction<_I32C, _I32>('ri_backend', isLeaf: true),
      _hasWayland = lib.lookupFunction<_I32C, _I32>(
        'ri_has_wayland',
        isLeaf: true,
      ),
      _euid = lib.lookupFunction<_I32C, _I32>('ri_euid', isLeaf: true),
      _pid = lib.lookupFunction<_I32C, _I32>('ri_pid', isLeaf: true),
      _sessionState = lib.lookupFunction<_I32C, _I32>('ri_session_state'),
      _x11Open = lib.lookupFunction<_I32C, _I32>('ri_x11_open'),
      _x11Move = lib.lookupFunction<_I32I32I32C, _I32I32I32>('ri_x11_move'),
      _x11Button = lib.lookupFunction<_I32I32I32C, _I32I32I32>('ri_x11_button'),
      _x11Key = lib.lookupFunction<_I32I32I32C, _I32I32I32>('ri_x11_key'),
      _x11Text = lib.lookupFunction<_TextC, _I32I32>('ri_x11_text'),
      _x11TextRestore = lib.lookupFunction<_VoidC, _Void>(
        'ri_x11_text_restore',
      ),
      _x11Monitors = lib.lookupFunction<_MonitorsC, _Monitors>(
        'ri_x11_monitors',
      ),
      _x11Window = lib.lookupFunction<_WindowC, _Window>('ri_x11_window'),
      _x11OnWindow = lib.lookupFunction<_XidPointC, _XidPoint>(
        'ri_x11_on_window',
      ),
      _x11HasFocus = lib.lookupFunction<_XidC, _I32I32>('ri_x11_has_focus'),
      _x11OwnWindowAt = lib.lookupFunction<_I32I32I32C, _I32I32I32>(
        'ri_x11_own_window_at',
      ),
      _x11OwnAppInFront = lib.lookupFunction<_I32C, _I32>(
        'ri_x11_own_app_in_front',
      ),
      _wlConnected = lib.lookupFunction<_I32C, _I32>('ri_wl_connected'),
      _wlPaused = lib.lookupFunction<_I32C, _I32>('ri_wl_paused'),
      _wlGeneration = lib.lookupFunction<_I32C, _I32>(
        'ri_wl_generation',
        isLeaf: true,
      ),
      _wlRegions = lib.lookupFunction<_RegionsC, _Regions>('ri_wl_regions'),
      _wlMove = lib.lookupFunction<_MoveC, _Move>('ri_wl_move'),
      _wlButton = lib.lookupFunction<_I32I32I32C, _I32I32I32>('ri_wl_button'),
      _wlScroll = lib.lookupFunction<_ScrollC, _Scroll>('ri_wl_scroll'),
      _wlKey = lib.lookupFunction<_I32I32I32C, _I32I32I32>('ri_wl_key'),
      _wlText = lib.lookupFunction<_TextC, _I32I32>('ri_wl_text'),
      _wlOwnAppInFront = lib.lookupFunction<_I32C, _I32>(
        'ri_wl_own_app_in_front',
        isLeaf: true,
      ),
      _wlPointerOverOwnWindow = lib.lookupFunction<_I32C, _I32>(
        'ri_wl_pointer_over_own_window',
        isLeaf: true,
      ),
      _activityStart = lib.lookupFunction<_I32C, _I32>('ri_activity_start'),
      _activityStop = lib.lookupFunction<_VoidC, _Void>('ri_activity_stop'),
      _activityCount = lib.lookupFunction<_I64C, _I32>(
        'ri_activity_count',
        isLeaf: true,
      ),
      _activityHealthy = lib.lookupFunction<_I32C, _I32>(
        'ri_activity_healthy',
        isLeaf: true,
      ),
      _activityHeartbeatAgeMs = lib.lookupFunction<_I64C, _I32>(
        'ri_activity_heartbeat_age_ms',
        isLeaf: true,
      ),
      _activityReason = lib.lookupFunction<Int64 Function(Int32), _I32I32>(
        'ri_activity_reason',
        isLeaf: true,
      ),
      _activityLongestGapMs = lib.lookupFunction<_I64C, _I32>(
        'ri_activity_longest_gap_ms',
        isLeaf: true,
      ),
      _activityDevicesLost = lib.lookupFunction<_I64C, _I32>(
        'ri_activity_devices_lost',
        isLeaf: true,
      );

  /// The bindings, or `null` if the plugin's library isn't in this process
  /// (a plain `flutter test` run, say).
  static FfiLinuxNative? open() {
    try {
      return FfiLinuxNative._(DynamicLibrary.open(_library));
    } on Object {
      return null;
    }
  }

  final _I32 _backend;
  final _I32 _hasWayland;
  final _I32 _euid;
  final _I32 _pid;
  final _I32 _sessionState;
  final _I32 _x11Open;
  final _I32I32I32 _x11Move;
  final _I32I32I32 _x11Button;
  final _I32I32I32 _x11Key;
  final _I32I32 _x11Text;
  final _Void _x11TextRestore;
  final _Monitors _x11Monitors;
  final _Window _x11Window;
  final _XidPoint _x11OnWindow;
  final _I32I32 _x11HasFocus;
  final _I32I32I32 _x11OwnWindowAt;
  final _I32 _x11OwnAppInFront;
  final _I32 _wlConnected;
  final _I32 _wlPaused;
  final _I32 _wlGeneration;
  final _Regions _wlRegions;
  final _Move _wlMove;
  final _I32I32I32 _wlButton;
  final _Scroll _wlScroll;
  final _I32I32I32 _wlKey;
  final _I32I32 _wlText;
  final _I32 _wlOwnAppInFront;
  final _I32 _wlPointerOverOwnWindow;
  final _I32 _activityStart;
  final _Void _activityStop;
  final _I32 _activityCount;
  final _I32 _activityHealthy;
  final _I32 _activityHeartbeatAgeMs;
  final _I32I32 _activityReason;
  final _I32 _activityLongestGapMs;
  final _I32 _activityDevicesLost;

  static bool? _tri(int v) => v < 0 ? null : v != 0;

  @override
  LinuxBackend get backend {
    final b = _backend();
    return b >= 0 && b < LinuxBackend.values.length
        ? LinuxBackend.values[b]
        : LinuxBackend.none;
  }

  @override
  bool get hasWayland => _hasWayland() != 0;

  @override
  int get euid => _euid();

  @override
  int get pid => _pid();

  @override
  LinuxSessionState sessionState() {
    final s = _sessionState();
    return s >= 0 && s < LinuxSessionState.values.length
        ? LinuxSessionState.values[s]
        : LinuxSessionState.unknown;
  }

  @override
  int x11Open() => _x11Open();

  @override
  int x11Move(int x, int y) => _x11Move(x, y);

  @override
  int x11Button(int button, {required bool down}) =>
      _x11Button(button, down ? 1 : 0);

  @override
  int x11Key(int code, {required bool down}) => _x11Key(code, down ? 1 : 0);

  @override
  int x11Text(int codepoint) => _x11Text(codepoint);

  @override
  void x11TextRestore() => _x11TextRestore();

  @override
  List<LinuxDisplayRecord> x11Monitors() {
    final ids = calloc<Int64>(_maxDisplays);
    final rects = calloc<Int32>(_maxDisplays * 4);
    final primary = calloc<Int32>(_maxDisplays);
    try {
      final n = _x11Monitors(_maxDisplays, ids, rects, primary);
      return [
        for (var i = 0; i < n; i++)
          LinuxDisplayRecord(
            id: ids[i],
            bounds: Rect.fromLTWH(
              rects[i * 4].toDouble(),
              rects[i * 4 + 1].toDouble(),
              rects[i * 4 + 2].toDouble(),
              rects[i * 4 + 3].toDouble(),
            ),
            isPrimary: primary[i] != 0,
          ),
      ];
    } finally {
      calloc
        ..free(ids)
        ..free(rects)
        ..free(primary);
    }
  }

  @override
  LinuxWindow? x11Window(int xid) {
    final out = calloc<Int32>(4);
    try {
      final state = _x11Window(xid, out, out + 1, out + 2, out + 3);
      if (state == 0) return null;
      return LinuxWindow(
        bounds: Rect.fromLTWH(
          out[0].toDouble(),
          out[1].toDouble(),
          out[2].toDouble(),
          out[3].toDouble(),
        ),
        shown: state == 1,
      );
    } finally {
      calloc.free(out);
    }
  }

  @override
  bool? x11OnWindow(int xid, int x, int y) => _tri(_x11OnWindow(xid, x, y));

  @override
  bool? x11HasFocus(int xid) => _tri(_x11HasFocus(xid));

  @override
  bool? x11OwnWindowAt(int x, int y) => _tri(_x11OwnWindowAt(x, y));

  @override
  bool? x11OwnAppInFront() => _tri(_x11OwnAppInFront());

  @override
  bool wlConnected() => _wlConnected() != 0;

  @override
  bool wlPaused() => _wlPaused() != 0;

  @override
  int wlGeneration() => _wlGeneration();

  @override
  List<LinuxDisplayRecord> wlRegions() {
    final ids = calloc<Int32>(_maxDisplays);
    final rects = calloc<Int32>(_maxDisplays * 4);
    final scales = calloc<Int32>(_maxDisplays);
    final mapping = calloc<Uint8>(_maxDisplays * 64);
    try {
      final n = _wlRegions(_maxDisplays, ids, rects, scales, mapping);
      return [
        for (var i = 0; i < n; i++)
          LinuxDisplayRecord(
            id: ids[i],
            bounds: Rect.fromLTWH(
              rects[i * 4].toDouble(),
              rects[i * 4 + 1].toDouble(),
              rects[i * 4 + 2].toDouble(),
              rects[i * 4 + 3].toDouble(),
            ),
            scale: scales[i] / 1000,
            mappingId: _string(mapping + i * 64, 64),
          ),
      ];
    } finally {
      calloc
        ..free(ids)
        ..free(rects)
        ..free(scales)
        ..free(mapping);
    }
  }

  static String _string(Pointer<Uint8> p, int max) {
    var n = 0;
    while (n < max && p[n] != 0) {
      n++;
    }
    return utf8.decode(p.asTypedList(n), allowMalformed: true);
  }

  @override
  int wlMove(int region, double x, double y) => _wlMove(region, x, y);

  @override
  int wlButton(int button, {required bool down}) =>
      _wlButton(button, down ? 1 : 0);

  @override
  int wlScroll(double dx, double dy, {required bool discrete}) =>
      _wlScroll(dx, dy, discrete ? 1 : 0);

  @override
  int wlKey(int code, {required bool down}) => _wlKey(code, down ? 1 : 0);

  @override
  int wlText(int codepoint) => _wlText(codepoint);

  @override
  bool? wlOwnAppInFront() => _tri(_wlOwnAppInFront());

  @override
  bool? wlPointerOverOwnWindow() => _tri(_wlPointerOverOwnWindow());

  @override
  bool activityStart() => _activityStart() != 0;

  @override
  void activityStop() => _activityStop();

  @override
  int activityCount() => _activityCount();

  @override
  bool activityHealthy() => _activityHealthy() != 0;

  @override
  int activityHeartbeatAgeMs() => _activityHeartbeatAgeMs();

  @override
  int activityReason(LinuxActivityReason reason) =>
      _activityReason(reason.index);

  @override
  int activityLongestGapMs() => _activityLongestGapMs();

  @override
  int activityDevicesLost() => _activityDevicesLost();
}
