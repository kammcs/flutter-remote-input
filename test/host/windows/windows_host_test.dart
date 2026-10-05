// The Windows platform under the real session, on a fake Win32: what a
// viewer's input becomes, as INPUT records.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/src/host/windows/input_records.dart';
import 'package:remote_input/src/host/windows/windows_host.dart';
import 'package:remote_input/testing.dart';

import '../../support/raw_viewer.dart';
import 'fake_win32.dart';

const int _hwnd = 0x1000;

void main() {
  late FakeWin32Api api;
  late FakeNativeActivity native;
  late WindowsHostPlatform platform;

  setUp(() {
    api = FakeWin32Api()
      ..screen = (left: -1920, top: 0, right: 1920, bottom: 1080)
      ..foreground = _hwnd
      ..hitTest = ((_, _) => _hwnd);
    // Another app's window: the host app's own windows aren't controllable.
    api.windows[_hwnd] = FakeWindow(
      pid: 4242,
      bounds: (left: -500, top: 100, right: 300, bottom: 700),
    );
    native = FakeNativeActivity();
    platform = WindowsHostPlatform(api, native);
  });

  test('reports Windows', () {
    expect(platform.platform, PeerPlatform.windows);
  });

  test('refuses to start unless per-monitor DPI aware', () {
    api.perMonitorV2 = false;
    expect(platform.checkAvailable(), HostUnavailableReason.dpiUnaware);
    expect(
      () => RemoteInputHost(platform: platform).enable(
        link: MemoryInputLink.pair().host,
        surface: const SharedSurface.window(_hwnd),
      ),
      throwsA(isA<HostUnavailableException>()),
    );
    api.perMonitorV2 = true;
    expect(platform.checkAvailable(), isNull);
  });

  test('a viewer drives a window surface', () {
    fakeAsync((async) {
      final pair = MemoryInputLink.pair();
      final viewer = RawViewer(pair.viewer);
      final session = RemoteInputHost(platform: platform)
          .enable(link: pair.host, surface: const SharedSurface.window(_hwnd));
      async.flushMicrotasks();
      expect(viewer.hostHello!.surfaceWidth, 800);
      expect(viewer.hostHello!.surfaceHeight, 600);
      viewer.hello();
      async.flushMicrotasks();
      expect(session.state, const SessionActive());
      expect(native.running, isTrue);

      int px(int v, int start, int extent) =>
          desktopPixel(start + (v + 0.5) * extent / 65536);

      // Corners and centre of the window's frame.
      for (final (x, y) in [(0, 0), (65535, 0), (0, 65535), (65535, 65535)]) {
        viewer.move(x, y);
        async.elapse(const Duration(milliseconds: 10));
      }
      viewer.button(32768, 32768, PointerButton.left, down: true);
      viewer.button(32768, 32768, PointerButton.left, down: false);
      viewer.key(0x00070004, KeyAction.down);
      viewer.key(0x00070004, KeyAction.up);
      viewer.text('ok');
      async.elapse(const Duration(milliseconds: 100));

      final records = api.records;
      final moves = records.whereType<MouseRecord>().toList();
      final pixels = [
        for (final m in moves)
          (
            pixelForAbsolute(m.dx, -1920, 3840),
            pixelForAbsolute(m.dy, 0, 1080),
          ),
      ];
      expect(pixels, [
        (-500, 100),
        (299, 100),
        (-500, 699),
        (299, 699),
        (px(32768, -500, 800), px(32768, 100, 600)),
        (px(32768, -500, 800), px(32768, 100, 600)),
      ]);
      expect(moves.map((m) => m.flags & 0xFFFE), [
        0xC000,
        0xC000,
        0xC000,
        0xC000,
        0xC002, // left down
        0xC004, // left up
      ]);
      final keys = records.whereType<KeyRecord>().toList();
      expect(keys.take(2), [
        const KeyRecord(scan: 0x1E, flags: 0x08, extraInfo: testTag),
        const KeyRecord(scan: 0x1E, flags: 0x0A, extraInfo: testTag),
      ]);
      expect(keys.skip(2), textRecords('ok', tag: testTag));

      // Local input pauses the session within one poll.
      native.counter++;
      async.elapse(const Duration(milliseconds: 10));
      expect(session.state, const SessionPaused(PauseReason.localInput));

      session.stop();
      async.flushMicrotasks();
      expect(native.running, isFalse);
    });
  });

  test('a window in front of the shared one drops the click', () {
    fakeAsync((async) {
      api.windows[0x2000] = FakeWindow(pid: 999);
      final pair = MemoryInputLink.pair();
      final viewer = RawViewer(pair.viewer);
      final session = RemoteInputHost(platform: platform)
          .enable(link: pair.host, surface: const SharedSurface.window(_hwnd));
      async.flushMicrotasks();
      viewer.hello();
      async.flushMicrotasks();
      api.hitTest = (_, _) => 0x2000;
      viewer.button(100, 100, PointerButton.left, down: true);
      async.elapse(const Duration(milliseconds: 50));
      expect(api.calls, isEmpty);
      expect(session.stats.dropped[DropReason.occluded], 1);
      session.stop();
    });
  });

  test('an elevated foreground window blocks keys', () {
    fakeAsync((async) {
      api.windows[0x3000] = FakeWindow(pid: 3);
      api.integrity[3] = 0x3000;
      final pair = MemoryInputLink.pair();
      final viewer = RawViewer(pair.viewer);
      final session = RemoteInputHost(platform: platform)
          .enable(link: pair.host, surface: const SharedSurface.display(1));
      async.flushMicrotasks();
      viewer.hello();
      async.flushMicrotasks();
      api.foreground = 0x3000;
      viewer.key(0x00070004, KeyAction.down);
      async.elapse(const Duration(milliseconds: 50));
      expect(api.calls, isEmpty);
      expect(session.state, const SessionBlocked(BlockReason.elevatedTarget));
      session.stop();
    });
  });

  test('UIPI reported by SendInput blocks the session', () {
    fakeAsync((async) {
      api.onSend = (_) => (sent: 0, error: Win32Input.errorAccessDenied);
      final pair = MemoryInputLink.pair();
      final viewer = RawViewer(pair.viewer);
      final session = RemoteInputHost(platform: platform)
          .enable(link: pair.host, surface: const SharedSurface.display(1));
      async.flushMicrotasks();
      viewer.hello();
      async.flushMicrotasks();
      viewer.text('x');
      async.elapse(const Duration(milliseconds: 50));
      expect(session.state, const SessionBlocked(BlockReason.elevatedTarget));
      session.stop();
    });
  });
}
