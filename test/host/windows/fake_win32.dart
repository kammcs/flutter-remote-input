import 'dart:typed_data';

import 'package:remote_input/src/host/windows/input_records.dart';
import 'package:remote_input/src/host/windows/win32_api.dart';

const int testTag = 0x726D746900001234;

/// A [Win32Api] the test sets up, recording what would be sent.
final class FakeWin32Api implements Win32Api {
  @override
  int injectionTag = testTag;

  /// Each `SendInput` call's records, decoded.
  final List<List<InputRecord>> calls = [];

  /// The raw bytes of each call.
  final List<Uint8List> rawCalls = [];

  /// What `SendInput` returns: by default, everything inserted.
  SendInputResult Function(int count)? onSend;

  /// `SetCursorPos` calls.
  final List<(int, int)> cursorSets = [];

  WinRect screen = (left: 0, top: 0, right: 1920, bottom: 1080);
  int lines = 3;
  int chars = 3;
  bool perMonitorV2 = true;

  List<WinMonitor> monitorList = [
    const WinMonitor(
      handle: 0x10001,
      bounds: (left: 0, top: 0, right: 1920, bottom: 1080),
      isPrimary: true,
      deviceName: r'\\.\DISPLAY1',
    ),
  ];
  int monitorsCalls = 0;

  /// Windows by handle.
  final Map<int, FakeWindow> windows = {};
  int Function(int x, int y) hitTest = (_, _) => 0;
  int foreground = 0;

  @override
  int currentProcessId = 100;

  bool inputDesktopDefault = true;
  final Map<int, int?> integrity = {};
  final List<int> integrityQueries = [];

  @override
  int? ownIntegrityLevel = IntegrityLevel.medium;

  List<InputRecord> get records => [for (final c in calls) ...c];

  @override
  SendInputResult sendInput(Uint8List inputs) {
    rawCalls.add(Uint8List.fromList(inputs));
    calls.add(decodeInputRecords(inputs));
    final count = inputs.length ~/ inputRecordSize;
    return onSend?.call(count) ?? (sent: count, error: 0);
  }

  @override
  bool setCursorPos(int x, int y) {
    cursorSets.add((x, y));
    return true;
  }

  @override
  WinRect virtualScreen() => screen;

  @override
  int wheelScrollLines() => lines;

  @override
  int wheelScrollChars() => chars;

  @override
  bool isPerMonitorAwareV2() => perMonitorV2;

  @override
  List<WinMonitor> monitors() {
    monitorsCalls++;
    return List.of(monitorList);
  }

  @override
  WinMonitor? monitor(int handle) {
    for (final m in monitorList) {
      if (m.handle == handle) return m;
    }
    return null;
  }

  @override
  bool isWindow(int hwnd) => windows.containsKey(hwnd);

  @override
  bool isIconic(int hwnd) => windows[hwnd]?.iconic ?? false;

  @override
  bool isWindowVisible(int hwnd) => windows[hwnd]?.visible ?? false;

  @override
  bool isCloaked(int hwnd) => windows[hwnd]?.cloaked ?? false;

  @override
  WinRect? windowBounds(int hwnd) => windows[hwnd]?.bounds;

  @override
  int windowFromPoint(int x, int y) => hitTest(x, y);

  @override
  int rootWindow(int hwnd) => windows[hwnd]?.root ?? hwnd;

  @override
  int foregroundWindow() => foreground;

  @override
  int processIdOfWindow(int hwnd) => windows[hwnd]?.pid ?? 0;

  @override
  bool isInputDesktopDefault() => inputDesktopDefault;

  @override
  int? integrityLevel(int pid) {
    integrityQueries.add(pid);
    return integrity.containsKey(pid) ? integrity[pid] : IntegrityLevel.medium;
  }
}

final class FakeWindow {
  FakeWindow({
    required this.pid,
    this.bounds = (left: 100, top: 50, right: 900, bottom: 650),
    this.root,
    this.iconic = false,
    this.visible = true,
    this.cloaked = false,
  });

  int pid;
  WinRect? bounds;
  int? root;
  bool iconic;
  bool visible;
  bool cloaked;
}

final class FakeNativeActivity implements NativeActivity {
  int counter = 0;
  bool running = false;
  bool failStart = false;
  int starts = 0;
  int stops = 0;

  @override
  bool start() {
    starts++;
    if (failStart) return false;
    running = true;
    return true;
  }

  @override
  void stop() {
    stops++;
    running = false;
  }

  @override
  int count() => counter;
}

/// Decodes an array of `INPUT` records, as Windows would read it.
List<InputRecord> decodeInputRecords(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final out = <InputRecord>[];
  for (var o = 0; o < bytes.length; o += inputRecordSize) {
    final type = data.getUint32(o, Endian.little);
    final u = o + 8;
    // The padding after `type` must stay zero.
    if (data.getUint32(o + 4, Endian.little) != 0) {
      throw StateError('padding written');
    }
    switch (type) {
      case Win32Input.typeMouse:
        if (data.getUint32(u + 16, Endian.little) != 0) {
          throw StateError('time set');
        }
        out.add(
          MouseRecord(
            dx: data.getInt32(u, Endian.little),
            dy: data.getInt32(u + 4, Endian.little),
            mouseData: data.getInt32(u + 8, Endian.little),
            flags: data.getUint32(u + 12, Endian.little),
            extraInfo: data.getUint64(u + 24, Endian.little),
          ),
        );
      case Win32Input.typeKeyboard:
        if (data.getUint16(u, Endian.little) != 0) {
          throw StateError('wVk set');
        }
        if (data.getUint32(u + 8, Endian.little) != 0) {
          throw StateError('time set');
        }
        out.add(
          KeyRecord(
            scan: data.getUint16(u + 2, Endian.little),
            flags: data.getUint32(u + 4, Endian.little),
            extraInfo: data.getUint64(u + 16, Endian.little),
          ),
        );
      default:
        throw StateError('unknown INPUT type $type');
    }
  }
  return out;
}
