import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/src/host/windows/win32_api.dart';
import 'package:remote_input/src/host/windows/windows_surfaces.dart';

import 'fake_win32.dart';

const int _shared = 0x1000;
const int _sharedChild = 0x1001;
const int _sharedPopup = 0x1002;
const int _other = 0x2000;

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
      ..[_shared] = FakeWindow(pid: 7)
      ..[_sharedChild] = FakeWindow(pid: 7, root: _shared)
      ..[_sharedPopup] = FakeWindow(pid: 7)
      ..[_other] = FakeWindow(pid: 8);
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

    test('windows of the same process are on it (menus, popups)', () {
      expect(onSurfaceWith(_sharedPopup), isTrue);
    });

    test('another app is not, nor is nothing', () {
      expect(onSurfaceWith(_other), isFalse);
      expect(onSurfaceWith(0), isFalse);
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
      api.foreground = _sharedPopup;
      expect(resolver.hasKeyboardFocus(s), isTrue);
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
}
