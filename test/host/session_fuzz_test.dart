// Session fuzzing (RIN-18, RIN-50; docs/design.md §12). By default a small
// run that takes seconds: a fixed seed, plus a new random seed each run,
// printed so a failure can be replayed. `dart run tool/fuzz.dart --mode
// session` runs it big:
//
//   flutter test test/host/session_fuzz_test.dart \
//     --dart-define=REMOTE_INPUT_FUZZ_SEQUENCES=100000 \
//     --dart-define=REMOTE_INPUT_FUZZ_SEED=3 \
//     --dart-define=REMOTE_INPUT_FUZZ_OUT=build/fuzz
//
// To replay sequence I of seed S alone: SEED=S, FIRST=I, SEQUENCES=1.
// Output is counts and timings; a failing sequence, shrunk, goes to a JSON
// file under REMOTE_INPUT_FUZZ_OUT.
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';

import '../support/session_fuzzer.dart';

const int _sequences = int.fromEnvironment(
  'REMOTE_INPUT_FUZZ_SEQUENCES',
  defaultValue: 300,
);
const int _seed = int.fromEnvironment(
  'REMOTE_INPUT_FUZZ_SEED',
  defaultValue: 1,
);
const int _first = int.fromEnvironment('REMOTE_INPUT_FUZZ_FIRST');
const String _out = String.fromEnvironment(
  'REMOTE_INPUT_FUZZ_OUT',
  defaultValue: 'build/fuzz',
);

/// Whether this is a run with explicit options (tool/fuzz.dart, or a
/// replay): then only the given seed runs.
const bool _explicit = bool.hasEnvironment('REMOTE_INPUT_FUZZ_SEED');

void main() {
  tearDown(RemoteInputHost.stopAll);

  final timeout = _sequences > 2000 ? Timeout.none : null;

  test(
    'random sequences keep the session safe (seed $_seed)',
    () => _fuzz(_seed, _first, _sequences),
    timeout: timeout,
  );

  if (!_explicit) {
    // A different seed every run, so the local gates keep exploring.
    final seed = Random().nextInt(1 << 32);
    test(
      'random sequences keep the session safe (rotating seed $seed)',
      () => _fuzz(seed, 0, _sequences),
      timeout: timeout,
    );
  }
}

void _fuzz(int seed, int first, int count) {
  final totals = FuzzTotals();
  final failures = <String>[];
  final watch = Stopwatch()..start();
  for (var i = first; i < first + count; i++) {
    final (setup, steps) = sequenceFor(seed, i);
    final failure = runSequence(setup, steps, totals);
    if (failure == null) continue;
    final shrunk = shrink(setup, steps, failure.invariant);
    final shrunkFailure = runSequence(setup, shrunk) ?? failure;
    final dir = Directory(_out)..createSync(recursive: true);
    final file = File(
      '${dir.path}/session-seed$seed-index$i-${failure.invariant}.json',
    );
    file.writeAsStringSync(
      reproduction(
        seed: seed,
        index: i,
        failure: shrunkFailure,
        setup: setup,
        steps: shrunk,
        originalSteps: steps.length,
      ),
    );
    failures.add('${failure.invariant} (sequence $i, ${file.path})');
    if (failures.length >= 20) break;
  }
  watch.stop();
  // Counts and timings only (docs/design.md §6.6).
  // ignore: avoid_print
  print(
    'session fuzz: seed $seed, sequences ${totals.sequences} from $first, '
    'steps ${totals.steps}, messages ${totals.messages}, '
    '${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s\n'
    '  injected: ${totals.injectedPresses} presses, moves, wheels and text; '
    '${totals.injectedReleases} releases\n'
    '  violations ${totals.violations}, drops ${totals.dropped}\n'
    '  stops: ${totals.stops}\n'
    '  states after a step: ${totals.states}\n'
    '  failures: ${failures.isEmpty ? 'none' : failures.join('; ')}',
  );
  expect(
    failures,
    isEmpty,
    reason:
        'replay with --dart-define=REMOTE_INPUT_FUZZ_SEED=$seed '
        '(and REMOTE_INPUT_FUZZ_FIRST=<sequence>, '
        'REMOTE_INPUT_FUZZ_SEQUENCES=1)',
  );
}
