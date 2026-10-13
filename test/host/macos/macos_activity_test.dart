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

extension on MacosActivityCounts {
  MacosActivityCounts plus(MacosActivityCounts o) => MacosActivityCounts(
    keyDowns: keyDowns + o.keyDowns,
    flagsChanged: flagsChanged + o.flagsChanged,
    buttonDowns: buttonDowns + o.buttonDowns,
    scrolls: scrolls + o.scrolls,
    moves: moves + o.moves,
  );
}

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

  group('checkDiscrete (RIN-42)', () {
    test('a key, modifier, button or scroll between polls counts once', () {
      expect(d.checkDiscrete(snap(keys: 1), ms(5)), isFalse); // no baseline yet
      d.update(snap(), ms(0));
      expect(d.checkDiscrete(snap(), ms(5)), isFalse);
      expect(d.checkDiscrete(snap(keys: 1), ms(5)), isTrue);
      expect(d.checkDiscrete(snap(keys: 1), ms(5)), isFalse);
      // Consumed: the next poll doesn't report it again.
      expect(d.update(snap(keys: 1), ms(10)), isFalse);
      expect(d.checkDiscrete(snap(keys: 1, flags: 1), ms(15)), isTrue);
      expect(
        d.checkDiscrete(snap(keys: 1, flags: 1, buttons: 1), ms(15)),
        isTrue,
      );
      expect(
        d.checkDiscrete(
          snap(keys: 1, flags: 1, buttons: 1, scrolls: 1),
          ms(15),
        ),
        isTrue,
      );
    });

    test('movement is left to the poll', () {
      d.update(snap(pointer: const Offset(100, 100)), ms(0));
      expect(
        d.checkDiscrete(
          snap(moves: 5, pointer: const Offset(200, 200)),
          ms(15),
        ),
        isFalse,
      );
      // A key found between polls keeps the movement for the poll to judge.
      expect(
        d.checkDiscrete(
          snap(keys: 1, moves: 5, pointer: const Offset(200, 200)),
          ms(5),
        ),
        isTrue,
      );
      expect(
        d.update(
          snap(keys: 1, moves: 5, pointer: const Offset(200, 200)),
          ms(10),
        ),
        isTrue,
      );
    });
  });

  group("the package's own posts in the HID counts (RIN-57)", () {
    const ownKey = MacosActivityCounts(keyDowns: 1);
    const ownButton = MacosActivityCounts(buttonDowns: 1);

    test('subtracted by default: an own click or key is not local', () {
      d.update(snap(), ms(0));
      // macOS 27: one posted click advanced the HID button count by one.
      expect(d.update(snap(buttons: 1, own: ownButton), ms(10)), isFalse);
      expect(
        d.checkDiscrete(
          snap(buttons: 1, keys: 1, own: ownKey.plus(ownButton)),
          ms(12),
        ),
        isFalse,
      );
      expect(d.subtractingOwnPosts, everyElement(isTrue));
    });

    test('local input next to own posts still counts', () {
      d.update(snap(), ms(0));
      // One own key and one from the keyboard in the same interval.
      expect(d.checkDiscrete(snap(keys: 2, own: ownKey), ms(5)), isTrue);
      expect(d.update(snap(keys: 2, own: ownKey), ms(10)), isFalse);
      expect(
        d.update(
          snap(keys: 2, buttons: 2, own: ownKey.plus(ownButton)),
          ms(20),
        ),
        isTrue,
      );
    });

    test("an own post's HID count arriving a poll later isn't local", () {
      d.update(snap(), ms(0));
      expect(d.update(snap(own: ownKey), ms(10)), isFalse);
      expect(d.update(snap(keys: 1, own: ownKey), ms(20)), isFalse);
      expect(d.checkDiscrete(snap(keys: 1, own: ownKey), ms(25)), isFalse);
    });

    test('learns when a kind never reaches the HID counts', () {
      d.update(snap(), ms(0));
      expect(d.update(snap(own: ownKey), ms(10)), isFalse);
      // Past the window with nothing matched: keys don't reach the counts
      // here, so a key from the keyboard now counts.
      expect(d.update(snap(keys: 1, own: ownKey), ms(600)), isTrue);
      expect(d.subtractingOwnPosts[0], isFalse);
      expect(d.subtractingOwnPosts[2], isTrue);
      // And from then on every key does, own posts or not.
      expect(
        d.checkDiscrete(snap(keys: 2, own: ownKey.plus(ownKey)), ms(610)),
        isTrue,
      );
    });

    test(
      'a missing post, once the kind is known to reach, changes nothing',
      () {
        d.update(snap(), ms(0));
        // A key post is seen in the HID counts: keys reach them.
        expect(d.update(snap(keys: 1, own: ownKey), ms(10)), isFalse);
        // A second post goes missing (the system dropped or merged it).
        const twoKeys = MacosActivityCounts(keyDowns: 2);
        expect(d.update(snap(keys: 1, own: twoKeys), ms(20)), isFalse);
        d.update(snap(keys: 1, own: twoKeys), ms(700));
        expect(d.subtractingOwnPosts[0], isTrue);
        // The package's next key is still subtracted.
        const threeKeys = MacosActivityCounts(keyDowns: 3);
        expect(d.update(snap(keys: 2, own: threeKeys), ms(710)), isFalse);
      },
    );

    test('coalesced moves, matched in part, keep the subtraction', () {
      d.update(snap(pointer: const Offset(100, 100)), ms(0));
      const ownMoves = MacosActivityCounts(moves: 5);
      expect(
        d.update(
          snap(moves: 3, own: ownMoves, pointer: const Offset(100, 100)),
          ms(10),
        ),
        isFalse,
      );
      d.update(
        snap(moves: 3, own: ownMoves, pointer: const Offset(100, 100)),
        ms(700),
      );
      expect(d.subtractingOwnPosts[4], isTrue);
    });

    test('an old own post cannot hide new local input', () {
      d = MacosActivityDetector(ownEventsReachHidState: true);
      d.update(snap(), ms(0));
      expect(d.update(snap(own: ownKey), ms(10)), isFalse);
      // The post never showed up; 600 ms later a real key isn't eaten by it.
      expect(d.update(snap(keys: 1, own: ownKey), ms(600)), isTrue);
    });

    test('forced off takes the HID counts as they are', () {
      d = MacosActivityDetector(ownEventsReachHidState: false);
      d.update(snap(), ms(0));
      expect(d.update(snap(keys: 1, own: ownKey), ms(10)), isTrue);
      expect(d.subtractingOwnPosts, everyElement(isFalse));
    });
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
          ms(700), // past ownEventWindow (500 ms)
        ),
        isTrue,
      );
    });
  });

  test('a clock that goes back keeps the windows short (RIN-18)', () {
    // The monitor's stopwatch follows the wall clock, which a time sync
    // after wake can set back. Single jitter reports half a second apart
    // must not add up to sustained movement across that.
    const p = Offset(100, 100);
    d.update(snap(pointer: p), ms(3600000));
    expect(d.update(snap(moves: 1, pointer: p), ms(3600010)), isFalse);
    expect(d.update(snap(moves: 2, pointer: p), ms(500)), isFalse);
    expect(d.update(snap(moves: 3, pointer: p), ms(1000)), isFalse);
    expect(d.update(snap(moves: 4, pointer: p), ms(1500)), isFalse);
    // Real movement still counts.
    expect(d.update(snap(moves: 6, pointer: p), ms(2000)), isFalse);
    expect(d.update(snap(moves: 8, pointer: p), ms(2010)), isTrue);
  });

  test('reset forgets the baseline', () {
    d.update(snap(), ms(0));
    d.reset();
    expect(d.update(snap(keys: 5), ms(10)), isFalse);
  });

  group('MacosCounterHealth (RIN-45)', () {
    late MacosCounterHealth h;
    setUp(() => h = MacosCounterHealth());

    // The pointer at [x], with the HID move counter at [moves] and the
    // package's own move counter at [own].
    MacosActivitySnapshot at(double x, {int moves = 100, int own = 0}) => snap(
      moves: moves,
      pointer: Offset(x, 0),
      own: MacosActivityCounts(moves: own),
    );

    test('physical moves the counters see are healthy', () {
      h.update(at(0), 0, ms(0));
      for (var i = 1; i <= 50; i++) {
        h.update(at(i * 20.0, moves: 100 + i * 3), 0, ms(i * 10));
      }
      expect(h.countersStale, isFalse);
      expect(h.unexplainedMoves, 0);
    });

    test('the pointer moving with the counter flat, twice, is stale', () {
      h.update(at(0), 0, ms(0));
      h.update(at(50), 0, ms(10));
      expect(h.countersStale, isFalse); // one sample could be a race
      h.update(at(100), 0, ms(20));
      expect(h.countersStale, isTrue);
      expect(h.trips, 1);
      // It stays stale while the counter is flat, moving or not.
      h.update(at(100), 0, ms(30));
      h.update(at(150), 0, ms(40));
      expect(h.countersStale, isTrue);
      expect(h.trips, 1);
      // Recovery: the counter advances with a physical move.
      expect(h.update(at(160, moves: 103), 0, ms(50)), isTrue);
      expect(h.countersStale, isFalse);
      expect(h.update(at(170, moves: 106), 0, ms(60)), isFalse);
    });

    test('strikes must fall within the window, with no HID move between', () {
      h.update(at(0), 0, ms(0));
      h.update(at(50), 0, ms(10));
      h.update(at(100), 0, ms(1500));
      expect(h.countersStale, isFalse);
      h.update(at(150), 0, ms(1510));
      expect(h.countersStale, isTrue);

      h = MacosCounterHealth()..update(at(0), 0, ms(0));
      h.update(at(50), 0, ms(10));
      h.update(at(60, moves: 101), 0, ms(20)); // the counter moved
      h.update(at(110, moves: 101), 0, ms(30));
      expect(h.countersStale, isFalse);
    });

    test('movement within the threshold is ignored', () {
      h.update(at(0), 0, ms(0));
      for (var i = 1; i <= 20; i++) {
        h.update(at(i.isEven ? 0 : 3), 0, ms(i * 10));
      }
      expect(h.countersStale, isFalse);
      expect(h.unexplainedMoves, 0);
    });

    test('the package\'s own moves are explained', () {
      h.update(at(0), 0, ms(0));
      // Its own counter advanced in the same poll.
      for (var i = 1; i <= 10; i++) {
        h.update(at(i * 100.0, own: i), 0, ms(i * 10));
      }
      expect(h.countersStale, isFalse);
      // Its post was counted a poll before the pointer got there.
      h
        ..noteInjectedPointer(const Offset(2000, 0))
        ..update(at(2000.5, own: 10), 0, ms(200))
        ..noteInjectedPointer(const Offset(3000, 0))
        ..update(at(3001, own: 10), 0, ms(210));
      expect(h.countersStale, isFalse);
      expect(h.unexplainedMoves, 0);
      // Anywhere else isn't.
      h
        ..update(at(3500, own: 10), 0, ms(220))
        ..update(at(4000, own: 10), 0, ms(230));
      expect(h.countersStale, isTrue);
    });

    test('a display reconfiguration explains jumps for a while', () {
      h.update(at(0), 0, ms(0));
      h.update(at(0), 1, ms(10)); // reconfigured
      h.update(at(900), 1, ms(20)); // the pointer lands on another display
      h.update(at(1800), 1, ms(30));
      expect(h.countersStale, isFalse);
      // After the grace, jumps count again.
      h.update(at(1900), 1, ms(600));
      h.update(at(2000), 1, ms(610));
      expect(h.countersStale, isTrue);
    });

    test('an unreadable pointer resets the baseline, without a strike', () {
      h.update(at(0), 0, ms(0));
      h.update(at(50), 0, ms(10));
      h.update(
        const MacosActivitySnapshot(
          hid: MacosActivityCounts(moves: 100),
          own: MacosActivityCounts(),
          pointer: Offset.zero,
          pointerReadable: false,
        ),
        0,
        ms(20),
      );
      h.update(at(500), 0, ms(30)); // a new baseline
      expect(h.countersStale, isFalse);
      expect(h.unexplainedMoves, 1);
    });
  });
}
