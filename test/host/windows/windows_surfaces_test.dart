import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/src/host/windows/win32_api.dart';
import 'package:remote_input/src/host/windows/windows_surfaces.dart';

import 'fake_win32.dart';

// The shared app: process 7, the shared window's thread 70.
const int _shared = 0x1000;
const int _sharedChild = 0x1001;
const int _dialog = 0x1003; // Owned by the shared window, another thread.
const int _dialogPopup = 0x1004; // Owned by the dialog.
const int _menu = 0x1005; // A #32768 menu of thread 70, unowned.
const int _dropDown = 0x1006; // An unowned tool popup of thread 70.
const int _sibling = 0x1007; // Another top-level window of thread 70.
const int _popupOnTaskbar = 0x1008; // Unowned WS_POPUP, no tool style.
const int _appWindowPopup = 0x1009; // Tool popup forced onto the taskbar.
const int _otherThreadMenu = 0x100A; // A menu of thread 72 (the taskbar's).
const int _otherThreadWindow = 0x100B; // The taskbar, the desktop.
const int _ownedBySibling = 0x100C; // A popup of thread 70's other window.
const int _crossProcessOwned = 0x100D; // Process 9, owned by the shared.
const int _cycleA = 0x100E; // Owns _cycleB, which owns it.
const int _cycleB = 0x100F;
const int _other = 0x2000;
// The host app itself: FakeWin32Api.currentProcessId.
const int _own = 0x3000;
const int _ownChild = 0x3001;

const int _popup = WindowStyle.popup;
const int _tool = WindowStyle.exToolWindow;

void main() {
  late FakeWin32Api api;
  late WindowsSurfaceResolver resolver;

  setUp(() {
    api = FakeWin32Api()
      ..monitorList = [
        const WinMonitor(
          handle: 0xA,
          bounds: (left: 0, top: 0, right: 1920, bottom: 1080),
          isPrimary: true,
          deviceName: r'\\.\DISPLAY1',
        ),
        const WinMonitor(
          handle: 0xB,
          bounds: (left: -2560, top: -360, right: 0, bottom: 1080),
          isPrimary: false,
          deviceName: r'\\.\DISPLAY3',
        ),
      ];
    api.windows
      ..[_shared] = FakeWindow(pid: 7, thread: 70)
      ..[_sharedChild] = FakeWindow(pid: 7, thread: 70, root: _shared)
      ..[_dialog] = FakeWindow(pid: 7, thread: 71, owner: _shared)
      ..[_dialogPopup] = FakeWindow(
        pid: 7,
        thread: 71,
        owner: _dialog,
        style: _popup,
        exStyle: _tool,
      )
      ..[_menu] = FakeWindow(
        pid: 7,
        thread: 70,
        style: _popup,
        exStyle: _tool,
        className: WindowStyle.menuClass,
      )
      ..[_dropDown] = FakeWindow(
        pid: 7,
        thread: 70,
        style: _popup,
        exStyle: _tool,
        className: 'ComboLBox',
      )
      ..[_sibling] = FakeWindow(pid: 7, thread: 70)
      ..[_popupOnTaskbar] = FakeWindow(pid: 7, thread: 70, style: _popup)
      ..[_appWindowPopup] = FakeWindow(
        pid: 7,
        thread: 70,
        style: _popup,
        exStyle: _tool | WindowStyle.exAppWindow,
      )
      ..[_otherThreadMenu] = FakeWindow(
        pid: 7,
        thread: 72,
        style: _popup,
        exStyle: _tool,
        className: WindowStyle.menuClass,
      )
      ..[_otherThreadWindow] = FakeWindow(
        pid: 7,
        thread: 72,
        style: _popup,
        exStyle: _tool,
        className: 'Shell_TrayWnd',
      )
      ..[_ownedBySibling] = FakeWindow(
        pid: 7,
        thread: 70,
        owner: _sibling,
        style: _popup,
        exStyle: _tool,
      )
      ..[_crossProcessOwned] = FakeWindow(pid: 9, owner: _shared)
      ..[_cycleA] = FakeWindow(pid: 7, thread: 70, owner: _cycleB)
      ..[_cycleB] = FakeWindow(pid: 7, thread: 70, owner: _cycleA)
      ..[_other] = FakeWindow(pid: 8)
      ..[_own] = FakeWindow(pid: api.currentProcessId)
      ..[_ownChild] = FakeWindow(pid: api.currentProcessId, root: _own);
    resolver = WindowsSurfaceResolver(api);
  });

  group('displays', () {
    test('ids from device names, pixel bounds, scale 1', () async {
      final displays = await resolver.displays();
      expect(displays.map((d) => d.id), [1, 3]);
      expect(displays[1].bounds, const Rect.fromLTRB(-2560, -360, 0, 1080));
      expect(displays[1].scaleFactor, 1);
      expect(displays[1].pixelSize, const Size(2560, 1440));
      expect(displays.map((d) => d.isPrimary), [true, false]);
    });

    test('a resolution change shows at the next event', () async {
      await resolver.displays();
      final calls = api.monitorsCalls;
      expect(
        resolver.resolve(const SharedSurface.display(3))!.bounds,
        const Rect.fromLTRB(-2560, -360, 0, 1080),
      );
      api.monitorList[1] = const WinMonitor(
        handle: 0xB,
        bounds: (left: -1920, top: 0, right: 0, bottom: 1080),
        isPrimary: false,
        deviceName: r'\\.\DISPLAY3',
      );
      expect(
        resolver.resolve(const SharedSurface.display(3))!.bounds,
        const Rect.fromLTRB(-1920, 0, 0, 1080),
      );
      // Read by handle, without enumerating again.
      expect(api.monitorsCalls, calls);
    });

    test('a new handle for the same display is found again', () {
      api.monitorList[1] = const WinMonitor(
        handle: 0xC,
        bounds: (left: 1920, top: 0, right: 3840, bottom: 1080),
        isPrimary: false,
        deviceName: r'\\.\DISPLAY3',
      );
      expect(
        resolver.resolve(const SharedSurface.display(3))!.bounds,
        const Rect.fromLTRB(1920, 0, 3840, 1080),
      );
    });

    test('a display that is gone resolves to null', () async {
      await resolver.displays();
      api.monitorList.removeAt(1);
      expect(resolver.resolve(const SharedSurface.display(3)), isNull);
      expect(resolver.resolve(const SharedSurface.display(9)), isNull);
    });

    test('device names without a number get fallback ids', () async {
      api.monitorList = [
        const WinMonitor(
          handle: 0xA,
          bounds: (left: 0, top: 0, right: 800, bottom: 600),
          isPrimary: true,
          deviceName: 'odd',
        ),
      ];
      final displays = await resolver.displays();
      expect(displays.single.id, WindowsSurfaceResolver.fallbackDisplayIdBase);
    });

    test('displayIdOf', () {
      expect(displayIdOf(r'\\.\DISPLAY1'), 1);
      expect(displayIdOf(r'\\.\display12'), 12);
      expect(displayIdOf(r'\\.\DISPLAY0'), isNull);
      expect(displayIdOf('MONITOR'), isNull);
    });
  });

  group('windows', () {
    test('bounds are the frame, pixel size its size', () {
      final g = resolver.resolve(const SharedSurface.window(_shared))!;
      expect(g.bounds, const Rect.fromLTRB(100, 50, 900, 650));
      expect(g.pixelSize, const Size(800, 600));
      expect(g.isHidden, isFalse);
    });

    test('read again for every event', () {
      const s = SharedSurface.window(_shared);
      resolver.resolve(s);
      api.windows[_shared]!.bounds = (left: 0, top: 0, right: 10, bottom: 10);
      expect(resolver.resolve(s)!.bounds, const Rect.fromLTRB(0, 0, 10, 10));
    });

    test('a closed window is gone', () {
      api.windows.remove(_shared);
      expect(resolver.resolve(const SharedSurface.window(_shared)), isNull);
      expect(resolver.resolve(const SharedSurface.window(0)), isNull);
    });

    test('minimized, invisible or cloaked is hidden', () {
      const s = SharedSurface.window(_shared);
      final w = api.windows[_shared]!..iconic = true;
      expect(resolver.resolve(s)!.isHidden, isTrue);
      w
        ..iconic = false
        ..visible = false;
      expect(resolver.resolve(s)!.isHidden, isTrue);
      w
        ..visible = true
        ..cloaked = true;
      expect(resolver.resolve(s)!.isHidden, isTrue);
      w
        ..cloaked = false
        ..bounds = null;
      expect(resolver.resolve(s)!.isHidden, isTrue);
    });

    test('rect surfaces resolve to their bounds', () {
      final s = SharedSurface.rect(const Rect.fromLTWH(1, 2, 3, 4));
      expect(resolver.resolve(s)!.bounds, const Rect.fromLTWH(1, 2, 3, 4));
      (s as RectSurface).close();
      expect(resolver.resolve(s), isNull);
    });
  });

  group('occlusion', () {
    const s = SharedSurface.window(_shared);

    bool onSurfaceWith(int hit) {
      final points = <(int, int)>[];
      api.hitTest = (x, y) {
        points.add((x, y));
        return hit;
      };
      final r = resolver.isOnSurface(s, const Offset(10.9, -0.5));
      expect(points, [(10, -1)]);
      return r;
    }

    test('the shared window and its children are on it', () {
      expect(onSurfaceWith(_shared), isTrue);
      expect(onSurfaceWith(_sharedChild), isTrue);
    });

    test('windows it owns are on it, through owned windows', () {
      expect(onSurfaceWith(_dialog), isTrue);
      expect(onSurfaceWith(_dialogPopup), isTrue);
      // Ownership crosses processes: the shared window asked for it.
      expect(onSurfaceWith(_crossProcessOwned), isTrue);
    });

    test('unowned menus and tool popups of its thread are on it', () {
      expect(onSurfaceWith(_menu), isTrue);
      expect(onSurfaceWith(_dropDown), isTrue);
    });

    test('other windows of the same process are not', () {
      // Another browser window on the same UI thread.
      expect(onSurfaceWith(_sibling), isFalse);
      // Unowned popups with a taskbar button are windows of their own.
      expect(onSurfaceWith(_popupOnTaskbar), isFalse);
      expect(onSurfaceWith(_appWindowPopup), isFalse);
      // Explorer: the taskbar and its menus run on another thread.
      expect(onSurfaceWith(_otherThreadMenu), isFalse);
      expect(onSurfaceWith(_otherThreadWindow), isFalse);
      // A popup of another window isn't matched by thread.
      expect(onSurfaceWith(_ownedBySibling), isFalse);
    });

    test('an owner cycle ends', () {
      expect(onSurfaceWith(_cycleA), isFalse);
    });

    test('another app is not, nor is nothing', () {
      expect(onSurfaceWith(_other), isFalse);
      expect(onSurfaceWith(0), isFalse);
    });

    test('a shared child window matches by its root window', () {
      api.hitTest = (_, _) => _dialog;
      expect(
        resolver.isOnSurface(
          const SharedSurface.window(_sharedChild),
          Offset.zero,
        ),
        isTrue,
      );
      api.hitTest = (_, _) => _sibling;
      expect(
        resolver.isOnSurface(
          const SharedSurface.window(_sharedChild),
          Offset.zero,
        ),
        isFalse,
      );
    });

    test('displays and rects are never occluded', () {
      api.hitTest = (_, _) => _other;
      expect(
        resolver.isOnSurface(const SharedSurface.display(1), Offset.zero),
        isTrue,
      );
    });
  });

  group('keyboard focus', () {
    const s = SharedSurface.window(_shared);

    test('follows the foreground window by the same rule', () {
      api.foreground = _shared;
      expect(resolver.hasKeyboardFocus(s), isTrue);
      api.foreground = _sharedChild;
      expect(resolver.hasKeyboardFocus(s), isTrue);
      api.foreground = _dialog;
      expect(resolver.hasKeyboardFocus(s), isTrue);
      api.foreground = _sibling;
      expect(resolver.hasKeyboardFocus(s), isFalse);
      api.foreground = _otherThreadWindow;
      expect(resolver.hasKeyboardFocus(s), isFalse);
      api.foreground = _other;
      expect(resolver.hasKeyboardFocus(s), isFalse);
      api.foreground = 0;
      expect(resolver.hasKeyboardFocus(s), isFalse);
    });

    test('displays always have it', () {
      api.foreground = _other;
      expect(resolver.hasKeyboardFocus(const SharedSurface.display(1)), isTrue);
    });
  });

  group('the host app\'s own windows', () {
    test('the root window under the point is this process\'s', () {
      final points = <(int, int)>[];
      var hit = _ownChild;
      api.hitTest = (x, y) {
        points.add((x, y));
        return hit;
      };
      expect(resolver.isOwnWindowAt(const Offset(5.5, 7.9)), isTrue);
      expect(points, [(5, 7)]);
      hit = _own;
      expect(resolver.isOwnWindowAt(Offset.zero), isTrue);
      for (final other in [_shared, _other, 0]) {
        hit = other;
        expect(resolver.isOwnWindowAt(Offset.zero), isFalse);
      }
    });

    test('the foreground window is this process\'s', () {
      api.foreground = _own;
      expect(resolver.isOwnAppInFront(), isTrue);
      api.foreground = _ownChild;
      expect(resolver.isOwnAppInFront(), isTrue);
      for (final other in [_shared, _other, 0]) {
        api.foreground = other;
        expect(resolver.isOwnAppInFront(), isFalse);
      }
    });
  });
}
