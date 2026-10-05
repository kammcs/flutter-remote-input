// Windows injection, end to end on a real desktop (roadmap M2,
// docs/design.md §12): a viewer and a host in this app, joined by a
// MemoryInputLink, with the host's surface the app's own window. It injects
// only into that window: the pointer stays inside its client area, and keys
// and text go to it while it's in front.
//
// Run on Windows, with the machine otherwise idle (it moves the real
// pointer and types real keys), from example/:
//
//   flutter test integration_test/windows_injection_test.dart -d windows
//
// Skipped on every other platform.
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:remote_input/remote_input.dart';
// The test reaches into the package for its INPUT records (to post input
// that isn't tagged, as a person's would be) and for the fallback pointer
// placement.
// ignore: implementation_imports
import 'package:remote_input/src/host/windows/input_records.dart';
// ignore: implementation_imports
import 'package:remote_input/src/host/windows/windows_injector.dart'
    show PointerPlacement;
// ignore: implementation_imports
import 'package:remote_input/src/host/windows/windows_platform.dart'
    show createWindowsHostPlatform;
import 'package:remote_input/testing.dart' show MemoryInputLink;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final skip = !Platform.isWindows;

  late _Win32 win32;
  late _Harness h;

  setUp(() {
    if (skip) return;
    win32 = _Win32();
    // Real pointer events from the OS reach the widgets.
    binding.shouldPropagateDevicePointerEvents = true;
  });

  Future<void> start(
    WidgetTester tester, {
    PointerPlacement placement = PointerPlacement.absolute,
  }) async {
    h = _Harness();
    await tester.pumpWidget(h.build());
    await _settle(tester, 300);
    final hwnd = win32.ownWindow();
    expect(hwnd, isNot(0), reason: "the test app's own window");
    win32.setForeground(hwnd);
    await _settle(tester);
    h.geometry = win32.geometry(hwnd);
    h.dpr = tester.view.devicePixelRatio;

    final platform = placement == PointerPlacement.absolute
        ? null
        : createWindowsHostPlatform(placement: placement);
    final host = RemoteInputHost(platform: platform);
    expect(host.checkAvailable(), isNull);
    final pair = MemoryInputLink.pair();
    h.session = host.enable(
      link: pair.host,
      surface: SharedSurface.window(
        hwnd,
        contentInsets: h.geometry.clientInsets,
      ),
      // The test injects into its own window, which the host otherwise
      // protects (HostOptions.protectHostWindows).
      options: const HostOptions(protectHostWindows: false),
    );
    h.viewer = RemoteInputViewer(link: pair.viewer);
    final active = await _waitFor(
      tester,
      () => h.session.state is SessionActive && h.viewer.surface != null,
    );
    expect(active, isTrue, reason: 'the handshake finishes');
    addTearDown(() async {
      h.session.stop();
      await h.viewer.close();
      HardwareKeyboard.instance.removeHandler(h.onKey);
    });
  }

  // Normalized points: the client area's corners and centre.
  const points = [
    Offset(0, 0),
    Offset(1, 0),
    Offset(0, 1),
    Offset(1, 1),
    Offset(0.5, 0.5),
  ];

  Future<void> checkMoves(WidgetTester tester) async {
    for (final p in points) {
      final want = h.expectedPixel(p);
      h.viewer.pointerMove(p);
      final moved = await _waitFor(tester, () {
        final last = h.lastPointer;
        return last != null &&
            (last.position - h.logical(want)).distance < 0.01;
      });
      expect(moved, isTrue, reason: 'Flutter sees the pointer at $p');
      expect(win32.cursorPos(), want, reason: 'GetCursorPos at $p');
    }
  }

  testWidgets('absolute moves land on the exact pixel', (tester) async {
    await start(tester);
    await checkMoves(tester);
    expect(h.session.state, const SessionActive());
  }, skip: skip);

  testWidgets('setCursorPos moves land on the exact pixel', (tester) async {
    await start(tester, placement: PointerPlacement.setCursorPos);
    await checkMoves(tester);
    // Its own SetCursorPos mustn't count as local input.
    expect(h.session.state, const SessionActive());
  }, skip: skip);

  testWidgets('buttons, including back and forward', (tester) async {
    await start(tester);
    const centre = Offset(0.5, 0.5);
    final want = h.logical(h.expectedPixel(centre));
    for (final (button, flutterButton) in [
      (PointerButton.left, kPrimaryButton),
      (PointerButton.right, kSecondaryButton),
      (PointerButton.middle, kMiddleMouseButton),
      (PointerButton.back, kBackMouseButton),
      (PointerButton.forward, kForwardMouseButton),
    ]) {
      h.downs.clear();
      h.ups = 0;
      h.viewer.click(centre, button: button);
      final clicked = await _waitFor(tester, () => h.ups > 0);
      expect(clicked, isTrue, reason: '$button released');
      expect(h.downs.single.buttons, flutterButton, reason: '$button');
      expect((h.downs.single.position - want).distance, lessThan(0.01));
    }
    expect(h.session.state, const SessionActive());
  }, skip: skip);

  testWidgets('wheel, both axes', (tester) async {
    await start(tester);
    const centre = Offset(0.5, 0.5);
    h.viewer.wheel(centre, dy: 3, unit: WheelUnit.line);
    expect(await _waitFor(tester, () => h.scrolls.isNotEmpty), isTrue);
    // Positive wire dy reveals what's below: Flutter's positive dy.
    expect(h.scrolls.last.scrollDelta.dy, greaterThan(0));
    h.scrolls.clear();
    h.viewer.wheel(centre, dx: -3, unit: WheelUnit.line);
    expect(await _waitFor(tester, () => h.scrolls.isNotEmpty), isTrue);
    expect(h.scrolls.last.scrollDelta.dx, lessThan(0));
    h.scrolls.clear();
    h.viewer.wheel(centre, dy: 100);
    expect(await _waitFor(tester, () => h.scrolls.isNotEmpty), isTrue);
    expect(h.scrolls.last.scrollDelta.dy, greaterThan(0));
  }, skip: skip);

  testWidgets('physical keys, extended keys and text', (tester) async {
    await start(tester);
    HardwareKeyboard.instance.addHandler(h.onKey);
    for (final key in [
      PhysicalKeyboardKey.keyA,
      PhysicalKeyboardKey.arrowUp, // E0-extended
      PhysicalKeyboardKey.controlRight, // E0-extended
      PhysicalKeyboardKey.f5,
    ]) {
      h.keys.clear();
      h.viewer
        ..key(key.usbHidUsage, KeyAction.down)
        ..key(key.usbHidUsage, KeyAction.up);
      final seen = await _waitFor(
        tester,
        () => h.keys.whereType<KeyUpEvent>().isNotEmpty,
      );
      expect(seen, isTrue, reason: '${key.debugName}');
      expect(h.keys.first, isA<KeyDownEvent>());
      expect(h.keys.first.physicalKey, key, reason: '${key.debugName}');
    }

    h.textFocus.requestFocus();
    await _settle(tester);
    const text = 'héllo wörld 👋 ½';
    h.viewer.text(text);
    final typed = await _waitFor(tester, () => h.text.text == text);
    expect(typed, isTrue, reason: 'the text field has the text');
    expect(h.session.state, const SessionActive());
  }, skip: skip);

  testWidgets('local input pauses the session within 50 ms', (tester) async {
    await start(tester);
    // Untagged input, as a person's keyboard would post it: Shift, which
    // types nothing.
    final watch = Stopwatch()..start();
    win32.sendUntagged([
      const KeyRecord(scan: 0x2A, flags: Win32Input.keyScanCode, extraInfo: 0),
      const KeyRecord(
        scan: 0x2A,
        flags: Win32Input.keyScanCode | Win32Input.keyUp,
        extraInfo: 0,
      ),
    ]);
    final paused = await _waitFor(
      tester,
      () => h.session.state == const SessionPaused(PauseReason.localInput),
      step: const Duration(milliseconds: 1),
    );
    watch.stop();
    expect(paused, isTrue);
    // A timing, not content: fine to print (docs/design.md §6.6).
    debugPrint('Paused ${watch.elapsedMilliseconds} ms after local input');
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 100)));

    // A small untagged movement (under 4 pixels) doesn't count.
    h.session.resume();
    await _settle(tester);
    expect(h.session.state, const SessionActive());
    win32.sendUntagged([
      const MouseRecord(
        dx: 1,
        dy: 1,
        flags: Win32Input.mouseMove,
        extraInfo: 0,
      ),
    ]);
    await _settle(tester, 100);
    expect(h.session.state, const SessionActive());
  }, skip: skip);
}

/// Waits until [condition] holds, pumping frames, for up to [timeout].
Future<bool> _waitFor(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
  Duration step = const Duration(milliseconds: 10),
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) return false;
    await Future<void>.delayed(step);
    await tester.pump();
  }
  return true;
}

Future<void> _settle(WidgetTester tester, [int ms = 150]) async {
  await Future<void>.delayed(Duration(milliseconds: ms));
  await tester.pump();
}

/// The test app, and what it received.
final class _Harness {
  late ControlSession session;
  late RemoteInputViewer viewer;
  late _Geometry geometry;
  late double dpr;

  final TextEditingController text = TextEditingController();
  final FocusNode textFocus = FocusNode();
  final List<PointerDownEvent> downs = [];
  final List<PointerScrollEvent> scrolls = [];
  final List<KeyEvent> keys = [];
  PointerEvent? lastPointer;
  int ups = 0;

  bool onKey(KeyEvent event) {
    keys.add(event);
    return false;
  }

  Widget build() => MaterialApp(
    home: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerHover: (e) => lastPointer = e,
      onPointerMove: (e) => lastPointer = e,
      onPointerDown: (e) {
        lastPointer = e;
        downs.add(e);
      },
      onPointerUp: (e) => ups++,
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) scrolls.add(e);
      },
      child: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            child: TextField(controller: text, focusNode: textFocus),
          ),
        ),
      ),
    ),
  );

  /// The desktop pixel the host puts normalized [p] on: the wire value's
  /// step centre on the client area, floored (`docs/design.md` §3.2).
  (int, int) expectedPixel(Offset p) {
    int wire(double v) => (v * 65536).floor().clamp(0, 65535);
    int px(int w, int start, int extent) =>
        (start + (w + 0.5) * extent / 65536).floor();
    final c = geometry.client;
    return (
      px(wire(p.dx), c.left, c.right - c.left),
      px(wire(p.dy), c.top, c.bottom - c.top),
    );
  }

  /// Where Flutter reports desktop pixel [px], in logical pixels.
  Offset logical((int, int) px) => Offset(
    (px.$1 - geometry.client.left) / dpr,
    (px.$2 - geometry.client.top) / dpr,
  );
}

typedef _Rect = ({int left, int top, int right, int bottom});

final class _Geometry {
  _Geometry(this.frame, this.client);

  /// `DWMWA_EXTENDED_FRAME_BOUNDS`: the surface's bounds.
  final _Rect frame;

  /// The client area, where Flutter draws, in desktop pixels.
  final _Rect client;

  EdgeInsets get clientInsets => EdgeInsets.fromLTRB(
    (client.left - frame.left).toDouble(),
    (client.top - frame.top).toDouble(),
    (frame.right - client.right).toDouble(),
    (frame.bottom - client.bottom).toDouble(),
  );
}

/// The few Win32 calls the test makes itself.
final class _Win32 {
  _Win32() {
    final user32 = DynamicLibrary.open('user32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final dwmapi = DynamicLibrary.open('dwmapi.dll');
    _findWindowEx = user32
        .lookupFunction<
          IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
          int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
        >('FindWindowExW');
    _getWindowThreadProcessId = user32
        .lookupFunction<
          Uint32 Function(IntPtr, Pointer<Uint32>),
          int Function(int, Pointer<Uint32>)
        >('GetWindowThreadProcessId');
    _setForegroundWindow = user32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'SetForegroundWindow',
        );
    _clientToScreen = user32
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<Int32>),
          int Function(int, Pointer<Int32>)
        >('ClientToScreen');
    _getClientRect = user32
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<Int32>),
          int Function(int, Pointer<Int32>)
        >('GetClientRect');
    _getCursorPos = user32
        .lookupFunction<
          Int32 Function(Pointer<Int32>),
          int Function(Pointer<Int32>)
        >('GetCursorPos');
    _sendInput = user32
        .lookupFunction<
          Uint32 Function(Uint32, Pointer<Uint8>, Int32),
          int Function(int, Pointer<Uint8>, int)
        >('SendInput');
    _getCurrentProcessId = kernel32
        .lookupFunction<Uint32 Function(), int Function()>(
          'GetCurrentProcessId',
        );
    _dwmGetWindowAttribute = dwmapi
        .lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32),
          int Function(int, int, Pointer<Void>, int)
        >('DwmGetWindowAttribute');
  }

  late final int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
  _findWindowEx;
  late final int Function(int, Pointer<Uint32>) _getWindowThreadProcessId;
  late final int Function(int) _setForegroundWindow;
  late final int Function(int, Pointer<Int32>) _clientToScreen;
  late final int Function(int, Pointer<Int32>) _getClientRect;
  late final int Function(Pointer<Int32>) _getCursorPos;
  late final int Function(int, Pointer<Uint8>, int) _sendInput;
  late final int Function() _getCurrentProcessId;
  late final int Function(int, int, Pointer<Void>, int) _dwmGetWindowAttribute;

  /// This process's runner window.
  int ownWindow() {
    final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final pid = calloc<Uint32>();
    try {
      var hwnd = 0;
      while (true) {
        hwnd = _findWindowEx(0, hwnd, cls, nullptr);
        if (hwnd == 0) return 0;
        _getWindowThreadProcessId(hwnd, pid);
        if (pid.value == _getCurrentProcessId()) return hwnd;
      }
    } finally {
      calloc
        ..free(cls)
        ..free(pid);
    }
  }

  void setForeground(int hwnd) => _setForegroundWindow(hwnd);

  _Geometry geometry(int hwnd) {
    final r = calloc<Int32>(4);
    try {
      expect(_dwmGetWindowAttribute(hwnd, 9, r.cast(), 16), 0);
      final frame = (left: r[0], top: r[1], right: r[2], bottom: r[3]);
      expect(_getClientRect(hwnd, r), isNot(0));
      final width = r[2];
      final height = r[3];
      r[0] = 0;
      r[1] = 0;
      expect(_clientToScreen(hwnd, r), isNot(0));
      final client = (
        left: r[0],
        top: r[1],
        right: r[0] + width,
        bottom: r[1] + height,
      );
      return _Geometry(frame, client);
    } finally {
      calloc.free(r);
    }
  }

  (int, int) cursorPos() {
    final p = calloc<Int32>(2);
    try {
      _getCursorPos(p);
      return (p[0], p[1]);
    } finally {
      calloc.free(p);
    }
  }

  /// Posts [records] without the package's tag, as other software would.
  void sendUntagged(List<InputRecord> records) {
    final bytes = encodeInputRecords(records);
    final p = calloc<Uint8>(bytes.length);
    try {
      p.asTypedList(bytes.length).setAll(0, bytes);
      expect(_sendInput(records.length, p, inputRecordSize), records.length);
    } finally {
      calloc.free(p);
    }
  }
}
