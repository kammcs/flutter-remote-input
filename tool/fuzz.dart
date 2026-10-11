// Fuzzes the v1 codec and the host session at scale (docs/design.md §12).
//
//   dart run tool/fuzz.dart --mode random  --iterations 50000000 --seed 1
//   dart run tool/fuzz.dart --mode mutate  --iterations 50000000 --seed 2
//   dart run tool/fuzz.dart --mode session --iterations 100000   --seed 3
//
// Options:
//   --mode random|mutate|codec|session   codec is random and mutate, half each
//   --iterations N   inputs (random, mutate, codec) or sequences (session)
//   --seed S         the same seed (and --jobs) gives the same run
//   --jobs J         isolates for the codec modes (default 1); each takes a
//                    slice of the iterations with its own seed derived from S
//   --first I        session only: the first sequence index (to replay one)
//   --out DIR        where minimized failing cases are written (default
//                    build/fuzz, which git ignores)
//
// The codec modes are pure Dart (`dart run`). The session imports dart:ui,
// so `--mode session` runs test/host/session_fuzz_test.dart under
// `flutter test` with the options as --dart-define values.
//
// Output is counts and timings only. The bytes of an input are written only
// for a minimized failing case, to a file under --out: they are random data,
// never anyone's input.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:remote_input/src/protocol/codec.dart';
import 'package:remote_input/src/protocol/messages.dart';
import 'package:remote_input/src/protocol/wire_types.dart';

Future<void> main(List<String> args) async {
  final Options options;
  try {
    options = Options.parse(args);
  } on FormatException catch (e) {
    stderr
      ..writeln(e.message)
      ..writeln(
        'usage: dart run tool/fuzz.dart --mode random|mutate|codec|session '
        '[--iterations N] [--seed S] [--jobs J] [--first I] [--out DIR]',
      );
    exitCode = 64;
    return;
  }
  if (options.mode == 'session') {
    exitCode = await _runSession(options);
    return;
  }
  exitCode = await _runCodec(options);
}

final class Options {
  Options({
    required this.mode,
    required this.iterations,
    required this.seed,
    required this.jobs,
    required this.first,
    required this.out,
  });

  factory Options.parse(List<String> args) {
    final values = <String, String>{};
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (!a.startsWith('--')) throw FormatException('unexpected "$a"');
      final eq = a.indexOf('=');
      if (eq > 0) {
        values[a.substring(2, eq)] = a.substring(eq + 1);
      } else {
        if (i + 1 >= args.length) throw FormatException('$a needs a value');
        values[a.substring(2)] = args[++i];
      }
    }
    int number(String name, int fallback) {
      final v = values.remove(name);
      if (v == null) return fallback;
      final n = int.tryParse(v.replaceAll('_', ''));
      if (n == null || n < 0) throw FormatException('--$name must be >= 0');
      return n;
    }

    final mode = values.remove('mode') ?? 'codec';
    if (!const ['random', 'mutate', 'codec', 'session'].contains(mode)) {
      throw FormatException('unknown --mode $mode');
    }
    final options = Options(
      mode: mode,
      iterations: number('iterations', mode == 'session' ? 1000 : 1000000),
      seed: number('seed', 1),
      jobs: max(1, number('jobs', 1)),
      first: number('first', 0),
      out: values.remove('out') ?? 'build/fuzz',
    );
    if (values.isNotEmpty) {
      throw FormatException('unknown option --${values.keys.first}');
    }
    return options;
  }

  final String mode;
  final int iterations;
  final int seed;
  final int jobs;
  final int first;
  final String out;
}

// --- Session mode: delegated to flutter test --------------------------------

Future<int> _runSession(Options o) async {
  final process = await Process.start('flutter', [
    'test',
    'test/host/session_fuzz_test.dart',
    '--dart-define=REMOTE_INPUT_FUZZ_SEQUENCES=${o.iterations}',
    '--dart-define=REMOTE_INPUT_FUZZ_SEED=${o.seed}',
    '--dart-define=REMOTE_INPUT_FUZZ_FIRST=${o.first}',
    '--dart-define=REMOTE_INPUT_FUZZ_OUT=${o.out}',
    '--reporter=expanded',
  ], mode: ProcessStartMode.inheritStdio);
  return process.exitCode;
}

// --- Codec modes ------------------------------------------------------------

Future<int> _runCodec(Options o) async {
  final watch = Stopwatch()..start();
  final jobs = <Future<CodecReport>>[];
  for (var j = 0; j < o.jobs; j++) {
    final start = o.iterations * j ~/ o.jobs;
    final end = o.iterations * (j + 1) ~/ o.jobs;
    final mode = o.mode;
    final seed = o.seed;
    jobs.add(
      Isolate.run(
        () => CodecFuzzer(mode: mode, seed: seed, shard: j).run(end - start),
      ),
    );
  }
  final reports = await Future.wait(jobs);
  watch.stop();
  final total = reports.reduce((a, b) => a..add(b));
  final seconds = watch.elapsedMilliseconds / 1000;
  stdout
    ..writeln(
      'codec fuzz: mode ${o.mode}, seed ${o.seed}, jobs ${o.jobs}, '
      '${total.iterations} inputs in ${seconds.toStringAsFixed(1)} s '
      '(${(total.iterations / max(seconds, 0.001) / 1e6).toStringAsFixed(2)} '
      'M/s)',
    )
    ..writeln('  random ${total.random}, mutated ${total.mutated}')
    ..writeln(
      '  decoded ${total.decoded} (round trips checked), '
      'ignored ${total.ignored}, rejected ${total.rejected}',
    )
    ..writeln(
      '  rejected by reason: ${total.reasons.entries.map((e) => '${e.key} ${e.value}').join(', ')}',
    )
    ..writeln(
      '  decoded by type: ${total.byType.entries.map((e) => '0x${e.key.toRadixString(16).padLeft(2, '0')} ${e.value}').join(', ')}',
    )
    ..writeln(
      '  bytes decoded ${total.bytes}, longest decode '
      '${total.maxDecodeMicros} us, over 1 ms on first try '
      '${total.slowFirstTry} (all re-timed under 1 ms: '
      '${total.failures.where((f) => f.kind == 'slow').isEmpty})',
    );
  final counts = total.failureCounts;
  if (counts.isEmpty) {
    stdout.writeln('  failures: none');
    return 0;
  }
  stdout.writeln(
    '  FAILURES: ${counts.entries.map((e) => '${e.key} ${e.value}').join(', ')}',
  );
  final dir = Directory(o.out)..createSync(recursive: true);
  var n = 0;
  for (final f in total.failures) {
    final file = File(
      '${dir.path}/codec-${o.mode}-seed${o.seed}-shard${f.shard}-${n++}-${f.kind}.txt',
    );
    file.writeAsStringSync(
      'kind: ${f.kind}\n'
      'detail: ${f.detail}\n'
      'shard: ${f.shard} of ${o.jobs}, iteration ${f.iteration}\n'
      'original length: ${f.originalLength}\n'
      'minimized (${f.bytes.length} bytes, hex):\n${_hex(f.bytes)}\n',
    );
    stdout.writeln('  wrote ${file.path}');
  }
  return 1;
}

String _hex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

/// One minimized failing input.
final class CodecFailure {
  CodecFailure(
    this.kind,
    this.detail,
    this.bytes,
    this.shard,
    this.iteration,
    this.originalLength,
  );

  final String kind;
  final String detail;
  final Uint8List bytes;
  final int shard;
  final int iteration;
  final int originalLength;
}

final class CodecReport {
  int iterations = 0;
  int random = 0;
  int mutated = 0;
  int decoded = 0;
  int ignored = 0;
  int rejected = 0;
  int bytes = 0;
  int maxDecodeMicros = 0;
  int slowFirstTry = 0;
  final Map<String, int> reasons = {};
  final Map<int, int> byType = {};
  final Map<String, int> failureCounts = {};
  final List<CodecFailure> failures = [];

  CodecReport add(CodecReport o) {
    iterations += o.iterations;
    random += o.random;
    mutated += o.mutated;
    decoded += o.decoded;
    ignored += o.ignored;
    rejected += o.rejected;
    bytes += o.bytes;
    maxDecodeMicros = max(maxDecodeMicros, o.maxDecodeMicros);
    slowFirstTry += o.slowFirstTry;
    o.reasons.forEach((k, v) => reasons[k] = (reasons[k] ?? 0) + v);
    o.byType.forEach((k, v) => byType[k] = (byType[k] ?? 0) + v);
    o.failureCounts.forEach(
      (k, v) => failureCounts[k] = (failureCounts[k] ?? 0) + v,
    );
    failures.addAll(o.failures);
    return this;
  }
}

/// The v1 body length of each known type (codec.dart's table, restated so
/// a change there shows up here as a classification failure).
const Map<int, int> bodyBytes = {
  MessageType.hostHello: 33,
  MessageType.hello: 22,
  MessageType.bye: 1,
  MessageType.hostState: 4,
  MessageType.surface: 10,
  MessageType.ping: 12,
  MessageType.pong: 12,
  MessageType.pointerMove: 15,
  MessageType.pointerButton: 13,
  MessageType.wheel: 15,
  MessageType.key: 11,
  MessageType.text: 6,
  MessageType.releaseAll: 4,
};

final List<int> knownTypes = bodyBytes.keys.toList();

/// Field kinds, for structure-aware mutation.
enum F { u8, enum8, u16, len16, i16, u32, seq, u64, nonce }

/// Each type's fields after the header: (offset, kind).
const Map<int, List<(int, F)>> layouts = {
  MessageType.hostHello: [
    (3, F.u8),
    (4, F.u8),
    (5, F.nonce),
    (21, F.enum8),
    (22, F.u32),
    (26, F.u16),
    (28, F.u32),
    (32, F.u32),
  ],
  MessageType.hello: [(3, F.u8), (4, F.nonce), (20, F.enum8), (21, F.u32)],
  MessageType.bye: [(3, F.enum8)],
  MessageType.hostState: [(3, F.enum8), (4, F.enum8), (5, F.u16)],
  MessageType.surface: [(3, F.u16), (5, F.u32), (9, F.u32)],
  MessageType.ping: [(3, F.u32), (7, F.u64)],
  MessageType.pong: [(3, F.u32), (7, F.u64)],
  MessageType.pointerMove: [
    (3, F.seq),
    (7, F.u16),
    (9, F.u16),
    (11, F.u16),
    (13, F.u8),
    (14, F.seq),
  ],
  MessageType.pointerButton: [
    (3, F.seq),
    (7, F.u16),
    (9, F.u16),
    (11, F.u16),
    (13, F.enum8),
    (14, F.enum8),
    (15, F.u8),
  ],
  MessageType.wheel: [
    (3, F.seq),
    (7, F.u16),
    (9, F.u16),
    (11, F.u16),
    (13, F.i16),
    (15, F.i16),
    (17, F.enum8),
  ],
  MessageType.key: [(3, F.seq), (7, F.u32), (11, F.enum8), (12, F.u16)],
  MessageType.text: [(3, F.seq), (7, F.len16)],
  MessageType.releaseAll: [(3, F.seq)],
};

const List<int> interesting8 = [0, 1, 2, 3, 4, 5, 6, 7, 0x7F, 0x80, 0xFE, 0xFF];
const List<int> interesting16 = [
  0,
  1,
  2,
  0x7F,
  0x80,
  0xFF,
  0x100,
  1023,
  1024,
  1025,
  2048,
  0x7FFF,
  0x8000,
  0xFFFE,
  0xFFFF,
];
const List<int> interesting32 = [
  0,
  1,
  2,
  0x7FFFFFFE,
  0x7FFFFFFF,
  0x80000000,
  0x80000001,
  0xFFFFFFFE,
  0xFFFFFFFF,
];

/// Byte sequences that stress a UTF-8 decoder.
const List<List<int>> utf8Traps = [
  [0xC0, 0x80], // overlong NUL
  [0xE0, 0x80, 0x80], // overlong
  [0xED, 0xA0, 0x80], // a surrogate, encoded
  [0xED, 0xBF, 0xBF], // a low surrogate, encoded
  [0xF4, 0x90, 0x80, 0x80], // past U+10FFFF
  [0xF8, 0x88, 0x80, 0x80, 0x80], // five bytes
  [0x80], // a lone continuation byte
  [0xE2, 0x82], // truncated
  [0xEF, 0xBB, 0xBF], // BOM
  [0xEF, 0xBF, 0xBF], // U+FFFF
  [0xEF, 0xBF, 0xBD], // U+FFFD
  [0x00], // NUL
  [0x1B], // Escape
  [0xC2, 0x9B], // CSI
  [0xF0, 0x9F, 0x98, 0x80], // an emoji
  [0xFF],
];

final class CodecFuzzer {
  CodecFuzzer({required this.mode, required int seed, required this.shard})
    : rng = Random(_mix(seed, shard));

  final String mode;
  final int shard;
  final Random rng;
  final CodecReport report = CodecReport();
  final Stopwatch _clock = Stopwatch()..start();
  late final int _ticksPerMicro = max(1, _clock.frequency ~/ 1000000);
  late final Uint8List _pool = _randomBytes(1 << 20);
  late final List<Uint8List> _corpus = [
    for (var i = 0; i < 4096; i++) _validMessage(),
  ];
  int _iteration = 0;

  static const int _maxFailuresKept = 8;

  CodecReport run(int iterations) {
    for (var i = 0; i < iterations; i++) {
      _iteration = i;
      final mutate = switch (mode) {
        'random' => false,
        'mutate' => true,
        _ => i.isOdd,
      };
      final bytes = mutate ? _mutated() : _random();
      if (mutate) {
        report.mutated++;
      } else {
        report.random++;
      }
      _check(bytes);
    }
    report.iterations = iterations;
    return report;
  }

  // --- Invariants -----------------------------------------------------------

  void _check(Uint8List bytes) {
    final t0 = _clock.elapsedTicks;
    final DecodeResult result;
    try {
      result = decodeMessage(bytes);
    } catch (e) {
      _fail('throws', e.runtimeType.toString(), bytes);
      return;
    }
    final micros = (_clock.elapsedTicks - t0) ~/ _ticksPerMicro;
    report.bytes += bytes.length;
    if (micros > report.maxDecodeMicros) report.maxDecodeMicros = micros;
    if (micros >= 1000) {
      report.slowFirstTry++;
      // A GC pause or a descheduled isolate can stretch one decode: only a
      // decode that's slow every time counts.
      if (_fastestMicros(bytes) >= 1000) _fail('slow', '>= 1 ms', bytes);
    }
    final problem = _problem(bytes, result);
    if (problem != null) _fail(problem.$1, problem.$2, bytes);
    switch (result) {
      case Decoded(:final message):
        report.decoded++;
        report.byType[message.type] = (report.byType[message.type] ?? 0) + 1;
      case DecodeIgnored():
        report.ignored++;
      case DecodeFailed(:final error):
        report.rejected++;
        report.reasons[error.name] = (report.reasons[error.name] ?? 0) + 1;
    }
  }

  int _fastestMicros(Uint8List bytes) {
    var best = 1 << 30;
    for (var i = 0; i < 20; i++) {
      final t = _clock.elapsedTicks;
      decodeMessage(bytes);
      best = min(best, (_clock.elapsedTicks - t) ~/ _ticksPerMicro);
    }
    return best;
  }

  /// What's wrong with [result] for [bytes], or `null`. Pure, so the
  /// minimizer can call it.
  static (String, String)? _problem(Uint8List bytes, DecodeResult? result) {
    final type = bytes.isEmpty ? -1 : bytes[0];
    final body = bodyBytes[type];
    switch (result) {
      case null:
        return ('throws', 'no result');
      case DecodeIgnored(type: final t):
        if (body != null || t != type || t < MessageType.firstIgnorable) {
          return ('classification', 'ignored a type it should not');
        }
        if (bytes.length < headerBytes) {
          return ('classification', 'ignored a message shorter than a header');
        }
        return null;
      case DecodeFailed(:final error):
        final short =
            bytes.length < headerBytes ||
            (body != null && bytes.length < headerBytes + body);
        switch (error) {
          case DecodeError.tooShort:
            if (!short) return ('classification', 'tooShort but long enough');
          case DecodeError.unknownType:
            if (short && bytes.length < headerBytes) {
              return ('classification', 'unknownType for a short header');
            }
            if (body != null || type >= MessageType.firstIgnorable) {
              return ('classification', 'unknownType for a defined type');
            }
          case DecodeError.badValue:
            if (short || body == null) {
              return ('classification', 'badValue without a full body');
            }
        }
        return null;
      case Decoded(:final sessionTag, :final message):
        if (body == null || message.type != type) {
          return ('classification', 'decoded as another type');
        }
        if (bytes.length < headerBytes + body) {
          return ('classification', 'decoded a short body');
        }
        if (sessionTag != (bytes[1] | bytes[2] << 8)) {
          return ('classification', 'wrong session tag');
        }
        final Uint8List again;
        try {
          again = encodeMessage(message, sessionTag: sessionTag);
        } catch (e) {
          return ('encodeThrows', e.runtimeType.toString());
        }
        final DecodeResult second;
        try {
          second = decodeMessage(again);
        } catch (e) {
          return ('roundTrip', 're-decode threw ${e.runtimeType}');
        }
        if (second is! Decoded ||
            second.sessionTag != sessionTag ||
            !sameMessage(second.message, message)) {
          return ('roundTrip', 're-encoded bytes decode to another message');
        }
        final third = encodeMessage(second.message, sessionTag: sessionTag);
        if (!_equalBytes(third, again)) {
          return ('roundTrip', 'encoding is not stable');
        }
        if (_exact.contains(type) &&
            !_equalBytes(
              again,
              Uint8List.sublistView(bytes, 0, again.length),
            )) {
          return ('lossy', 'decoded fields differ from the bytes');
        }
        return null;
    }
  }

  /// Types whose decode keeps every byte of the v1 body, so re-encoding
  /// gives the input's first bytes back. (Bye, the platforms and the u64s
  /// normalize by design.)
  static const Set<int> _exact = {
    MessageType.hostState,
    MessageType.surface,
    MessageType.pointerMove,
    MessageType.pointerButton,
    MessageType.wheel,
    MessageType.key,
    MessageType.text,
    MessageType.releaseAll,
  };

  void _fail(String kind, String detail, Uint8List bytes) {
    report.failureCounts[kind] = (report.failureCounts[kind] ?? 0) + 1;
    if (report.failures.where((f) => f.kind == kind).length >=
        _maxFailuresKept) {
      return;
    }
    final min = kind == 'slow'
        ? Uint8List.fromList(bytes)
        : _minimize(bytes, (b) => _kindOf(b) == kind);
    report.failures.add(
      CodecFailure(kind, detail, min, shard, _iteration, bytes.length),
    );
  }

  static String? _kindOf(Uint8List b) {
    DecodeResult r;
    try {
      r = decodeMessage(b);
    } catch (_) {
      return 'throws';
    }
    return _problem(b, r)?.$1;
  }

  /// Shrinks [bytes] while [fails] holds: shorter, then fewer bytes, then
  /// zeros. Bounded.
  static Uint8List _minimize(Uint8List bytes, bool Function(Uint8List) fails) {
    var best = Uint8List.fromList(bytes);
    var budget = 20000;
    bool tryCandidate(Uint8List c) {
      if (budget-- <= 0) return false;
      if (fails(c)) {
        best = c;
        return true;
      }
      return false;
    }

    for (var chunk = best.length ~/ 2; chunk >= 1; chunk ~/= 2) {
      var i = 0;
      while (i < best.length && budget > 0) {
        final end = min(best.length, i + chunk);
        final c = Uint8List(best.length - (end - i))
          ..setRange(0, i, best)
          ..setRange(i, best.length - (end - i), best, end);
        if (!tryCandidate(c)) i += chunk;
      }
    }
    for (var i = 0; i < best.length && budget > 0; i++) {
      if (best[i] == 0) continue;
      tryCandidate(Uint8List.fromList(best)..[i] = 0);
    }
    return best;
  }

  // --- Random inputs --------------------------------------------------------

  Uint8List _random() {
    final len = _randomLength();
    final pool = _pool;
    // Keep the pool changing, deterministically.
    for (var k = 0; k < 4; k++) {
      pool[rng.nextInt(pool.length)] = rng.nextInt(256);
    }
    final off = rng.nextInt(pool.length - len);
    final r = rng.nextInt(10);
    if (len > 0) {
      if (r < 6) {
        pool[off] = knownTypes[rng.nextInt(knownTypes.length)];
      } else if (r < 7) {
        pool[off] = MessageType.firstIgnorable + rng.nextInt(64);
      }
      if (pool[off] == MessageType.text && len >= headerBytes + 6) {
        // Often a consistent length, so UTF-8 decoding is reached.
        if (rng.nextBool()) {
          final n = min(len - headerBytes - 6, 0xFFFF);
          pool[off + 7] = n & 0xFF;
          pool[off + 8] = n >> 8;
          if (rng.nextBool()) {
            for (var i = off + 9; i < off + len; i++) {
              pool[i] &= 0x7F; // ASCII
            }
          }
        }
      }
    }
    final view = Uint8List.sublistView(pool, off, off + len);
    // Mostly views into the pool (an offset buffer), sometimes a fresh list.
    return rng.nextInt(10) == 0 ? Uint8List.fromList(view) : view;
  }

  int _randomLength() {
    final r = rng.nextInt(100);
    if (r < 45) return rng.nextInt(48);
    if (r < 65) {
      switch (rng.nextInt(4)) {
        case 0:
          return rng.nextInt(4);
        case 1:
          final body = bodyBytes[knownTypes[rng.nextInt(knownTypes.length)]]!;
          return headerBytes + body + rng.nextInt(3) - 1;
        case 2:
          return const [9, 10, 1032, 1033, 1034][rng.nextInt(5)];
        default:
          return const [2047, 2048, 2049, 4095, 4096, 4097, 5120][rng.nextInt(
            7,
          )];
      }
    }
    if (r < 90) return 48 + rng.nextInt(1100 - 48);
    return 1100 + rng.nextInt(5120 - 1100 + 1);
  }

  Uint8List _randomBytes(int n) {
    final b = Uint8List(n);
    final words = Uint32List.view(b.buffer);
    for (var i = 0; i < words.length; i++) {
      words[i] = rng.nextInt(1 << 32);
    }
    return b;
  }

  // --- Structure-aware mutation ---------------------------------------------

  Uint8List _mutated() {
    var b = Uint8List.fromList(_corpus[rng.nextInt(_corpus.length)]);
    final ops = 1 + rng.nextInt(rng.nextInt(4) + 1);
    for (var k = 0; k < ops; k++) {
      b = _mutateOnce(b);
    }
    return b;
  }

  Uint8List _mutateOnce(Uint8List b) {
    final len = b.length;
    switch (rng.nextInt(13)) {
      case 0: // flip a bit
        if (len > 0) b[rng.nextInt(len)] ^= 1 << rng.nextInt(8);
        return b;
      case 1: // a random byte
        if (len > 0) b[rng.nextInt(len)] = rng.nextInt(256);
        return b;
      case 2: // an interesting byte
        if (len > 0) {
          b[rng.nextInt(len)] = interesting8[rng.nextInt(interesting8.length)];
        }
        return b;
      case 3: // truncate, often to a boundary
        final type = len > 0 ? b[0] : 0;
        final body = bodyBytes[type];
        final n = switch (rng.nextInt(3)) {
          0 => rng.nextInt(len + 1),
          1 => rng.nextInt(4),
          _ => body == null ? rng.nextInt(len + 1) : headerBytes + body - 1,
        };
        return Uint8List.sublistView(b, 0, min(len, max(0, n)));
      case 4: // extend: trailing bytes, or up to a size limit
        final target = switch (rng.nextInt(3)) {
          0 => len + 1 + rng.nextInt(16),
          1 => const [1033, 2048, 2049, 4096, 4097, 5120][rng.nextInt(6)],
          _ => len + rng.nextInt(1100),
        };
        if (target <= len) return b;
        final c = Uint8List(target)..setRange(0, len, b);
        final fill = rng.nextInt(3);
        for (var i = len; i < target; i++) {
          c[i] = fill == 0 ? 0 : (fill == 1 ? 0xFF : rng.nextInt(256));
        }
        return c;
      case 5: // splice two messages
        final other = _corpus[rng.nextInt(_corpus.length)];
        final cut = rng.nextInt(len + 1);
        final from = rng.nextInt(other.length + 1);
        return Uint8List(cut + other.length - from)
          ..setRange(0, cut, b)
          ..setRange(cut, cut + other.length - from, other, from);
      case 6:
      case 7:
      case 8: // a field to a boundary or an undefined value
        return _mutateField(b);
      case 9: // another type with this body
        if (len == 0) return b;
        b[0] = switch (rng.nextInt(4)) {
          0 => knownTypes[rng.nextInt(knownTypes.length)],
          1 => MessageType.firstIgnorable + rng.nextInt(64),
          2 => const [0x00, 0x08, 0x0F, 0x13, 0x1F, 0x23, 0xBF][rng.nextInt(7)],
          _ => rng.nextInt(256),
        };
        return b;
      case 10: // insert bytes
        final at = rng.nextInt(len + 1);
        final n = 1 + rng.nextInt(8);
        final c = Uint8List(len + n)
          ..setRange(0, at, b)
          ..setRange(at + n, len + n, b, at);
        for (var i = at; i < at + n; i++) {
          c[i] = rng.nextInt(256);
        }
        return c;
      case 11: // delete a range
        if (len == 0) return b;
        final at = rng.nextInt(len);
        final n = 1 + rng.nextInt(min(8, len - at));
        return Uint8List(len - n)
          ..setRange(0, at, b)
          ..setRange(at, len - n, b, at + n);
      default: // UTF-8 traps in a text body, with the length kept consistent
        return _mutateText(b);
    }
  }

  Uint8List _mutateField(Uint8List b) {
    if (b.isEmpty) return b;
    final fields = layouts[b[0]];
    if (fields == null) return b;
    final (off, kind) = fields[rng.nextInt(fields.length)];
    final data = ByteData.sublistView(b);
    void put(int width, int v) {
      if (off + width > b.length) return;
      switch (width) {
        case 1:
          data.setUint8(off, v & 0xFF);
        case 2:
          data.setUint16(off, v & 0xFFFF, Endian.little);
        case 4:
          data.setUint32(off, v & 0xFFFFFFFF, Endian.little);
      }
    }

    switch (kind) {
      case F.u8:
        put(1, interesting8[rng.nextInt(interesting8.length)]);
      case F.enum8:
        // Just past the defined codes, or anywhere.
        put(1, rng.nextBool() ? rng.nextInt(16) : rng.nextInt(256));
      case F.u16:
      case F.i16:
        put(2, interesting16[rng.nextInt(interesting16.length)]);
      case F.len16:
        final actual = max(0, b.length - 9);
        put(2, switch (rng.nextInt(4)) {
          0 => actual + rng.nextInt(3) - 1,
          1 => const [0, 1, 1023, 1024, 1025, 0x7FFF, 0xFFFF][rng.nextInt(7)],
          2 => rng.nextInt(0x10000),
          _ => actual,
        });
      case F.u32:
        put(4, interesting32[rng.nextInt(interesting32.length)]);
      case F.seq:
        // Near the wrap and the half-way point of serial arithmetic.
        put(
          4,
          rng.nextBool()
              ? interesting32[rng.nextInt(interesting32.length)]
              : 0xFFFFFFF0 + rng.nextInt(0x20),
        );
      case F.u64:
        put(4, interesting32[rng.nextInt(interesting32.length)]);
        if (off + 8 <= b.length) {
          data.setUint32(
            off + 4,
            interesting32[rng.nextInt(interesting32.length)],
            Endian.little,
          );
        }
      case F.nonce:
        if (off + nonceBytes <= b.length) {
          final i = off + rng.nextInt(nonceBytes);
          b[i] ^= 1 + rng.nextInt(255);
        }
    }
    return b;
  }

  Uint8List _mutateText(Uint8List b) {
    if (b.length < 9 || b[0] != MessageType.text) {
      // Make it a text message first.
      final text = _textBytes(rng.nextInt(32));
      b = _encodeRawText(rng.nextInt(1 << 32), text);
    }
    final body = b.sublist(9);
    final trap = utf8Traps[rng.nextInt(utf8Traps.length)];
    final at = rng.nextInt(body.length + 1);
    final text = <int>[...body.sublist(0, at), ...trap, ...body.sublist(at)];
    final seq = ByteData.sublistView(b).getUint32(3, Endian.little);
    final out = _encodeRawText(
      seq,
      text.length > 1100 ? text.sublist(0, 1100) : text,
    );
    out[1] = b[1];
    out[2] = b[2];
    return out;
  }

  static Uint8List _encodeRawText(int seq, List<int> text) {
    final b = Uint8List(9 + text.length);
    ByteData.sublistView(b)
      ..setUint8(0, MessageType.text)
      ..setUint32(3, seq, Endian.little)
      ..setUint16(7, text.length, Endian.little);
    b.setRange(9, b.length, text);
    return b;
  }

  // --- Valid messages -------------------------------------------------------

  int _u(int bits) => switch (rng.nextInt(4)) {
    0 => const [0, 1][rng.nextInt(2)],
    1 => (1 << bits) - 1 - rng.nextInt(2),
    _ => bits == 32 ? rng.nextInt(1 << 32) : rng.nextInt(1 << bits),
  };

  int _seq() => switch (rng.nextInt(4)) {
    0 => 0xFFFFFFFF - rng.nextInt(16),
    1 => interesting32[rng.nextInt(interesting32.length)],
    _ => rng.nextInt(1 << 32),
  };

  Uint8List _nonce() =>
      Uint8List.fromList(List.generate(nonceBytes, (_) => rng.nextInt(256)));

  T _pick<T>(List<T> values) => values[rng.nextInt(values.length)];

  List<int> _textBytes(int maxBytes) => utf8.encode(_text(maxBytes));

  String _text(int maxBytes) {
    // dart format off
    const pieces = [
      'a', 'Z', '0', ' ', '\t', '\n', '\r', '\x1B', '\x08', '\x7F',
      '\u0085', 'é', 'ß', '€', 'ж', '中', '日本', '한', '\u{1F600}',
      '\u{1F468}\u200D\u{1F469}', '\u0301', '\uFEFF', '\uFFFD',
      '\u{10FFFF}', '\u200B',
    ];
    // dart format on
    final sb = StringBuffer();
    var bytes = 0;
    final target = rng.nextInt(maxBytes + 1);
    while (true) {
      final p = _pick(pieces);
      final n = utf8.encode(p).length;
      if (bytes + n > target) break;
      sb.write(p);
      bytes += n;
    }
    return sb.toString();
  }

  Uint8List _validMessage() {
    final tag = rng.nextInt(1 << 16);
    final type = _pick(knownTypes);
    final WireMessage m = switch (type) {
      MessageType.hostHello => () {
        final nonce = _nonce();
        nonce[0] = tag & 0xFF;
        nonce[1] = tag >> 8;
        return HostHello(
          minVersion: _u(8),
          maxVersion: _u(8),
          nonce: nonce,
          hostPlatform: _pick(PeerPlatform.values),
          capabilities: _u(32),
          surfaceEpoch: _u(16),
          surfaceWidth: _u(32),
          surfaceHeight: _u(32),
        );
      }(),
      MessageType.hello => Hello(
        version: _u(8),
        nonce: _nonce(),
        viewerPlatform: _pick(PeerPlatform.values),
        capabilities: _u(32),
      ),
      MessageType.bye => Bye(_pick(ByeReason.values)),
      MessageType.hostState => HostState(
        state: _pick(HostStateCode.values),
        reason: _u(8),
        surfaceEpoch: _u(16),
      ),
      MessageType.surface => SurfaceMessage(
        surfaceEpoch: _u(16),
        width: _u(32),
        height: _u(32),
      ),
      MessageType.ping => Ping(id: _u(32), viewerMicros: _u53()),
      MessageType.pong => Pong(id: _u(32), viewerMicros: _u53()),
      MessageType.pointerMove => PointerMove(
        _seq(),
        surfaceEpoch: _u(16),
        x: _u(16),
        y: _u(16),
        buttons: _u(8),
        reliableSeq: _seq(),
      ),
      MessageType.pointerButton => PointerButtonMessage(
        _seq(),
        surfaceEpoch: _u(16),
        x: _u(16),
        y: _u(16),
        button: _pick(PointerButton.values),
        down: rng.nextBool(),
        clickCount: _u(8),
      ),
      MessageType.wheel => Wheel(
        _seq(),
        surfaceEpoch: _u(16),
        x: _u(16),
        y: _u(16),
        dx: _u(16) - 0x8000,
        dy: _u(16) - 0x8000,
        unit: _pick(WheelUnit.values),
      ),
      MessageType.key => KeyMessage(
        _seq(),
        usage: rng.nextBool() ? 0x00070000 + rng.nextInt(0x100) : _u(32),
        action: _pick(KeyAction.values),
        modifiers: _u(16),
      ),
      MessageType.text => TextMessage(
        _seq(),
        _text(rng.nextInt(8) == 0 ? maxTextBytes : 48),
      ),
      _ => ReleaseAll(_seq()),
    };
    final bytes = encodeMessage(m, sessionTag: tag);
    if (rng.nextInt(8) == 0) {
      // A later v1 minor's trailing fields.
      return Uint8List(bytes.length + 1 + rng.nextInt(8))
        ..setRange(0, bytes.length, bytes);
    }
    return bytes;
  }

  int _u53() => switch (rng.nextInt(3)) {
    0 => 0,
    1 => 0x1FFFFFFFFFFFFF,
    _ => rng.nextInt(1 << 32) * 0x200000 + rng.nextInt(0x200000),
  };
}

int _mix(int seed, int shard) {
  // SplitMix-style, kept within 32 bits for Random().
  var z = (seed * 0x9E3779B1 + shard * 0x85EBCA77 + 0x165667B1) & 0xFFFFFFFF;
  z = ((z ^ (z >> 16)) * 0x7FEB352D) & 0xFFFFFFFF;
  z = ((z ^ (z >> 15)) * 0x846CA68B) & 0xFFFFFFFF;
  return z ^ (z >> 16);
}

bool _equalBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Whether two decoded messages are equal, field by field.
bool sameMessage(WireMessage a, WireMessage b) {
  final fa = fieldsOf(a);
  final fb = fieldsOf(b);
  if (fa.length != fb.length) return false;
  for (var i = 0; i < fa.length; i++) {
    final x = fa[i];
    final y = fb[i];
    if (x is Uint8List && y is Uint8List) {
      if (!_equalBytes(x, y)) return false;
    } else if (x != y) {
      return false;
    }
  }
  return true;
}

List<Object> fieldsOf(WireMessage m) => switch (m) {
  HostHello m => [
    m.type,
    m.minVersion,
    m.maxVersion,
    m.nonce,
    m.hostPlatform,
    m.capabilities,
    m.surfaceEpoch,
    m.surfaceWidth,
    m.surfaceHeight,
  ],
  Hello m => [m.type, m.version, m.nonce, m.viewerPlatform, m.capabilities],
  Bye m => [m.type, m.reason],
  HostState m => [m.type, m.state, m.reason, m.surfaceEpoch],
  SurfaceMessage m => [m.type, m.surfaceEpoch, m.width, m.height],
  Ping m => [m.type, m.id, m.viewerMicros],
  Pong m => [m.type, m.id, m.viewerMicros],
  PointerMove m => [
    m.type,
    m.seq,
    m.surfaceEpoch,
    m.x,
    m.y,
    m.buttons,
    m.reliableSeq,
  ],
  PointerButtonMessage m => [
    m.type,
    m.seq,
    m.surfaceEpoch,
    m.x,
    m.y,
    m.button,
    m.down,
    m.clickCount,
  ],
  Wheel m => [m.type, m.seq, m.surfaceEpoch, m.x, m.y, m.dx, m.dy, m.unit],
  KeyMessage m => [m.type, m.seq, m.usage, m.action, m.modifiers],
  TextMessage m => [m.type, m.seq, m.text],
  ReleaseAll m => [m.type, m.seq],
};
