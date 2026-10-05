import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/src/host/windows/win32_api.dart';
import 'package:remote_input/src/host/windows/windows_secure_context.dart';

import 'fake_win32.dart';

const int _own = 0x10;
const int _normal = 0x20;
const int _admin = 0x30;
const int _opaque = 0x40;

void main() {
  late FakeWin32Api api;
  late WindowsSecureContextProbe probe;

  setUp(() {
    api = FakeWin32Api()..currentProcessId = 1;
    api.windows
      ..[_own] = FakeWindow(pid: 1)
      ..[_normal] = FakeWindow(pid: 2)
      ..[_admin] = FakeWindow(pid: 3)
      ..[_opaque] = FakeWindow(pid: 4);
    api.integrity
      ..[2] = IntegrityLevel.medium
      ..[3] = IntegrityLevel.high
      ..[4] = null; // The token can't be read.
    probe = WindowsSecureContextProbe(api);
  });

  test('the secure desktop blocks both kinds', () {
    api.inputDesktopDefault = false;
    expect(probe.check(InputKind.keyboard), BlockReason.secureDesktop);
    expect(
      probe.check(InputKind.pointer, point: Offset.zero),
      BlockReason.secureDesktop,
    );
  });

  test('keys follow the foreground window', () {
    api.foreground = _normal;
    expect(probe.check(InputKind.keyboard), isNull);
    api.foreground = _admin;
    expect(probe.check(InputKind.keyboard), BlockReason.elevatedTarget);
    api.foreground = _own;
    expect(probe.check(InputKind.keyboard), isNull);
    api.foreground = 0;
    expect(probe.check(InputKind.keyboard), isNull);
  });

  test('the pointer follows the window under the point', () {
    final hits = <(int, int)>[];
    api
      ..foreground = _admin
      ..hitTest = (x, y) {
        hits.add((x, y));
        return _normal;
      };
    expect(
      probe.check(InputKind.pointer, point: const Offset(-3.5, 9.9)),
      isNull,
    );
    expect(hits, [(-4, 9)]);
    api.hitTest = (_, _) => _admin;
    expect(
      probe.check(InputKind.pointer, point: Offset.zero),
      BlockReason.elevatedTarget,
    );
    // Without a point, only the desktop is checked.
    expect(probe.check(InputKind.pointer), isNull);
  });

  test('a token that cannot be read counts as elevated', () {
    api.foreground = _opaque;
    expect(probe.check(InputKind.keyboard), BlockReason.elevatedTarget);
  });

  test('an elevated host can reach elevated apps', () {
    api
      ..ownIntegrityLevel = IntegrityLevel.high
      ..foreground = _admin;
    probe = WindowsSecureContextProbe(api);
    expect(probe.check(InputKind.keyboard), isNull);
  });

  test('answers are cached per process for a while', () {
    fakeAsync((async) {
      probe = WindowsSecureContextProbe(api);
      api.foreground = _admin;
      for (var i = 0; i < 100; i++) {
        probe.check(InputKind.keyboard);
      }
      expect(api.integrityQueries, [3]);
      async.elapse(const Duration(seconds: 3));
      probe.check(InputKind.keyboard);
      expect(api.integrityQueries, [3, 3]);
    });
  });

  test('lastSubAuthority reads integrity SIDs', () {
    // S-1-16-12288: Mandatory Label\High.
    final high = Uint8List.fromList([
      1, 1, 0, 0, 0, 0, 0, 16, // revision, count, authority 16
      0x00, 0x30, 0x00, 0x00, // 0x3000
    ]);
    expect(lastSubAuthority(high), IntegrityLevel.high);
    // Two sub-authorities: the last one counts.
    final two = Uint8List.fromList([
      1, 2, 0, 0, 0, 0, 0, 5, //
      1, 0, 0, 0, //
      0x00, 0x20, 0x00, 0x00,
    ]);
    expect(lastSubAuthority(two), IntegrityLevel.medium);
    expect(lastSubAuthority(Uint8List.fromList([1, 1, 0, 0])), isNull);
    expect(
      lastSubAuthority(
        Uint8List.fromList([2, 1, 0, 0, 0, 0, 0, 16, 0, 0, 0, 0]),
      ),
      isNull,
    );
    expect(
      lastSubAuthority(Uint8List.fromList([1, 0, 0, 0, 0, 0, 0, 16])),
      isNull,
    );
  });
}
