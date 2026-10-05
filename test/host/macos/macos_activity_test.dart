import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/src/host/macos/macos_activity.dart';
import 'package:remote_input/src/host/macos/macos_native.dart';

MacosActivitySnapshot snap({
  int keys = 0,
  int flags = 0,
  int buttons = 0,
  int scrolls = 0,
  int moves = 0,
  Offset pointer = Offset.zero,
  MacosActivityCounts own = const MacosActivityCounts(),
}) => MacosActivitySnapshot(
  hid: MacosActivityCounts(
    keyDowns: keys,
    flagsChanged: flags,
    buttonDowns: buttons,
    scrolls: scrolls,
    moves: moves,
  ),
  own: own,
  pointer: pointer,
);

Duration ms(int v) => Duration(milliseconds: v);

void main() {
  late MacosActivityDetector d;
  setUp(() => d = MacosActivityDetector());

  test('the first snapshot sets the baseline', () {
    expect(d.update(snap(keys: 500, moves: 9000), ms(0)), isFalse);
    expect(d.update(snap(keys: 500, moves: 9000), ms(10)), isFalse);
  });

  test('a key, a modifier, a button or a scroll is local input', () {
    d.update(snap(), ms(0));
    expect(d.update(snap(keys: 1), ms(10)), isTrue);
    expect(d.update(snap(keys: 1), ms(20)), isFalse);
    expect(d.update(snap(keys: 1, flags: 1), ms(30)), isTrue);
    expect(d.update(snap(keys: 1, flags: 1, buttons: 1), ms(40)), isTrue);
    expect(
      d.update(snap(keys: 1, flags: 1, buttons: 1, scrolls: 2), ms(50)),
      isTrue,
    );
  });

  test('counters that wrap around 2^32 still count', () {
    d.update(snap(keys: 0xFFFFFFFF), ms(0));
    expect(d.update(snap(keys: 0), ms(10)), isTrue);
  });

  group('pointer movement', () {
    test('within the threshold is jitter', () {
      d.update(snap(pointer: const Offset(100, 100)), ms(0));
      expect(
        d.update(snap(moves: 1, pointer: const Offset(102, 101)), ms(10)),
        isFalse,
      );
    });

    test('past the threshold is local input', () {
      d.update(snap(pointer: const Offset(100, 100)), ms(0));
      expect(
        d.update(snap(moves: 3, pointer: const Offset(105, 100)), ms(10)),
        isTrue,
      );
    });

    test('slow movement adds up across polls', () {
      d.update(snap(pointer: const Offset(100, 100)), ms(0));
      var moves = 0;
      var fired = false;
      for (var i = 1; i <= 5 && !fired; i++) {
        moves++;
        fired = d.update(
          snap(moves: moves, pointer: Offset(100.0 + i, 100)),
          ms(i * 10),
        );
      }
      expect(fired, isTrue);
    });

    test('jitter spread over quiet spells doesn\'t add up', () {
      d.update(snap(pointer: const Offset(100, 100)), ms(0));
      var t = 0;
      var moves = 0;
      for (var i = 1; i <= 10; i++) {
        moves++;
        t += 10;
        expect(
          d.update(snap(moves: moves, pointer: Offset(100.0 + i, 100)), ms(t)),
          isFalse,
          reason: 'step $i',
        );
        // Still for longer than the anchor reset.
        t += 300;
        expect(
          d.update(snap(moves: moves, pointer: Offset(100.0 + i, 100)), ms(t)),
          isFalse,
        );
      }
    });

    test('the pointer moving without a HID move is the package\'s own', () {
      d.update(snap(pointer: const Offset(100, 100)), ms(0));
      expect(d.update(snap(pointer: const Offset(900, 500)), ms(10)), isFalse);
    });

    test('measured from where the package put the pointer', () {
      d.update(snap(pointer: const Offset(100, 100)), ms(0));
      d.noteInjectedPointer(const Offset(500, 500));
      // A HID move reported, but the pointer is where the package put it.
      expect(
        d.update(snap(moves: 1, pointer: const Offset(501, 500)), ms(10)),
        isFalse,
      );
      d.noteInjectedPointer(const Offset(600, 600));
      expect(
        d.update(snap(moves: 2, pointer: const Offset(620, 600)), ms(20)),
        isTrue,
      );
    });
  });

  group('if the package\'s own events reach the HID counts', () {
    setUp(() => d = MacosActivityDetector(ownEventsReachHidState: true));

    test('they are subtracted', () {
      d.update(snap(), ms(0));
      expect(
        d.update(
          snap(keys: 1, own: const MacosActivityCounts(keyDowns: 1)),
          ms(10),
        ),
        isFalse,
      );
    });

    test('even when the HID count catches up a poll later', () {
      d.update(snap(), ms(0));
      expect(
        d.update(snap(own: const MacosActivityCounts(keyDowns: 1)), ms(10)),
        isFalse,
      );
      expect(
        d.update(
          snap(keys: 1, own: const MacosActivityCounts(keyDowns: 1)),
          ms(20),
        ),
        isFalse,
      );
    });

    test('local input on top of the package\'s still counts', () {
      d.update(snap(), ms(0));
      expect(
        d.update(
          snap(keys: 2, own: const MacosActivityCounts(keyDowns: 1)),
          ms(10),
        ),
        isTrue,
      );
    });

    test('an own event that never shows up stops masking', () {
      d.update(snap(), ms(0));
      d.update(snap(own: const MacosActivityCounts(keyDowns: 1)), ms(10));
      expect(
        d.update(
          snap(keys: 1, own: const MacosActivityCounts(keyDowns: 1)),
          ms(400),
        ),
        isTrue,
      );
    });
  });

  test('reset forgets the baseline', () {
    d.update(snap(), ms(0));
    d.reset();
    expect(d.update(snap(keys: 5), ms(10)), isFalse);
  });
}
