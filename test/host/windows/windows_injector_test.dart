import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/src/host/windows/input_records.dart';
import 'package:remote_input/src/host/windows/windows_injector.dart';

import 'fake_win32.dart';

const int _absMove = 0x8000 | 0x4000 | 0x0001;

void main() {
  late FakeWin32Api api;
  late WindowsInjector injector;

  setUp(() {
    api = FakeWin32Api()
      // Two displays: a 2560-wide one left of a 1920 primary.
      ..screen = (left: -2560, top: -360, right: 1920, bottom: 1080);
    injector = WindowsInjector(api);
  });

  MouseRecord absolute(int px, int py, {int flags = 0, int mouseData = 0}) =>
      MouseRecord(
        dx: absoluteCoordinate(px, -2560, 4480),
        dy: absoluteCoordinate(py, -360, 1440),
        mouseData: mouseData,
        flags: _absMove | flags,
        extraInfo: testTag,
      );

  group('pointer', () {
    test('a move is one absolute record on the point\'s pixel', () {
      expect(
        injector.movePointer(const Offset(-100.7, 20.2), heldButtons: {}),
        InjectResult.injected,
      );
      expect(api.calls, [
        [absolute(-101, 20)],
      ]);
    });

    test('the absolute value lands back on the pixel', () {
      injector.movePointer(const Offset(1919.99, 1079.5), heldButtons: {});
      final r = api.records.single as MouseRecord;
      expect(pixelForAbsolute(r.dx, -2560, 4480), 1919);
      expect(pixelForAbsolute(r.dy, -360, 1440), 1079);
    });

    test('buttons carry the move in the same record', () {
      const p = Offset(10, 10);
      final cases = {
        (PointerButton.left, true): (0x0002, 0),
        (PointerButton.left, false): (0x0004, 0),
        (PointerButton.right, true): (0x0008, 0),
        (PointerButton.right, false): (0x0010, 0),
        (PointerButton.middle, true): (0x0020, 0),
        (PointerButton.middle, false): (0x0040, 0),
        (PointerButton.back, true): (0x0080, 1),
        (PointerButton.back, false): (0x0100, 1),
        (PointerButton.forward, true): (0x0080, 2),
        (PointerButton.forward, false): (0x0100, 2),
      };
      for (final MapEntry(key: (b, down), value: (flags, data))
          in cases.entries) {
        api.calls.clear();
        injector.pointerButton(p, b, down: down, clickCount: 1);
        expect(api.calls, [
          [absolute(10, 10, flags: flags, mouseData: data)],
        ], reason: '$b down: $down');
      }
    });

    test('the click count does not change the record', () {
      injector.pointerButton(
        Offset.zero,
        PointerButton.left,
        down: true,
        clickCount: 2,
      );
      expect(api.records.single, absolute(0, 0, flags: 0x0002));
    });

    test('setCursorPos placement sets the cursor, then a tagged event', () {
      injector = WindowsInjector(api, placement: PointerPlacement.setCursorPos);
      injector
        ..movePointer(const Offset(-5.5, 7.9), heldButtons: {})
        ..pointerButton(
          const Offset(-5.5, 7.9),
          PointerButton.back,
          down: true,
          clickCount: 1,
        );
      expect(api.cursorSets, [(-6, 7), (-6, 7)]);
      expect(api.records, [
        const MouseRecord(flags: 0x0001, extraInfo: testTag),
        const MouseRecord(flags: 0x0080, mouseData: 1, extraInfo: testTag),
      ]);
    });
  });

  group('wheel', () {
    test('lines: vertical negated, horizontal as is, both in one call', () {
      injector.wheel(const Offset(1, 2), dx: 1, dy: 3, unit: WheelUnit.line);
      expect(api.calls, [
        [
          absolute(1, 2, flags: 0x0800, mouseData: -120),
          absolute(1, 2, flags: 0x1000, mouseData: 40),
        ],
      ]);
    });

    test('pixels follow the lines-per-notch setting', () {
      api.lines = 6;
      injector.wheel(Offset.zero, dx: 0, dy: -100, unit: WheelUnit.pixel);
      expect(api.records.single, absolute(0, 0, flags: 0x0800, mouseData: 60));
    });

    test('a fraction of a unit posts nothing yet', () {
      expect(
        injector.wheel(Offset.zero, dx: 0, dy: 0, unit: WheelUnit.pixel),
        InjectResult.injected,
      );
      expect(api.calls, isEmpty);
    });
  });

  group('keys', () {
    test('by scan code, extended where the table says', () {
      injector
        ..key(0x00070052, down: true) // ArrowUp
        ..key(0x00070052, down: true, repeat: true)
        ..key(0x00070052, down: false)
        ..key(0x00070004, down: true); // KeyA
      expect(api.calls, [
        [const KeyRecord(scan: 0x48, flags: 0x09, extraInfo: testTag)],
        [const KeyRecord(scan: 0x48, flags: 0x09, extraInfo: testTag)],
        [const KeyRecord(scan: 0x48, flags: 0x0B, extraInfo: testTag)],
        [const KeyRecord(scan: 0x1E, flags: 0x08, extraInfo: testTag)],
      ]);
    });

    test('a usage without a scan code posts nothing', () {
      expect(injector.key(0x00FF0001, down: true), InjectResult.unmappedKey);
      expect(api.calls, isEmpty);
    });

    test('text goes in one call', () {
      injector.text('hi 😀');
      expect(api.calls, hasLength(1));
      expect(api.calls.single, textRecords('hi 😀', tag: testTag));
      expect(api.calls.single, hasLength(10));
    });

    test('empty text posts nothing', () {
      expect(injector.text(''), InjectResult.injected);
      expect(api.calls, isEmpty);
    });
  });

  group('failures', () {
    test('access denied is an elevated target', () {
      api.onSend = (_) => (sent: 0, error: 5);
      expect(injector.key(0x00070004, down: true), InjectResult.elevatedTarget);
    });

    test('other shortfalls fail', () {
      api.onSend = (n) => (sent: n - 1, error: 0);
      expect(injector.text('ab'), InjectResult.failed);
      api.onSend = (_) => (sent: 0, error: 87);
      expect(
        injector.movePointer(Offset.zero, heldButtons: {}),
        InjectResult.failed,
      );
    });

    test('every record carries the tag', () {
      api.injectionTag = 0x726D7469000000AA;
      injector
        ..movePointer(Offset.zero, heldButtons: {})
        ..wheel(Offset.zero, dx: 3, dy: 3, unit: WheelUnit.line)
        ..key(0x00070004, down: true)
        ..text('x\n');
      expect(api.records, isNotEmpty);
      for (final r in api.records) {
        expect(r.extraInfo, 0x726D7469000000AA);
      }
    });
  });

  test('the records passed to SendInput are cleared after the call', () {
    injector
      ..text('hunter2')
      ..key(0x00070004, down: true)
      ..movePointer(const Offset(10, 10), heldButtons: {});
    expect(api.passedBuffers, hasLength(3));
    for (final b in api.passedBuffers) {
      expect(b, everyElement(0));
    }
    // What Windows was given, copied during the call, was the real thing.
    expect(api.records.whereType<KeyRecord>(), isNotEmpty);
    expect(api.rawCalls.first, isNot(everyElement(0)));
  });
}
