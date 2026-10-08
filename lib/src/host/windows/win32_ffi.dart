// The package's own minimal Win32 bindings (`docs/design.md` §7.2, open
// question 8): about thirty functions, rather than a dependency on the
// `win32` package. Signatures follow the Windows SDK headers for 64-bit
// Windows (x64 and arm64, the only targets Flutter builds): handles are
// pointer-sized (IntPtr), BOOL/LONG/int are Int32, UINT/DWORD are Uint32.
//
// This is the only file in the package that imports dart:ffi. It's reached
// only through platform_ffi.dart's conditional export, so web builds never
// see it.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'input_records.dart' show inputRecordSize;
import 'win32_api.dart';

// --- Constants (winuser.h, winnt.h, dwmapi.h) --------------------------------

const int _smXVirtualScreen = 76;
const int _smYVirtualScreen = 77;
const int _smCxVirtualScreen = 78;
const int _smCyVirtualScreen = 79;
const int _spiGetWheelScrollLines = 0x0068;
const int _spiGetWheelScrollChars = 0x006C;
const int _perMonitorAwareV2 = -4; // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
const int _monitorInfoFPrimary = 0x0001;
const int _monitorInfoExSize = 104; // sizeof(MONITORINFOEXW)
const int _gaRoot = 2;
const int _gwOwner = 4;
const int _gwlStyle = -16;
const int _gwlExStyle = -20;
const int _classNameUnits = 256; // Class names are at most 256 characters.
const int _dwmwaExtendedFrameBounds = 9;
const int _dwmwaCloaked = 14;
const int _desktopReadObjects = 0x0001;
const int _uoiName = 2;
const int _desktopNameUnits = 64; // Desktop names are short: "Default".

const int _processQueryLimitedInformation = 0x1000;
const int _tokenQuery = 0x0008;
const int _tokenIntegrityLevel = 25; // TOKEN_INFORMATION_CLASS
const int _labelBufferSize = 128; // TOKEN_MANDATORY_LABEL and its SID

/// `POINT`, passed by value to `WindowFromPoint`.
final class _Point extends Struct {
  @Int32()
  external int x;

  @Int32()
  external int y;
}

// --- Signatures ---------------------------------------------------------------

typedef _MonitorEnumProc = Int32 Function(
  IntPtr monitor,
  IntPtr hdc,
  Pointer<Void> rect,
  IntPtr data,
);

/// The [Win32Api] over `dart:ffi`: user32, kernel32, advapi32 and dwmapi,
/// and the plugin DLL for `SendInput` and the activity hooks.
final class FfiWin32Api implements Win32Api, NativeActivity {
  FfiWin32Api._(DynamicLibrary plugin)
    : _sendInput = plugin
          .lookupFunction<
            Uint32 Function(Uint32, Pointer<Uint8>, Int32, Pointer<Uint32>),
            int Function(int, Pointer<Uint8>, int, Pointer<Uint32>)
          >('remote_input_send_input'),
      _activityStart = plugin.lookupFunction<Int32 Function(), int Function()>(
        'remote_input_activity_start',
      ),
      _activityStop = plugin.lookupFunction<Void Function(), void Function()>(
        'remote_input_activity_stop',
      ),
      _activityCount = plugin.lookupFunction<Uint64 Function(), int Function()>(
        'remote_input_activity_count',
        isLeaf: true,
      ),
      _activityHooksInstalled = plugin
          .lookupFunction<Int32 Function(), int Function()>(
            'remote_input_activity_hooks_installed',
            isLeaf: true,
          ),
      _activityHeartbeatAge = plugin
          .lookupFunction<Int64 Function(), int Function()>(
            'remote_input_activity_heartbeat_age',
            isLeaf: true,
          ),
      _activityReasonCount = plugin
          .lookupFunction<Uint64 Function(Int32), int Function(int)>(
            'remote_input_activity_reason_count',
            isLeaf: true,
          ),
      _activityLongestGap = plugin
          .lookupFunction<Uint64 Function(), int Function()>(
            'remote_input_activity_longest_gap',
            isLeaf: true,
          ),
      injectionTag = plugin
          .lookupFunction<Uint64 Function(), int Function()>('remote_input_tag')
          .call() {
    final user32 = DynamicLibrary.open('user32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final advapi32 = DynamicLibrary.open('advapi32.dll');
    final dwmapi = DynamicLibrary.open('dwmapi.dll');

    _getSystemMetrics = user32
        .lookupFunction<Int32 Function(Int32), int Function(int)>(
          'GetSystemMetrics',
        );
    _systemParametersInfo = user32
        .lookupFunction<
          Int32 Function(Uint32, Uint32, Pointer<Void>, Uint32),
          int Function(int, int, Pointer<Void>, int)
        >('SystemParametersInfoW');
    _setCursorPos = user32
        .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
          'SetCursorPos',
        );
    _getThreadDpiAwarenessContext = user32
        .lookupFunction<IntPtr Function(), int Function()>(
          'GetThreadDpiAwarenessContext',
        );
    _areDpiAwarenessContextsEqual = user32
        .lookupFunction<Int32 Function(IntPtr, IntPtr), int Function(int, int)>(
          'AreDpiAwarenessContextsEqual',
        );
    _enumDisplayMonitors = user32
        .lookupFunction<
          Int32 Function(
            IntPtr,
            Pointer<Void>,
            Pointer<NativeFunction<_MonitorEnumProc>>,
            IntPtr,
          ),
          int Function(
            int,
            Pointer<Void>,
            Pointer<NativeFunction<_MonitorEnumProc>>,
            int,
          )
        >('EnumDisplayMonitors');
    _getMonitorInfo = user32
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<Uint8>),
          int Function(int, Pointer<Uint8>)
        >('GetMonitorInfoW');
    _isWindow = user32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindow');
    _isIconic = user32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsIconic');
    _isWindowVisible = user32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'IsWindowVisible',
        );
    _getWindowRect = user32
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<Int32>),
          int Function(int, Pointer<Int32>)
        >('GetWindowRect');
    _windowFromPoint = user32
        .lookupFunction<IntPtr Function(_Point), int Function(_Point)>(
          'WindowFromPoint',
        );
    _getAncestor = user32
        .lookupFunction<
          IntPtr Function(IntPtr, Uint32),
          int Function(int, int)
        >('GetAncestor');
    _getWindow = user32
        .lookupFunction<
          IntPtr Function(IntPtr, Uint32),
          int Function(int, int)
        >('GetWindow');
    _getWindowLongPtr = user32
        .lookupFunction<IntPtr Function(IntPtr, Int32), int Function(int, int)>(
          'GetWindowLongPtrW',
        );
    _getClassName = user32
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<Uint16>, Int32),
          int Function(int, Pointer<Uint16>, int)
        >('GetClassNameW');
    _getForegroundWindow = user32
        .lookupFunction<IntPtr Function(), int Function()>(
          'GetForegroundWindow',
        );
    _getWindowThreadProcessId = user32
        .lookupFunction<
          Uint32 Function(IntPtr, Pointer<Uint32>),
          int Function(int, Pointer<Uint32>)
        >('GetWindowThreadProcessId');
    _openInputDesktop = user32
        .lookupFunction<
          IntPtr Function(Uint32, Int32, Uint32),
          int Function(int, int, int)
        >('OpenInputDesktop');
    _getUserObjectInformation = user32
        .lookupFunction<
          Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>),
          int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)
        >('GetUserObjectInformationW');
    _closeDesktop = user32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'CloseDesktop',
        );
    _dwmGetWindowAttribute = dwmapi
        .lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32),
          int Function(int, int, Pointer<Void>, int)
        >('DwmGetWindowAttribute');
    currentProcessId = kernel32
        .lookupFunction<Uint32 Function(), int Function()>(
          'GetCurrentProcessId',
        )
        .call();
    _getCurrentProcess = kernel32
        .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
    _openProcess = kernel32
        .lookupFunction<
          IntPtr Function(Uint32, Int32, Uint32),
          int Function(int, int, int)
        >('OpenProcess');
    _closeHandle = kernel32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'CloseHandle',
        );
    _openProcessToken = advapi32
        .lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<IntPtr>),
          int Function(int, int, Pointer<IntPtr>)
        >('OpenProcessToken');
    _getTokenInformation = advapi32
        .lookupFunction<
          Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>),
          int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)
        >('GetTokenInformation');
  }

  /// Opens the plugin DLL (`remote_input_plugin.dll`, loaded with the app)
  /// and the system DLLs, or returns `null` if any is missing or the
  /// native `INPUT` layout isn't the one `input_records.dart` writes.
  ///
  /// Without the plugin DLL there are no activity hooks, and the package
  /// doesn't inject without local input winning (`docs/design.md` §6.3).
  static FfiWin32Api? open() {
    try {
      final plugin = DynamicLibrary.open('remote_input_plugin.dll');
      final inputSize = plugin
          .lookupFunction<Int32 Function(), int Function()>(
            'remote_input_input_size',
          )
          .call();
      if (inputSize != inputRecordSize) return null;
      return FfiWin32Api._(plugin);
    } on Object {
      return null;
    }
  }

  // Plugin DLL.
  final int Function(int, Pointer<Uint8>, int, Pointer<Uint32>) _sendInput;
  final int Function() _activityStart;
  final void Function() _activityStop;
  final int Function() _activityCount;
  final int Function() _activityHooksInstalled;
  final int Function() _activityHeartbeatAge;
  final int Function(int) _activityReasonCount;
  final int Function() _activityLongestGap;

  // user32, kernel32, advapi32, dwmapi.
  late final int Function(int) _getSystemMetrics;
  late final int Function(int, int, Pointer<Void>, int) _systemParametersInfo;
  late final int Function(int, int) _setCursorPos;
  late final int Function() _getThreadDpiAwarenessContext;
  late final int Function(int, int) _areDpiAwarenessContextsEqual;
  late final int Function(
    int,
    Pointer<Void>,
    Pointer<NativeFunction<_MonitorEnumProc>>,
    int,
  )
  _enumDisplayMonitors;
  late final int Function(int, Pointer<Uint8>) _getMonitorInfo;
  late final int Function(int) _isWindow;
  late final int Function(int) _isIconic;
  late final int Function(int) _isWindowVisible;
  late final int Function(int, Pointer<Int32>) _getWindowRect;
  late final int Function(_Point) _windowFromPoint;
  late final int Function(int, int) _getAncestor;
  late final int Function() _getForegroundWindow;
  late final int Function(int, int) _getWindow;
  late final int Function(int, int) _getWindowLongPtr;
  late final int Function(int, Pointer<Uint16>, int) _getClassName;
  late final int Function(int, Pointer<Uint32>) _getWindowThreadProcessId;
  late final int Function(int, int, int) _openInputDesktop;
  late final int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)
  _getUserObjectInformation;
  late final int Function(int) _closeDesktop;
  late final int Function(int, int, Pointer<Void>, int) _dwmGetWindowAttribute;
  late final int Function() _getCurrentProcess;
  late final int Function(int, int, int) _openProcess;
  late final int Function(int) _closeHandle;
  late final int Function(int, int, Pointer<IntPtr>) _openProcessToken;
  late final int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)
  _getTokenInformation;

  /// Scratch memory, reused: calls are synchronous on one isolate.
  final Pointer<Uint32> _error = calloc<Uint32>();
  final Pointer<Int32> _rect = calloc<Int32>(4);
  final Pointer<Uint32> _dword = calloc<Uint32>();
  final Pointer<_Point> _point = calloc<_Point>();
  final Pointer<Uint8> _monitorInfo = calloc<Uint8>(_monitorInfoExSize);
  final Pointer<Uint16> _desktopName = calloc<Uint16>(_desktopNameUnits);
  final Pointer<Uint16> _className = calloc<Uint16>(_classNameUnits);
  Pointer<Uint8> _inputs = nullptr;
  int _inputsCapacity = 0;

  @override
  final int injectionTag;

  @override
  late final int currentProcessId;

  // --- Input ----------------------------------------------------------------

  @override
  SendInputResult sendInput(Uint8List inputs) {
    if (inputs.isEmpty) return (sent: 0, error: 0);
    if (inputs.length > _inputsCapacity) {
      if (_inputs != nullptr) calloc.free(_inputs);
      _inputsCapacity = inputs.length * 2;
      _inputs = calloc<Uint8>(_inputsCapacity);
    }
    final native = _inputs.asTypedList(inputs.length)..setAll(0, inputs);
    final count = inputs.length ~/ inputRecordSize;
    final sent = _sendInput(count, _inputs, inputRecordSize, _error);
    // The records may carry typed text and key codes: don't leave them in
    // native memory until the next call overwrites them (§6.6).
    native.fillRange(0, inputs.length, 0);
    return (sent: sent, error: _error.value);
  }

  @override
  bool setCursorPos(int x, int y) => _setCursorPos(x, y) != 0;

  @override
  WinRect virtualScreen() {
    final left = _getSystemMetrics(_smXVirtualScreen);
    final top = _getSystemMetrics(_smYVirtualScreen);
    return (
      left: left,
      top: top,
      right: left + _getSystemMetrics(_smCxVirtualScreen),
      bottom: top + _getSystemMetrics(_smCyVirtualScreen),
    );
  }

  @override
  int wheelScrollLines() => _spi(_spiGetWheelScrollLines);

  @override
  int wheelScrollChars() => _spi(_spiGetWheelScrollChars);

  int _spi(int action) {
    _dword.value = 0;
    if (_systemParametersInfo(action, 0, _dword.cast(), 0) == 0) return 0;
    return _dword.value;
  }

  @override
  bool isPerMonitorAwareV2() =>
      _areDpiAwarenessContextsEqual(
        _getThreadDpiAwarenessContext(),
        _perMonitorAwareV2,
      ) !=
      0;

  // --- Monitors -------------------------------------------------------------

  @override
  List<WinMonitor> monitors() {
    _enumerated.clear();
    _enumDisplayMonitors(0, nullptr, _monitorEnumProc, 0);
    final handles = List.of(_enumerated);
    _enumerated.clear();
    return [for (final h in handles) ?monitor(h)];
  }

  @override
  WinMonitor? monitor(int handle) {
    final bytes = _monitorInfo.asTypedList(_monitorInfoExSize)
      ..fillRange(0, _monitorInfoExSize, 0);
    final data = ByteData.sublistView(bytes)
      ..setUint32(0, _monitorInfoExSize, Endian.little);
    if (_getMonitorInfo(handle, _monitorInfo) == 0) return null;
    WinRect rect(int o) => (
      left: data.getInt32(o, Endian.little),
      top: data.getInt32(o + 4, Endian.little),
      right: data.getInt32(o + 8, Endian.little),
      bottom: data.getInt32(o + 12, Endian.little),
    );
    return WinMonitor(
      handle: handle,
      bounds: rect(4), // rcMonitor; rcWork is at 20.
      isPrimary: data.getUint32(36, Endian.little) & _monitorInfoFPrimary != 0,
      deviceName: (_monitorInfo + 40).cast<Utf16>().toDartString(),
    );
  }

  // --- Windows --------------------------------------------------------------

  @override
  bool isWindow(int hwnd) => _isWindow(hwnd) != 0;

  @override
  bool isIconic(int hwnd) => _isIconic(hwnd) != 0;

  @override
  bool isWindowVisible(int hwnd) => _isWindowVisible(hwnd) != 0;

  @override
  bool isCloaked(int hwnd) {
    _dword.value = 0;
    final hr = _dwmGetWindowAttribute(hwnd, _dwmwaCloaked, _dword.cast(), 4);
    return hr == 0 && _dword.value != 0;
  }

  @override
  WinRect? windowBounds(int hwnd) {
    final ok =
        _dwmGetWindowAttribute(
              hwnd,
              _dwmwaExtendedFrameBounds,
              _rect.cast(),
              16,
            ) ==
            0 ||
        _getWindowRect(hwnd, _rect) != 0;
    if (!ok) return null;
    return (left: _rect[0], top: _rect[1], right: _rect[2], bottom: _rect[3]);
  }

  @override
  int windowFromPoint(int x, int y) {
    _point.ref
      ..x = x
      ..y = y;
    return _windowFromPoint(_point.ref);
  }

  @override
  int rootWindow(int hwnd) => _getAncestor(hwnd, _gaRoot);

  @override
  int foregroundWindow() => _getForegroundWindow();

  @override
  int processIdOfWindow(int hwnd) {
    _dword.value = 0;
    if (_getWindowThreadProcessId(hwnd, _dword) == 0) return 0;
    return _dword.value;
  }

  @override
  int threadIdOfWindow(int hwnd) => _getWindowThreadProcessId(hwnd, nullptr);

  @override
  int ownerWindow(int hwnd) => _getWindow(hwnd, _gwOwner);

  @override
  int windowStyle(int hwnd) => _getWindowLongPtr(hwnd, _gwlStyle) & 0xFFFFFFFF;

  @override
  int windowExStyle(int hwnd) =>
      _getWindowLongPtr(hwnd, _gwlExStyle) & 0xFFFFFFFF;

  @override
  String windowClassName(int hwnd) {
    final n = _getClassName(hwnd, _className, _classNameUnits);
    if (n <= 0) return '';
    return _className.cast<Utf16>().toDartString(length: n);
  }

  // --- Secure contexts ------------------------------------------------------

  @override
  bool isInputDesktopDefault() {
    final desktop = _openInputDesktop(0, 0, _desktopReadObjects);
    if (desktop == 0) return false;
    try {
      _desktopName[0] = 0;
      final ok = _getUserObjectInformation(
        desktop,
        _uoiName,
        _desktopName.cast(),
        _desktopNameUnits * 2,
        _dword,
      );
      return ok != 0 &&
          _desktopName.cast<Utf16>().toDartString().toLowerCase() == 'default';
    } finally {
      _closeDesktop(desktop);
    }
  }

  @override
  int? integrityLevel(int pid) {
    final process = _openProcess(_processQueryLimitedInformation, 0, pid);
    if (process == 0) return null;
    try {
      return _tokenIntegrity(process);
    } finally {
      _closeHandle(process);
    }
  }

  @override
  late final int? ownIntegrityLevel = _tokenIntegrity(_getCurrentProcess());

  int? _tokenIntegrity(int process) {
    final token = calloc<IntPtr>();
    final label = calloc<Uint8>(_labelBufferSize);
    try {
      if (_openProcessToken(process, _tokenQuery, token) == 0) return null;
      try {
        if (_getTokenInformation(
              token.value,
              _tokenIntegrityLevel,
              label.cast(),
              _labelBufferSize,
              _dword,
            ) ==
            0) {
          return null;
        }
        // TOKEN_MANDATORY_LABEL.Label.Sid: a pointer into the same buffer.
        final sid = Pointer<Uint8>.fromAddress(label.cast<IntPtr>().value);
        final end = label.address + _labelBufferSize;
        if (sid.address < label.address || sid.address + 8 > end) return null;
        final length = 8 + 4 * sid[1];
        if (sid.address + length > end) return null;
        return lastSubAuthority(Uint8List.fromList(sid.asTypedList(length)));
      } finally {
        _closeHandle(token.value);
      }
    } finally {
      calloc
        ..free(token)
        ..free(label);
    }
  }

  // --- NativeActivity -------------------------------------------------------

  @override
  bool start() => _activityStart() != 0;

  @override
  void stop() => _activityStop();

  @override
  int count() => _activityCount();

  @override
  bool hooksInstalled() => _activityHooksInstalled() != 0;

  @override
  int heartbeatAgeMs() => _activityHeartbeatAge();

  @override
  int reasonCount(NativeActivityReason reason) =>
      _activityReasonCount(reason.index);

  @override
  int longestGapMs() => _activityLongestGap();
}

/// Monitors found by the running `EnumDisplayMonitors` call. The callback
/// runs synchronously on the calling thread, inside that call.
final List<int> _enumerated = [];

int _onMonitor(int monitor, int hdc, Pointer<Void> rect, int data) {
  _enumerated.add(monitor);
  return 1;
}

final Pointer<NativeFunction<_MonitorEnumProc>> _monitorEnumProc =
    Pointer.fromFunction<_MonitorEnumProc>(_onMonitor, 0);
