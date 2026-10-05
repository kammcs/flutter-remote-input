// MacosNative over dart:ffi: the plugin's `@_cdecl` Swift functions
// (macos/remote_input/Sources/remote_input/RemoteInputNative.swift), looked
// up in the running process (docs/design.md §7.1). Only imported from
// macos_platform.dart, which only native (non-web) builds compile.

import 'dart:ffi';
import 'dart:io' show pid;
import 'dart:ui' show Offset, Rect;

import 'package:ffi/ffi.dart' show calloc;

import '../../surface.dart';
import 'macos_native.dart';

typedef _AccessC = Int32 Function(Int32 fresh);
typedef _Access = int Function(int fresh);
typedef _MouseC = Int32 Function(
  Uint32 type,
  Double x,
  Double y,
  Int32 button,
  Int32 clickState,
  Uint64 flags,
);
typedef _Mouse = int Function(
  int type,
  double x,
  double y,
  int button,
  int clickState,
  int flags,
);
typedef _ScrollC = Int32 Function(
  Double x,
  Double y,
  Int32 unit,
  Int32 wheel1,
  Int32 wheel2,
  Uint64 flags,
);
typedef _Scroll = int Function(
  double x,
  double y,
  int unit,
  int wheel1,
  int wheel2,
  int flags,
);
typedef _KeyC = Int32 Function(
  Uint16 keyCode,
  Int32 down,
  Int32 autorepeat,
  Uint64 flags,
);
typedef _Key = int Function(int keyCode, int down, int autorepeat, int flags);
typedef _TextC = Int32 Function(Pointer<Uint16> units, Int32 length);
typedef _Text = int Function(Pointer<Uint16> units, int length);
typedef _OutC = Int32 Function(Pointer<Double> out);
typedef _Out = int Function(Pointer<Double> out);
typedef _ListC = Int32 Function(Pointer<Double> out, Int32 capacity);
typedef _List = int Function(Pointer<Double> out, int capacity);
typedef _WindowC = Int32 Function(
  Uint32 windowId,
  Pointer<Double> out,
  Int32 capacity,
);
typedef _Window = int Function(int windowId, Pointer<Double> out, int capacity);
typedef _PidsC = Int32 Function(Pointer<Int32> out, Int32 capacity);
typedef _Pids = int Function(Pointer<Int32> out, int capacity);
typedef _Int32C = Int32 Function();
typedef _Int64C = Int64 Function();
typedef _IntGet = int Function();
typedef _SnapshotC = Void Function(Pointer<Double> out);
typedef _Snapshot = void Function(Pointer<Double> out);

/// The symbol that shows the plugin's native code is in this process.
const String _probeSymbol = 'remote_input_post_access';

/// The most displays read at once.
const int _maxDisplays = 32;

/// The most windows read at once: above a shared window, or on screen
/// (front to back, so any beyond are the backmost).
const int _maxAbove = 512;

/// The most keyboard-panel processes read at once.
const int _maxPanelPids = 8;

/// [MacosNative] through dart:ffi.
final class FfiMacosNative implements MacosNative {
  FfiMacosNative._(DynamicLibrary lib)
    : _access = lib.lookupFunction<_AccessC, _Access>(
        'remote_input_post_access',
      ),
      _mouse = lib.lookupFunction<_MouseC, _Mouse>('remote_input_post_mouse'),
      _scroll = lib.lookupFunction<_ScrollC, _Scroll>(
        'remote_input_post_scroll',
      ),
      _key = lib.lookupFunction<_KeyC, _Key>('remote_input_post_key'),
      _text = lib.lookupFunction<_TextC, _Text>('remote_input_post_text'),
      _cursor = lib.lookupFunction<_OutC, _Out>('remote_input_cursor_location'),
      _displays = lib.lookupFunction<_ListC, _List>('remote_input_displays'),
      _generation = lib.lookupFunction<_Int64C, _IntGet>(
        'remote_input_display_generation',
      ),
      _window = lib.lookupFunction<_WindowC, _Window>(
        'remote_input_window_info',
      ),
      _windowList = lib.lookupFunction<_ListC, _List>(
        'remote_input_window_list',
      ),
      _panels = lib.lookupFunction<_PidsC, _Pids>(
        'remote_input_keyboard_panel_pids',
      ),
      _frontmost = lib.lookupFunction<_Int32C, _IntGet>(
        'remote_input_frontmost_pid',
      ),
      _secure = lib.lookupFunction<_Int32C, _IntGet>(
        'remote_input_secure_input',
      ),
      _session = lib.lookupFunction<_Int32C, _IntGet>(
        'remote_input_session_state',
      ),
      _snapshot = lib.lookupFunction<_SnapshotC, _Snapshot>(
        'remote_input_activity_snapshot',
      );

  /// The native functions in this process, or `null` if the plugin's native
  /// code isn't linked in (a `flutter test` run, or a Dart program without
  /// the plugin).
  static FfiMacosNative? open() {
    final lib = DynamicLibrary.process();
    if (!lib.providesSymbol(_probeSymbol)) return null;
    return FfiMacosNative._(lib);
  }

  final _Access _access;
  final _Mouse _mouse;
  final _Scroll _scroll;
  final _Key _key;
  final _Text _text;
  final _Out _cursor;
  final _List _displays;
  final _IntGet _generation;
  final _Window _window;
  final _List _windowList;
  final _Pids _panels;
  final _IntGet _frontmost;
  final _IntGet _secure;
  final _IntGet _session;
  final _Snapshot _snapshot;

  // Buffers live as long as the process: this object is a singleton
  // (macosHostPlatform()).
  final Pointer<Uint16> _textBuffer = calloc<Uint16>(20);
  final Pointer<Double> _small = calloc<Double>(16);
  final Pointer<Double> _displayBuffer = calloc<Double>(_maxDisplays * 7);
  final Pointer<Double> _windowBuffer = calloc<Double>(7 + _maxAbove * 7);
  final Pointer<Int32> _pidBuffer = calloc<Int32>(_maxPanelPids);

  @override
  bool postAccess({required bool fresh}) => _access(fresh ? 1 : 0) != 0;

  @override
  int postMouse(
    int type,
    Offset point, {
    required int button,
    required int clickState,
    required int flags,
  }) => _mouse(type, point.dx, point.dy, button, clickState, flags);

  @override
  int postScroll(
    Offset point, {
    required int unit,
    required int wheel1,
    required int wheel2,
    required int flags,
  }) => _scroll(point.dx, point.dy, unit, wheel1, wheel2, flags);

  @override
  int postKey(
    int keyCode, {
    required bool down,
    required bool autorepeat,
    required int flags,
  }) => _key(keyCode, down ? 1 : 0, autorepeat ? 1 : 0, flags);

  @override
  int postText(List<int> units) {
    if (units.isEmpty || units.length > 20) return MacosStatus.failed;
    for (var i = 0; i < units.length; i++) {
      _textBuffer[i] = units[i];
    }
    final r = _text(_textBuffer, units.length);
    // Don't leave typed text lying in memory longer than needed.
    for (var i = 0; i < units.length; i++) {
      _textBuffer[i] = 0;
    }
    return r;
  }

  @override
  Offset? cursorLocation() =>
      _cursor(_small) == 0 ? null : Offset(_small[0], _small[1]);

  @override
  List<DisplayInfo> displays() {
    final count = _displays(_displayBuffer, _maxDisplays);
    final n = count < _maxDisplays ? count : _maxDisplays;
    return [
      for (var i = 0; i < n; i++)
        DisplayInfo(
          id: _displayBuffer[i * 7].toInt(),
          bounds: Rect.fromLTWH(
            _displayBuffer[i * 7 + 1],
            _displayBuffer[i * 7 + 2],
            _displayBuffer[i * 7 + 3],
            _displayBuffer[i * 7 + 4],
          ),
          scaleFactor: _displayBuffer[i * 7 + 5],
          isPrimary: _displayBuffer[i * 7 + 6] != 0,
        ),
    ];
  }

  @override
  int displayGeneration() => _generation();

  @override
  MacosWindowInfo? windowInfo(int windowId) {
    final b = _windowBuffer;
    final count = _window(windowId, b, _maxAbove);
    if (count < 0) return null;
    return MacosWindowInfo(
      bounds: Rect.fromLTWH(b[0], b[1], b[2], b[3]),
      onScreen: b[4] != 0,
      ownerPid: b[5].toInt(),
      scale: b[6],
      above: _records(b + 7, count),
    );
  }

  @override
  List<MacosWindowRecord>? onScreenWindows() {
    final b = _windowBuffer;
    final count = _windowList(b, _maxAbove);
    if (count < 0) return null;
    return _records(b, count);
  }

  /// [count] window records of 7 doubles each at [b].
  static List<MacosWindowRecord> _records(Pointer<Double> b, int count) => [
    for (var i = 0; i < count; i++)
      MacosWindowRecord(
        ownerPid: b[i * 7].toInt(),
        layer: b[i * 7 + 1].toInt(),
        alpha: b[i * 7 + 2],
        bounds: Rect.fromLTWH(
          b[i * 7 + 3],
          b[i * 7 + 4],
          b[i * 7 + 5],
          b[i * 7 + 6],
        ),
      ),
  ];

  @override
  int get ownPid => pid;

  @override
  List<int> keyboardPanelPids() {
    final count = _panels(_pidBuffer, _maxPanelPids);
    final n = count < _maxPanelPids ? count : _maxPanelPids;
    return [for (var i = 0; i < n; i++) _pidBuffer[i]];
  }

  @override
  int frontmostPid() => _frontmost();

  @override
  bool secureInput() => _secure() != 0;

  @override
  int sessionState() => _session();

  @override
  MacosActivitySnapshot activitySnapshot() {
    final b = _small;
    _snapshot(b);
    return MacosActivitySnapshot(
      hid: MacosActivityCounts(
        keyDowns: b[0].toInt(),
        flagsChanged: b[1].toInt(),
        buttonDowns: b[2].toInt(),
        scrolls: b[3].toInt(),
        moves: b[4].toInt(),
      ),
      pointer: Offset(b[5], b[6]),
      own: MacosActivityCounts(
        keyDowns: b[7].toInt(),
        flagsChanged: b[8].toInt(),
        buttonDowns: b[9].toInt(),
        scrolls: b[10].toInt(),
        moves: b[11].toInt(),
      ),
    );
  }
}
