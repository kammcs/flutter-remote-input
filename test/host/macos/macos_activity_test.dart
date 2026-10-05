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

  group('sustained hardware moves (review M2)', () {
    // The viewer streams moves at 250 Hz: before every poll the package
    // has put the pointer somewhere new, so the distance rule measures from
    // there and never sees the hardware's few points.
    Offset injectedAt(int poll) => Offset(300.0 + poll * 7, 300);

    test('count while the viewer moves the pointer', () {
      d.update(snap(pointer: injectedAt(0)), ms(0));
      var hidMoves = 0;
      var firedAt = -1;
      for (var poll = 1; poll <= 10 && firedAt < 0; poll++) {
        d.noteInjectedPointer(injectedAt(poll));
        // A 125 Hz mouse: one report per 10 ms poll, each nudging the
        // pointer a point from where the package put it.
        hidMoves++;
        if (d.update(
          snap(moves: hidMoves, pointer: injectedAt(poll) + const Offset(1, 0)),
          ms(poll * 10),
        )) {
          firedAt = poll;
        }
      }
      expect(firedAt, 3);
    });

    test('count wherever the pointer is', () {
      d.update(snap(pointer: const Offset(100, 100)), ms(0));
      expect(
        d.update(snap(moves: 2, pointer: const Offset(100, 100)), ms(10)),
        isFalse,
      );
      expect(
        d.update(snap(moves: 3, pointer: const Offset(100, 100)), ms(20)),
        isTrue,
      );
    });

    test('a single jitter report does not', () {
      d.update(snap(pointer: injectedAt(0)), ms(0));
      for (var poll = 1; poll <= 30; poll++) {
        d.noteInjectedPointer(injectedAt(poll));
        expect(
          d.update(snap(moves: 1, pointer: injectedAt(poll)), ms(poll * 10)),
          isFalse,
          reason: 'poll $poll',
        );
      }
    });

    test('a short burst within one poll does not, until it goes on', () {
      d.update(snap(pointer: injectedAt(0)), ms(0));
      d.noteInjectedPointer(injectedAt(1));
      // Five reports from a 1000 Hz mouse in one poll: a bump.
      expect(d.update(snap(moves: 5, pointer: injectedAt(1)), ms(10)), isFalse);
      d.noteInjectedPointer(injectedAt(2));
      expect(d.update(snap(moves: 5, pointer: injectedAt(2)), ms(20)), isFalse);
      d.noteInjectedPointer(injectedAt(3));
      // The movement continues into the next poll.
      expect(d.update(snap(moves: 6, pointer: injectedAt(3)), ms(30)), isTrue);
    });

    test('reports spread thinner than the window do not', () {
      d.update(snap(pointer: injectedAt(0)), ms(0));
      var hidMoves = 0;
      for (var poll = 1; poll <= 100; poll++) {
        d.noteInjectedPointer(injectedAt(poll));
        // One report every 60 ms: at most two within 100 ms.
        if (poll % 6 == 0) hidMoves++;
        expect(
          d.update(
            snap(moves: hidMoves, pointer: injectedAt(poll)),
            ms(poll * 10),
          ),
          isFalse,
          reason: 'poll $poll',
        );
      }
    });

    test('the package\'s own moves alone are not local input', () {
      d.update(snap(pointer: injectedAt(0)), ms(0));
      for (var poll = 1; poll <= 50; poll++) {
        d.noteInjectedPointer(injectedAt(poll));
        expect(
          d.update(snap(pointer: injectedAt(poll)), ms(poll * 10)),
          isFalse,
        );
      }
    });

    test('a detection starts a new count', () {
      d.update(snap(), ms(0));
      d.update(snap(moves: 2), ms(10));
      expect(d.update(snap(moves: 3), ms(20)), isTrue);
      expect(d.update(snap(moves: 4), ms(30)), isFalse);
      expect(d.update(snap(moves: 5), ms(40)), isFalse);
      expect(d.update(snap(moves: 6), ms(50)), isTrue);
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

    test('the package\'s streamed moves are subtracted, local ones count', () {
      Offset at(int poll) => Offset(300.0 + poll * 7, 300);
      d.update(snap(pointer: at(0)), ms(0));
      var own = 0;
      var local = 0;
      for (var poll = 1; poll <= 20; poll++) {
        // 250 Hz from the viewer: 2 or 3 of the package's moves a poll,
        // all of them in the HID counts too.
        own += poll.isEven ? 3 : 2;
        d.noteInjectedPointer(at(poll));
        expect(
          d.update(
            snap(
              moves: own,
              pointer: at(poll),
              own: MacosActivityCounts(moves: own),
            ),
            ms(poll * 10),
          ),
          isFalse,
          reason: 'poll $poll',
        );
      }
      var fired = false;
      for (var poll = 21; poll <= 30 && !fired; poll++) {
        own += poll.isEven ? 3 : 2;
        local++;
        d.noteInjectedPointer(at(poll));
        fired = d.update(
          snap(
            moves: own + local,
            pointer: at(poll),
            own: MacosActivityCounts(moves: own),
          ),
          ms(poll * 10),
        );
      }
      expect(fired, isTrue);
      expect(local, 3);
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
