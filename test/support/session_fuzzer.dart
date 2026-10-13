// A fuzzer for ControlSession (RIN-18; docs/design.md §12): long random
// sequences of valid, malformed and hostile messages, time, host calls and
// environment changes, with the session's safety invariants checked after
// every step and at every injected event.
//
// Sequences are data (a Setup and a list of Steps) generated from a seed, so
// a failing one replays exactly and can be shrunk.
//
// Nothing here prints key codes, text or positions: failures name the
// invariant; the steps (random data, not anyone's input) go to a file.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/src/host/session.dart' show debugSessionHeld;
import 'package:remote_input/src/protocol/codec.dart';
import 'package:remote_input/src/protocol/messages.dart';
import 'package:remote_input/testing.dart';

/// The nonce the generator writes into messages. The runner maps it (and
/// its tag) onto the session's real, random nonce by XOR, a bijection, so a
/// sequence behaves the same whatever nonce the session drew.
final Uint8List virtualNonce = Uint8List.fromList(
  List.generate(nonceBytes, (i) => 0xA0 + i),
);
final int virtualTag = sessionTagOf(virtualNonce);

const int _window = 7;

/// FakeSurfaceResolver's default display.
const Rect _display = Rect.fromLTWH(0, 0, 1920, 1080);

// --- Sequences as data -------------------------------------------------------

/// How the session is enabled.
final class Setup {
  Setup({
    required this.surface,
    required this.insets,
    required this.hostIsMac,
    required this.allowKeyboard,
    required this.manualResume,
    required this.localIdleMs,
    required this.heartbeatMs,
    required this.noModifierMapping,
    required this.filter,
    required this.protectHostWindows,
    required this.expiresInMs,
    required this.limits,
  });

  factory Setup.fromJson(Map<String, Object?> j) => Setup(
    surface: j['surface']! as int,
    insets: j['insets']! as int,
    hostIsMac: j['hostIsMac']! as bool,
    allowKeyboard: j['allowKeyboard']! as bool,
    manualResume: j['manualResume']! as bool,
    localIdleMs: j['localIdleMs']! as int,
    heartbeatMs: j['heartbeatMs']! as int,
    noModifierMapping: j['noModifierMapping']! as bool,
    filter: j['filter']! as bool,
    protectHostWindows: j['protectHostWindows']! as bool,
    expiresInMs: j['expiresInMs'] as int?,
    limits: (j['limits'] as List<Object?>?)?.cast<int>(),
  );

  /// 0 display, 1 window, 2 rect.
  final int surface;

  /// 0 none, 1 small, 2 larger than the surface.
  final int insets;
  final bool hostIsMac;
  final bool allowKeyboard;
  final bool manualResume;
  final int localIdleMs;
  final int heartbeatMs;
  final bool noModifierMapping;
  final bool filter;
  final bool protectHostWindows;
  final int? expiresInMs;

  /// InputLimits' ten values in constructor order, or null for defaults.
  final List<int>? limits;

  InputLimits get inputLimits {
    final l = limits;
    if (l == null) return InputLimits();
    return InputLimits(
      maxMessageBytes: l[0],
      textRate: l[1],
      textBurst: l[2],
      moveRate: l[3],
      eventRate: l[4],
      eventBurst: l[5],
      maxWheelPixels: l[6],
      maxWheelLines: l[7],
      maxHeldKeys: l[8],
      maxQueuedEvents: l[9],
    );
  }

  Map<String, Object?> toJson() => {
    'surface': surface,
    'insets': insets,
    'hostIsMac': hostIsMac,
    'allowKeyboard': allowKeyboard,
    'manualResume': manualResume,
    'localIdleMs': localIdleMs,
    'heartbeatMs': heartbeatMs,
    'noModifierMapping': noModifierMapping,
    'filter': filter,
    'protectHostWindows': protectHostWindows,
    'expiresInMs': expiresInMs,
    'limits': limits,
  };
}

/// One thing that happens to the session.
sealed class Step {
  const Step();

  factory Step.fromJson(Map<String, Object?> j) => switch (j['k']) {
    'send' => Send(_unhex(j['bytes']! as String), j['reliable']! as bool),
    'elapse' => Elapse(j['us']! as int),
    'host' => HostCall(HostAction.values.byName(j['a']! as String)),
    _ => EnvChange(EnvAction.values.byName(j['a']! as String), j['v']! as int),
  };

  Map<String, Object?> toJson();
}

/// The viewer sends [bytes] (with the virtual nonce) on one channel.
final class Send extends Step {
  const Send(this.bytes, this.reliable);

  final Uint8List bytes;
  final bool reliable;

  @override
  Map<String, Object?> toJson() => {
    'k': 'send',
    'reliable': reliable,
    'bytes': _hex(bytes),
  };
}

/// Fake time passes.
final class Elapse extends Step {
  const Elapse(this.micros);

  final int micros;

  @override
  Map<String, Object?> toJson() => {'k': 'elapse', 'us': micros};
}

/// What the host app (or the person at the host) does.
enum HostAction {
  pause,
  resume,
  stop,
  stopAll,
  localInput,
  closeLink,
  toDisplay,
  toWindow,
  toRect,
}

/// The host app calls something.
final class HostCall extends Step {
  const HostCall(this.action);

  final HostAction action;

  @override
  Map<String, Object?> toJson() => {'k': 'host', 'a': action.name};
}

/// What changes in the fake OS.
enum EnvAction {
  /// 0 everything injects; 1 presses fail; 2 presses hit an elevated
  /// target; 3 everything fails, releases too; 4 presses lose the
  /// permission; 5 keys are unmapped.
  injector,

  /// 0 none, else BlockReason.values[v - 1].
  securePointer,
  secureKeyboard,
  monitorHealthy,
  keyboardFocus,
  occluded,
  ownWindow,
  ownAppInFront,

  /// 0 gone, 1 normal, 2 hidden, 3 empty, 4 moved.
  windowGeometry,
  closeRect,
}

/// The environment changes.
final class EnvChange extends Step {
  const EnvChange(this.action, this.value);

  final EnvAction action;
  final int value;

  @override
  Map<String, Object?> toJson() => {'k': 'env', 'a': action.name, 'v': value};
}

String _hex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

// --- Generation --------------------------------------------------------------

const int _a = 0x00070004;
const int _r = 0x00070015;
const List<int> _usages = [
  _a,
  0x00070005,
  0x00070006,
  _r,
  0x00070028, // Enter
  0x0007002B, // Tab
  0x00070029, // Escape
  0x00070039, // Caps Lock
  HidModifier.controlLeft,
  HidModifier.shiftLeft,
  HidModifier.altLeft,
  HidModifier.metaLeft,
  HidModifier.controlRight,
  HidModifier.shiftRight,
  HidModifier.altRight,
  HidModifier.metaRight,
];

/// Generates one sequence from [rng].
final class SequenceGenerator {
  SequenceGenerator(this.rng);

  final Random rng;
  final List<Step> _steps = [];

  late int _seq;
  int? _lastReliable;
  final List<int> _sentReliable = [];
  final Set<int> _held = {};
  int _buttons = 0;
  int _epoch = 0;
  late int _profile;
  bool _stopped = false;

  /// Steps until the host resumes after a pause, or 0.
  int _resumeIn = 0;

  (Setup, List<Step>) generate() {
    final setup = _setup();
    _profile = rng.nextInt(4); // normal, hostile, flood, chaos
    _seq = switch (rng.nextInt(4)) {
      0 => 0,
      1 => 0xFFFFFFFF - rng.nextInt(64), // wraps soon
      2 => 0x7FFFFFF0 + rng.nextInt(32),
      _ => rng.nextInt(1 << 32),
    };
    if (rng.nextInt(10) != 0) {
      for (var i = rng.nextInt(3); i > 0; i--) {
        _one();
      }
      _hello();
    }
    final length = 20 + rng.nextInt(rng.nextInt(10) == 0 ? 1500 : 380);
    while (_steps.length < length) {
      _one();
      if (_resumeIn > 0 && --_resumeIn == 0) {
        _steps.add(const HostCall(HostAction.resume));
      }
    }
    return (setup, _steps);
  }

  Setup _setup() {
    int upTo(int cap, {int? small}) => rng.nextInt(3) == 0 && small != null
        ? 1 + rng.nextInt(small)
        : 1 + rng.nextInt(cap);
    return Setup(
      surface: const [0, 0, 0, 1, 2][rng.nextInt(5)],
      insets: const [0, 0, 0, 1, 2][rng.nextInt(5)],
      hostIsMac: rng.nextBool(),
      allowKeyboard: rng.nextInt(10) != 0,
      manualResume: rng.nextInt(4) == 0,
      localIdleMs: 50 + rng.nextInt(3000),
      heartbeatMs: 200 + rng.nextInt(8000),
      noModifierMapping: rng.nextInt(4) == 0,
      filter: rng.nextInt(3) == 0,
      protectHostWindows: rng.nextInt(5) != 0,
      expiresInMs: rng.nextInt(5) == 0 ? 1 + rng.nextInt(30000) : null,
      limits: rng.nextInt(3) != 0
          ? null
          : [
              upTo(4096, small: 64),
              upTo(1000, small: 8),
              upTo(2000, small: 8),
              upTo(500, small: 4),
              upTo(200, small: 4),
              upTo(400, small: 8),
              upTo(1200),
              upTo(10),
              upTo(16, small: 3),
              upTo(256, small: 24),
            ],
    );
  }

  int _next() {
    final s = _seq;
    _seq = (_seq + 1) & 0xFFFFFFFF;
    return s;
  }

  void _send(WireMessage m, {bool reliable = true, int? tag}) {
    if (m is InputMessage && m is! PointerMove && reliable) {
      _lastReliable = m.seq;
      _sentReliable.add(m.seq);
    }
    _steps.add(Send(encodeMessage(m, sessionTag: tag ?? virtualTag), reliable));
  }

  void _hello({int version = 1, Uint8List? nonce}) => _send(
    Hello(
      version: version,
      nonce: nonce ?? virtualNonce,
      viewerPlatform:
          PeerPlatform.values[rng.nextInt(PeerPlatform.values.length)],
      capabilities: rng.nextInt(4),
    ),
  );

  /// Weights per profile (normal, hostile, flood, chaos) for each kind.
  // dart format off
  static const List<List<int>> _weights = [
    // key, button, wheel, move, text, releaseAll, ping, seq anomaly,
    // random bytes, mutated, wrong tag, wrong channel, host-only, oversized,
    // ignorable, hello, bye, short/medium/long elapse, host call,
    // environment, input burst, violation burst
    [20, 10, 4, 25, 5, 1, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 0, 25, 8, 1, 3, 2, 1, 0],
    [6, 4, 2, 8, 3, 1, 4, 6, 8, 10, 6, 5, 5, 4, 3, 2, 0, 15, 6, 2, 2, 2, 1, 3],
    [10, 6, 6, 8, 6, 1, 6, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 10, 2, 0, 1, 1, 8, 0],
    [10, 6, 3, 12, 4, 2, 2, 3, 3, 3, 2, 2, 2, 2, 2, 2, 1, 15, 6, 2, 8, 8, 2, 1],
  ];
  // dart format on

  void _one() {
    final w = _weights[_profile];
    var r = rng.nextInt(w.fold(0, (a, b) => a + b));
    var kind = 0;
    while (r >= w[kind]) {
      r -= w[kind];
      kind++;
    }
    switch (kind) {
      case 0:
        _key();
      case 1:
        _button();
      case 2:
        _wheel();
      case 3:
        _move();
      case 4:
        _text();
      case 5:
        _send(ReleaseAll(_next()));
        _held.clear();
        _buttons = 0;
      case 6:
        _send(
          Ping(id: rng.nextInt(1 << 32), viewerMicros: rng.nextInt(1 << 32)),
        );
      case 7:
        _anomaly();
      case 8:
        _steps.add(Send(_randomBytes(rng.nextInt(64)), rng.nextBool()));
      case 9:
        _steps.add(Send(_mutated(), rng.nextInt(4) != 0));
      case 10:
        _send(
          KeyMessage(_next(), usage: _a, action: KeyAction.down, modifiers: 0),
          tag: virtualTag ^ (1 + rng.nextInt(0xFFFF)),
        );
      case 11:
        _send(
          _pick([
            KeyMessage(_next(), usage: _a, action: KeyAction.up, modifiers: 0),
            ReleaseAll(_next()),
            PointerButtonMessage(
              _next(),
              surfaceEpoch: _epoch,
              x: 1,
              y: 1,
              button: PointerButton.left,
              down: true,
              clickCount: 1,
            ),
          ]),
          reliable: false,
        );
      case 12:
        _send(
          _pick<WireMessage>([
            HostState(state: HostStateCode.stopped, reason: 1, surfaceEpoch: 0),
            const SurfaceMessage(surfaceEpoch: 0, width: 1, height: 1),
            const Pong(id: 1, viewerMicros: 1),
            HostHello(
              minVersion: 1,
              maxVersion: 1,
              nonce: virtualNonce,
              hostPlatform: PeerPlatform.macos,
              capabilities: 0,
              surfaceEpoch: 0,
              surfaceWidth: 1,
              surfaceHeight: 1,
            ),
          ]),
          reliable: rng.nextBool(),
        );
      case 13:
        final b = _randomBytes(2049 + rng.nextInt(3000));
        b[0] = MessageType.key;
        b[1] = virtualTag & 0xFF;
        b[2] = virtualTag >> 8;
        _steps.add(Send(b, true));
      case 14:
        final b = _randomBytes(3 + rng.nextInt(32));
        b[0] = MessageType.firstIgnorable + rng.nextInt(64);
        _steps.add(Send(b, rng.nextBool()));
      case 15:
        switch (rng.nextInt(4)) {
          case 0:
            _hello();
          case 1:
            _hello(version: 2 + rng.nextInt(254));
          case 2:
            _hello(nonce: Uint8List.fromList(virtualNonce)..[5] ^= 0x40);
          default:
            _hello(version: 0);
        }
      case 16:
        if (rng.nextInt(4) == 0) _send(const Bye(ByeReason.closed));
      case 17:
        _steps.add(Elapse(rng.nextInt(4) == 0 ? 0 : rng.nextInt(10000)));
      case 18:
        _steps.add(Elapse(10000 + rng.nextInt(1500000)));
      case 19:
        _steps.add(Elapse(1500000 + rng.nextInt(11000000)));
      case 20:
        _host();
      case 21:
        _env();
      case 22:
        final n = rng.nextBool()
            ? 10 + rng.nextInt(100)
            : 20 + rng.nextInt(300);
        final paced = rng.nextBool();
        for (var i = n; i > 0; i--) {
          if (paced && rng.nextInt(8) == 0) {
            _steps.add(Elapse(rng.nextInt(50000)));
          }
          switch (rng.nextInt(4)) {
            case 0:
              _key();
            case 1:
              _button();
            case 2:
              _wheel();
            default:
              _text();
          }
        }
      default:
        for (var i = 10 + rng.nextInt(60); i > 0; i--) {
          switch (rng.nextInt(3)) {
            case 0:
              _steps.add(Send(_randomBytes(rng.nextInt(24)), true));
            case 1:
              _send(
                ReleaseAll(_next()),
                tag: virtualTag ^ (1 + rng.nextInt(0xFFFF)),
              );
            default:
              _send(
                const Pong(id: 0, viewerMicros: 0),
                reliable: rng.nextBool(),
              );
          }
          if (rng.nextInt(8) == 0) {
            _steps.add(Elapse(rng.nextInt(400000)));
          }
        }
    }
  }

  T _pick<T>(List<T> v) => v[rng.nextInt(v.length)];

  void _key() {
    final heldList = _held.toList();
    final int usage;
    final KeyAction action;
    if (heldList.isNotEmpty && rng.nextInt(3) == 0) {
      usage = _pick(heldList);
      action = rng.nextInt(4) == 0 ? KeyAction.repeat : KeyAction.up;
    } else {
      usage = switch (rng.nextInt(10)) {
        0 => 0x00070000 + rng.nextInt(0x100),
        1 => rng.nextInt(1 << 32),
        _ => _pick(_usages),
      };
      action = rng.nextInt(8) == 0 ? KeyAction.repeat : KeyAction.down;
    }
    if (action == KeyAction.up) {
      _held.remove(usage);
    } else {
      _held.add(usage);
    }
    var modifiers = 0;
    for (final h in _held) {
      modifiers |= HidModifier.bitOf(h);
    }
    if (rng.nextInt(10) == 0) modifiers = rng.nextInt(0x10000);
    if (rng.nextInt(20) == 0) modifiers |= KeyModifiers.unmapped;
    _send(
      KeyMessage(_next(), usage: usage, action: action, modifiers: modifiers),
    );
  }

  int _coord() => switch (rng.nextInt(6)) {
    0 => 0,
    1 => 0xFFFF,
    _ => rng.nextInt(0x10000),
  };

  int _messageEpoch() =>
      rng.nextInt(10) == 0 ? (_epoch + 1 + rng.nextInt(3)) & 0xFFFF : _epoch;

  void _button() {
    final b = PointerButton.values[rng.nextInt(PointerButton.values.length)];
    final held = _buttons & b.mask != 0;
    final down = rng.nextInt(6) == 0 ? held : !held;
    _buttons = down ? _buttons | b.mask : _buttons & ~b.mask;
    _send(
      PointerButtonMessage(
        _next(),
        surfaceEpoch: _messageEpoch(),
        x: _coord(),
        y: _coord(),
        button: b,
        down: down,
        clickCount: _pick(const [1, 1, 1, 2, 3, 0, 255]),
      ),
    );
  }

  void _wheel() {
    int delta() => switch (rng.nextInt(4)) {
      0 => _pick(const [-0x8000, 0x7FFF, -1201, 1201, -11, 11]),
      _ => rng.nextInt(241) - 120,
    };
    _send(
      Wheel(
        _next(),
        surfaceEpoch: _messageEpoch(),
        x: _coord(),
        y: _coord(),
        dx: delta(),
        dy: delta(),
        unit: WheelUnit.values[rng.nextInt(2)],
      ),
    );
  }

  void _move() {
    final s = _next();
    _send(
      PointerMove(
        s,
        surfaceEpoch: _messageEpoch(),
        x: _coord(),
        y: _coord(),
        buttons: rng.nextInt(10) == 0 ? rng.nextInt(256) : _buttons,
        reliableSeq: switch (rng.nextInt(12)) {
          0 => (s + 1 + rng.nextInt(8)) & 0xFFFFFFFF, // not sent yet
          1 => rng.nextInt(1 << 32),
          _ => _lastReliable ?? s,
        },
      ),
      reliable: rng.nextInt(20) == 0,
    );
  }

  // dart format off
  static const List<String> _pieces = [
    'a', 'Z', '0', ' ', '\t', '\n', '\r', '\x1B', '\x08', '\x00', '\x7F',
    '\u0085', 'é', 'ß', '€', 'ж', '中', '\u{1F600}', '\uFEFF', '\u200B',
  ];
  // dart format on

  void _text() {
    if (rng.nextInt(10) == 0) return _overCapText();
    final target = switch (rng.nextInt(10)) {
      0 => maxTextBytes - rng.nextInt(8), // at the cap
      1 => rng.nextInt(maxTextBytes + 1),
      _ => rng.nextInt(40),
    };
    final sb = StringBuffer();
    var bytes = 0;
    while (true) {
      final p = _pick(_pieces);
      final n = utf8.encode(p).length;
      if (bytes + n > target) break;
      sb.write(p);
      bytes += n;
    }
    _send(TextMessage(_next(), sb.toString()));
  }

  /// A Text over the 1024-byte cap, multi-byte, built by hand since the
  /// encoder refuses it: malformed (or oversized) on the host.
  void _overCapText() {
    final text = <int>[];
    while (text.length < maxTextBytes + 1 + rng.nextInt(600)) {
      text.addAll(utf8.encode(_pick(_pieces)));
    }
    final b = Uint8List(9 + text.length);
    ByteData.sublistView(b)
      ..setUint8(0, MessageType.text)
      ..setUint16(1, virtualTag, Endian.little)
      ..setUint32(3, _next(), Endian.little)
      ..setUint16(7, text.length, Endian.little);
    b.setRange(9, b.length, text);
    _steps.add(Send(b, true));
  }

  void _anomaly() {
    switch (rng.nextInt(5)) {
      case 0: // a replay
        if (_sentReliable.isEmpty) return _key();
        final old = _pick(_sentReliable);
        _send(ReleaseAll(old));
      case 1: // half the sequence space ahead: neither before nor after
        _seq = (_seq + 0x80000000) & 0xFFFFFFFF;
        _key();
      case 2: // a little backwards
        _seq = (_seq - 1 - rng.nextInt(4)) & 0xFFFFFFFF;
        _button();
      case 3: // a jump to just before the wrap
        _seq = 0xFFFFFFFF - rng.nextInt(4);
        _key();
      default: // a move from the past
        final s = (_seq - 1 - rng.nextInt(16)) & 0xFFFFFFFF;
        _send(
          PointerMove(
            s,
            surfaceEpoch: _epoch,
            x: _coord(),
            y: _coord(),
            buttons: _buttons,
            reliableSeq: s,
          ),
          reliable: false,
        );
    }
  }

  void _host() {
    final r = rng.nextInt(100);
    final HostAction a;
    if (r < 25) {
      a = HostAction.localInput;
    } else if (r < 37) {
      a = HostAction.pause;
    } else if (r < 65) {
      a = HostAction.resume;
    } else if (r < 93) {
      a = _pick(const [
        HostAction.toDisplay,
        HostAction.toWindow,
        HostAction.toRect,
      ]);
    } else if (r < 97) {
      a = HostAction.stop;
    } else if (r < 99) {
      a = HostAction.stopAll;
    } else {
      a = HostAction.closeLink;
    }
    if (!_stopped &&
        (a == HostAction.toDisplay ||
            a == HostAction.toWindow ||
            a == HostAction.toRect)) {
      _epoch = (_epoch + 1) & 0xFFFF;
      _buttons = 0;
    }
    if (a == HostAction.stop ||
        a == HostAction.stopAll ||
        a == HostAction.closeLink) {
      _stopped = true;
    }
    if (a == HostAction.pause && rng.nextInt(4) != 0) {
      _resumeIn = 1 + rng.nextInt(30);
    }
    _steps.add(HostCall(a));
  }

  void _env() {
    final a = EnvAction.values[rng.nextInt(EnvAction.values.length)];
    final v = switch (a) {
      EnvAction.injector => rng.nextInt(3) == 0 ? rng.nextInt(6) : 0,
      EnvAction.securePointer || EnvAction.secureKeyboard =>
        rng.nextBool() ? 0 : 1 + rng.nextInt(BlockReason.values.length),
      EnvAction.windowGeometry => rng.nextInt(3) == 0 ? rng.nextInt(5) : 1,
      _ => rng.nextInt(2),
    };
    _steps.add(EnvChange(a, v));
  }

  Uint8List _randomBytes(int n) {
    final b = Uint8List(n);
    for (var i = 0; i < n; i++) {
      b[i] = rng.nextInt(256);
    }
    return b;
  }

  Uint8List _mutated() {
    final m = _pick<WireMessage>([
      KeyMessage(_seq, usage: _a, action: KeyAction.down, modifiers: 0),
      PointerButtonMessage(
        _seq,
        surfaceEpoch: _epoch,
        x: 100,
        y: 100,
        button: PointerButton.left,
        down: true,
        clickCount: 1,
      ),
      Wheel(
        _seq,
        surfaceEpoch: _epoch,
        x: 1,
        y: 1,
        dx: 1,
        dy: 1,
        unit: WheelUnit.line,
      ),
      TextMessage(_seq, 'abc'),
      PointerMove(
        _seq,
        surfaceEpoch: _epoch,
        x: 5,
        y: 5,
        buttons: 0,
        reliableSeq: _seq,
      ),
      ReleaseAll(_seq),
      const Ping(id: 1, viewerMicros: 2),
    ]);
    _next();
    final b = encodeMessage(m, sessionTag: virtualTag);
    var out = Uint8List.fromList(b);
    for (var k = 1 + rng.nextInt(3); k > 0; k--) {
      switch (rng.nextInt(5)) {
        case 0:
          if (out.isNotEmpty) {
            out[rng.nextInt(out.length)] ^= 1 << rng.nextInt(8);
          }
        case 1:
          out = Uint8List.sublistView(out, 0, rng.nextInt(out.length + 1));
        case 2:
          out = Uint8List(out.length + 1 + rng.nextInt(8))
            ..setRange(0, out.length, out);
        case 3:
          if (out.length > 3) {
            out[3 + rng.nextInt(out.length - 3)] = _pick(const [0, 0xFF, 6, 3]);
          }
        default:
          if (out.isNotEmpty) out[0] = rng.nextInt(256);
      }
    }
    return Uint8List.fromList(out);
  }
}

// --- Running and checking ----------------------------------------------------

/// The first invariant a sequence broke.
final class Failure {
  Failure(this.invariant, this.detail, this.step);

  /// A name, safe to print.
  final String invariant;

  /// What happened: event kinds and states only. Written to a file.
  final String detail;

  /// The index of the step it happened at, or -1 at the end.
  final int step;
}

/// Counts across many sequences, for the report.
final class FuzzTotals {
  int sequences = 0;
  int steps = 0;
  int messages = 0;
  int injectedPresses = 0;
  int injectedReleases = 0;
  int violations = 0;
  int dropped = 0;
  final Map<String, int> stops = SplayTreeMap();
  final Map<String, int> states = SplayTreeMap();

  void addStop(String s) => stops[s] = (stops[s] ?? 0) + 1;
  void addState(String s) => states[s] = (states[s] ?? 0) + 1;
}

/// Runs [steps] against a fresh session. Returns the first failure, or
/// null. Adds counts to [totals] when given.
Failure? runSequence(Setup setup, List<Step> steps, [FuzzTotals? totals]) {
  Failure? failure;
  void fail(String invariant, String detail, int step) {
    failure ??= Failure(invariant, detail, step);
  }

  var current = -1;
  runZonedGuarded(() {
    FakeAsync(
      initialTime: DateTime.utc(2026),
      includeTimerStackTrace: false,
    ).run(
      (async) => _Run(
        setup,
        steps,
        async,
        totals,
        (i, d) => fail(i, d, current),
        (i) => current = i,
      ).go(),
    );
  }, (e, st) => fail('threw', '${e.runtimeType} escaped the session', current));
  RemoteInputHost.stopAll();
  return failure;
}

final class _Run {
  _Run(this.setup, this.steps, this.async, this.totals, this.fail, this.at);

  final Setup setup;
  final List<Step> steps;
  final FakeAsync async;
  final FuzzTotals? totals;
  final void Function(String invariant, String detail) fail;
  final void Function(int step) at;

  late final InputLimits limits = setup.inputLimits;
  late final FakeHostPlatform platform;
  late final ({MemoryInputLink host, MemoryInputLink viewer}) pair;
  late final ControlSession session;
  late final DateTime? expiresAt;
  RectSurface? rect;

  /// The surface the session shares now, and where the injector last put
  /// the pointer.
  late SharedSurface current;
  Offset? lastPoint;
  Uint8List? realNonce;

  // The OS's view: what was pressed and not released, from the injector.
  final Set<int> osKeys = {};
  final Set<PointerButton> osButtons = {};
  bool releaseRefused = false;
  int injectorMode = 0;
  bool windowGone = false;

  final ListQueue<int> violationTimes = ListQueue();
  int violationsSeen = 0;
  int lastTouch = 0;
  bool stopSeen = false;
  bool sessionMade = false;
  int stepsRun = 0;

  int now() => clock.now().microsecondsSinceEpoch;

  void go() {
    final surfaces = FakeSurfaceResolver();
    surfaces.windows[_window] = _geometry(1);
    platform = FakeHostPlatform(
      platform: setup.hostIsMac ? PeerPlatform.macos : PeerPlatform.windows,
      surfaces: surfaces,
    );
    platform.injector.onInject = _onInject;
    pair = MemoryInputLink.pair();
    pair.viewer.reliable.messages.listen((bytes) {
      final r = decodeMessage(bytes);
      if (r is Decoded && r.message is HostHello) {
        realNonce ??= (r.message as HostHello).nonce;
      }
    });
    final expires = setup.expiresInMs;
    expiresAt = expires == null
        ? null
        : clock.now().add(Duration(milliseconds: expires));
    session = RemoteInputHost(platform: platform).enable(
      link: pair.host,
      surface: current = _surface(setup.surface),
      options: HostOptions(
        expiresAt: expiresAt,
        allowKeyboard: setup.allowKeyboard,
        resumePolicy: setup.manualResume
            ? ResumePolicy.manual
            : ResumePolicy.automatic,
        localIdle: Duration(milliseconds: setup.localIdleMs),
        heartbeatTimeout: Duration(milliseconds: setup.heartbeatMs),
        modifierMapping: setup.noModifierMapping
            ? ModifierMapping.none
            : ModifierMapping.auto,
        keyFilter: setup.filter ? _filter : null,
        limits: setup.limits == null ? null : limits,
        protectHostWindows: setup.protectHostWindows,
      ),
    );
    sessionMade = true;
    async.flushMicrotasks();
    if (realNonce == null) {
      fail('noHostHello', 'the host never said hello');
      return;
    }
    lastTouch = now();
    // A stopped session gets a few more steps, to show nothing is injected
    // after stop(); the rest would add nothing.
    var afterStop = 0;
    for (var i = 0; i < steps.length && afterStop < 25; i++) {
      at(i);
      _step(steps[i]);
      if (session.state.isStopped) afterStop++;
      stepsRun++;
    }
    at(-1);
    // The end: stop, and nothing may stay held or keep running.
    if (!session.state.isStopped) {
      session.stop();
      _afterStep(const HostCall(HostAction.stop));
    }
    async.elapse(const Duration(seconds: 30));
    _checkHeld();
    if (async.periodicTimerCount != 0 || async.pendingTimers.isNotEmpty) {
      fail('timersAfterStop', '${async.pendingTimers.length} timers left');
    }
    final t = totals;
    if (t != null) {
      t.sequences++;
      t.steps += stepsRun;
      final stats = session.stats;
      t.violations += stats.totalViolations;
      t.dropped += stats.totalDropped;
      final s = session.state;
      if (s is SessionStopped) t.addStop(s.reason.name);
    }
  }

  static bool _filter(KeyPress p) =>
      !(p.usage == _r &&
          (p.heldModifiers.contains(HidModifier.metaLeft) ||
              p.heldModifiers.contains(HidModifier.metaRight)));

  SharedSurface _surface(int kind) => switch (kind) {
    0 => SharedSurface.display(1, contentInsets: _insets),
    1 => SharedSurface.window(_window, contentInsets: _insets),
    _ => rect = RectSurface(
      const Rect.fromLTWH(-640, 200, 640, 480),
      pixelSize: const Size(1280, 960),
      contentInsets: _insets,
    ),
  };

  /// Where [surface] is now, in desktop coordinates, or null if it's gone.
  Rect? _bounds(SharedSurface surface) => switch (surface) {
    DisplaySurface() => _display,
    WindowSurface() => platform.surfaces.windows[_window]?.bounds,
    RectSurface s => s.isClosed ? null : s.bounds,
  };

  EdgeInsets get _insets => switch (setup.insets) {
    0 => EdgeInsets.zero,
    1 => const EdgeInsets.fromLTRB(4, 30, 4, 4),
    _ => const EdgeInsets.all(5000),
  };

  static SurfaceGeometry? _geometry(int v) => switch (v) {
    0 => null,
    2 => const SurfaceGeometry(
      bounds: Rect.fromLTWH(100, 50, 800, 600),
      pixelSize: Size(1600, 1200),
      isHidden: true,
    ),
    3 => const SurfaceGeometry(
      bounds: Rect.fromLTWH(100, 50, 0, 600),
      pixelSize: Size.zero,
    ),
    4 => const SurfaceGeometry(
      bounds: Rect.fromLTWH(-1200, -300, 1024, 768),
      pixelSize: Size(1024, 768),
    ),
    _ => const SurfaceGeometry(
      bounds: Rect.fromLTWH(100, 50, 800, 600),
      pixelSize: Size(1600, 1200),
    ),
  };

  // --- Steps -----------------------------------------------------------------

  void _step(Step step) {
    final before = debugSessionHeld(session);
    final wasStopped = session.state.isStopped;
    switch (step) {
      case Send(:final bytes, :final reliable):
        totals?.messages++;
        final real = _toReal(bytes);
        if (!wasStopped && real.length <= limits.maxMessageBytes) {
          final r = decodeMessage(real);
          if (r is Decoded && r.sessionTag == sessionTagOf(realNonce!)) {
            lastTouch = now();
          }
        }
        (reliable ? pair.viewer.reliable : pair.viewer.unreliable).send(real);
        async.flushMicrotasks();
      case Elapse(:final micros):
        async.elapse(Duration(microseconds: micros));
      case HostCall(:final action):
        _host(action);
        async.flushMicrotasks();
      case EnvChange(:final action, :final value):
        _env(action, value);
    }
    _afterStep(step, queuedBefore: before.queued, wasStopped: wasStopped);
  }

  void _host(HostAction action) {
    switch (action) {
      case HostAction.pause:
        session.pause();
      case HostAction.resume:
        session.resume();
      case HostAction.stop:
        session.stop();
      case HostAction.stopAll:
        RemoteInputHost.stopAll();
      case HostAction.localInput:
        platform.localActivity.simulateInput();
      case HostAction.closeLink:
        pair.host.close();
      case HostAction.toDisplay || HostAction.toWindow || HostAction.toRect:
        final surface = _surface(action.index - HostAction.toDisplay.index);
        if (surface is WindowSurface && windowGone) {
          platform.surfaces.windows[_window] = _geometry(1);
          windowGone = false;
        }
        try {
          session.changeSurface(surface);
          current = surface;
          if (session.state.isStopped) {
            fail('changedAfterStop', 'changeSurface worked after stop');
          }
        } on StateError {
          if (!session.state.isStopped) {
            fail('stateError', 'changeSurface threw while running');
          }
        }
    }
  }

  void _env(EnvAction action, int v) {
    final s = platform.surfaces;
    switch (action) {
      case EnvAction.injector:
        injectorMode = v;
      case EnvAction.securePointer:
        platform.secureContext.pointer = v == 0
            ? null
            : BlockReason.values[v - 1];
      case EnvAction.secureKeyboard:
        platform.secureContext.keyboard = v == 0
            ? null
            : BlockReason.values[v - 1];
      case EnvAction.monitorHealthy:
        platform.localActivity.healthy = v == 1;
      case EnvAction.keyboardFocus:
        s.keyboardFocus = v == 1;
      case EnvAction.occluded:
        s.occluded = v == 1 ? (p) => p.dx < 300 : null;
      case EnvAction.ownWindow:
        s.ownWindowAt = v == 1 ? (p) => p.dy < 200 : null;
      case EnvAction.ownAppInFront:
        s.ownAppInFront = v == 1;
      case EnvAction.windowGeometry:
        s.windows[_window] = _geometry(v);
        windowGone = v == 0;
      case EnvAction.closeRect:
        if (v == 1) rect?.close();
    }
  }

  /// Maps the virtual nonce and tag in [bytes] onto the session's.
  Uint8List _toReal(Uint8List bytes) {
    final out = Uint8List.fromList(bytes);
    final real = realNonce!;
    final realTag = sessionTagOf(real);
    if (out.length >= 3) {
      out[1] ^= (virtualTag ^ realTag) & 0xFF;
      out[2] ^= (virtualTag ^ realTag) >> 8;
    }
    final at = switch (out.isEmpty ? -1 : out[0]) {
      MessageType.hostHello => 5,
      MessageType.hello => 4,
      _ => -1,
    };
    if (at > 0) {
      for (var i = 0; i < nonceBytes && at + i < out.length; i++) {
        out[at + i] ^= virtualNonce[i] ^ real[i];
      }
    }
    return out;
  }

  // --- Invariants ------------------------------------------------------------

  InjectResult _onInject(InjectedEvent e) {
    final release =
        (e is InjectedKey && !e.down) || (e is InjectedButton && !e.down);
    final pointer =
        e is InjectedMove || e is InjectedButton || e is InjectedWheel;
    if (!sessionMade) {
      fail('injectedDuringEnable', '${e.runtimeType} injected during enable');
      return InjectResult.injected;
    }
    final state = session.state;
    if (!release) {
      final allowed =
          state is SessionActive ||
          (state is SessionBlocked && pointer && !state.reason.blocksPointer);
      if (!allowed) {
        fail('injectedWhileInactive', '${e.runtimeType} injected in $state');
      }
      final expires = expiresAt;
      if (expires != null && !clock.now().isBefore(expires)) {
        fail('injectedAfterExpiry', '${e.runtimeType} injected after expiry');
      }
      totals?.injectedPresses++;
    } else {
      totals?.injectedReleases++;
    }
    final InjectResult result = switch (injectorMode) {
      1 when !release => InjectResult.failed,
      2 when !release => InjectResult.elevatedTarget,
      3 => InjectResult.failed,
      4 when !release => InjectResult.permissionDenied,
      5 when e is InjectedKey => InjectResult.unmappedKey,
      _ => InjectResult.injected,
    };
    final ok = result == InjectResult.injected;
    final point = switch (e) {
      InjectedMove(:final point) ||
      InjectedButton(:final point) ||
      InjectedWheel(:final point) => point,
      _ => null,
    };
    if (point != null) {
      // Every pointer event lands on the shared surface (RIN-50), whose
      // right and bottom edges are outside it (RIN-51): a point on them
      // would be a pixel past the surface once floored. A release may
      // instead go where the pointer already is (docs/design.md §6.2).
      final bounds = _bounds(current);
      final inside =
          bounds != null &&
          point.dx.isFinite &&
          point.dy.isFinite &&
          point.dx >= bounds.left &&
          point.dx < bounds.right &&
          point.dy >= bounds.top &&
          point.dy < bounds.bottom;
      if (!inside && !(release && point == lastPoint)) {
        fail('pointOffSurface', '${e.runtimeType} outside the surface');
      }
      // The session remembers moves and buttons, not wheel events.
      if (ok && e is! InjectedWheel) lastPoint = point;
    }
    switch (e) {
      case InjectedKey(:final usage, :final down):
        if (down) {
          lastTouch = now();
          if (ok) osKeys.add(usage);
        } else if (ok) {
          osKeys.remove(usage);
        } else {
          releaseRefused = true;
        }
      case InjectedButton(:final button, :final down):
        lastTouch = now();
        if (down) {
          if (ok) osButtons.add(button);
        } else if (ok) {
          osButtons.remove(button);
        } else {
          releaseRefused = true;
        }
      case InjectedMove() || InjectedWheel() || InjectedText():
        break;
    }
    if (osKeys.length > limits.maxHeldKeys && !releaseRefused) {
      fail('tooManyKeys', '${osKeys.length} keys held');
    }
    return result;
  }

  void _afterStep(Step step, {int queuedBefore = 0, bool wasStopped = false}) {
    final state = session.state;
    final held = debugSessionHeld(session);
    totals?.addState(switch (state) {
      SessionBlocked(:final reason) => 'blocked.${reason.name}',
      SessionPaused(:final reason) => 'paused.${reason.name}',
      SessionStopped() => 'stopped',
      SessionActive() => 'active',
      SessionWaiting() => 'waiting',
    });

    if (held.queued > limits.maxQueuedEvents) {
      fail('queueOverCap', '${held.queued} queued');
    }
    if (held.heldKeys > limits.maxHeldKeys) {
      fail('heldOverCap', '${held.heldKeys} keys held');
    }

    // Violations: more than 50 in 10 s stop the session, and nothing else
    // does.
    final stats = session.stats;
    final t = now();
    for (var i = violationsSeen; i < stats.totalViolations; i++) {
      violationTimes.add(t);
    }
    violationsSeen = stats.totalViolations;
    while (violationTimes.isNotEmpty && violationTimes.first <= t - 10000000) {
      violationTimes.removeFirst();
    }

    if (wasStopped && !state.isStopped) {
      fail('restarted', 'a stopped session left the stopped state');
    }
    final newlyStopped = !wasStopped && state is SessionStopped;
    if (newlyStopped) {
      _checkStop(step, state.reason, queuedBefore);
      stopSeen = true;
      if (RemoteInputHost.activeSession != null) {
        fail('stillActive', 'activeSession set after stop');
      }
    } else if (!state.isStopped && violationTimes.length > 50) {
      fail('violationsIgnored', '${violationTimes.length} violations in 10 s');
    }

    // What each state allows to stay held.
    if (!releaseRefused) {
      final noKeys = switch (state) {
        SessionActive() => false,
        SessionBlocked() => true,
        _ => true,
      };
      final noButtons = switch (state) {
        SessionActive() => false,
        SessionBlocked(:final reason) => reason.blocksPointer,
        _ => true,
      };
      if (noKeys && osKeys.isNotEmpty) {
        fail('keysHeld', '${osKeys.length} keys held in $state');
      }
      if (noButtons && osButtons.isNotEmpty) {
        fail('buttonsHeld', '${osButtons.length} buttons held in $state');
      }
      if ((osKeys.isNotEmpty || osButtons.isNotEmpty) &&
          t - lastTouch >= setup.heartbeatMs * 1000) {
        fail('heldPastHeartbeat', 'held past the heartbeat timeout');
      }
    }
    if (step case HostCall(action: HostAction.localInput)) {
      if (state is! SessionWaiting &&
          state is! SessionStopped &&
          state is! SessionPaused) {
        fail('localInputIgnored', 'local input left the session $state');
      }
    }
    if (step case HostCall(action: HostAction.pause)) {
      if (!state.isStopped &&
          state != const SessionPaused(PauseReason.byHost)) {
        if (state is! SessionWaiting) {
          fail('pauseIgnored', 'pause() left the session $state');
        }
      }
    }
  }

  void _checkStop(Step step, StopReason reason, int queuedBefore) {
    bool expiredNow() {
      final e = expiresAt;
      return e != null && !clock.now().isBefore(e);
    }

    final surfaceGone = windowGone || (rect?.isClosed ?? false);
    final ok = switch (reason) {
      StopReason.byHost => _isHost(step, HostAction.stop),
      StopReason.stopAll => _isHost(step, HostAction.stopAll),
      StopReason.linkClosed => _isHost(step, HostAction.closeLink),
      StopReason.expired => expiredNow(),
      StopReason.surfaceGone => surfaceGone,
      StopReason.permissionDenied => injectorMode == 4,
      StopReason.flooding =>
        step is Send && queuedBefore >= limits.maxQueuedEvents,
      StopReason.protocolViolation =>
        step is Send && violationTimes.length > 50,
      StopReason.viewerLeft => step is Send && step.reliable && _isBye(step),
      _ => false,
    };
    if (!ok) {
      fail('unexpectedStop', 'stopped (${reason.name}) at ${step.runtimeType}');
    }
  }

  static bool _isHost(Step step, HostAction action) =>
      step is HostCall && step.action == action;

  bool _isBye(Send s) {
    final real = _toReal(s.bytes);
    if (real.length > limits.maxMessageBytes) return false;
    final r = decodeMessage(real);
    return r is Decoded &&
        r.message is Bye &&
        r.sessionTag == sessionTagOf(realNonce!);
  }

  void _checkHeld() {
    if (!session.state.isStopped) {
      fail('notStopped', 'the session is still running after stop()');
    }
    if (releaseRefused) return;
    if (osKeys.isNotEmpty || osButtons.isNotEmpty) {
      fail(
        'heldAfterStop',
        '${osKeys.length} keys, ${osButtons.length} buttons',
      );
    }
  }
}

// --- Shrinking ---------------------------------------------------------------

/// Removes steps from [steps] while the sequence still breaks [invariant].
List<Step> shrink(Setup setup, List<Step> steps, String invariant) {
  var best = steps;
  var budget = 3000;
  bool fails(List<Step> c) =>
      budget-- > 0 && runSequence(setup, c)?.invariant == invariant;
  for (var chunk = best.length ~/ 2; chunk >= 1; chunk ~/= 2) {
    var i = 0;
    while (i < best.length && budget > 0) {
      final c = [
        ...best.sublist(0, i),
        ...best.sublist(min(best.length, i + chunk)),
      ];
      if (fails(c)) {
        best = c;
      } else {
        i += chunk;
      }
    }
  }
  return best;
}

/// Mixes a seed and a sequence index into one Random seed.
int sequenceSeed(int seed, int index) {
  var z = (seed * 0x9E3779B1 + index * 0x85EBCA77 + 0x27D4EB2F) & 0xFFFFFFFF;
  z = ((z ^ (z >> 16)) * 0x7FEB352D) & 0xFFFFFFFF;
  z = ((z ^ (z >> 15)) * 0x846CA68B) & 0xFFFFFFFF;
  return z ^ (z >> 16);
}

/// The sequence for [seed] and [index].
(Setup, List<Step>) sequenceFor(int seed, int index) =>
    SequenceGenerator(Random(sequenceSeed(seed, index))).generate();

/// A failing sequence as JSON, for the file under `--out`.
String reproduction({
  required int seed,
  required int index,
  required Failure failure,
  required Setup setup,
  required List<Step> steps,
  required int originalSteps,
}) => const JsonEncoder.withIndent(' ').convert({
  'seed': seed,
  'index': index,
  'invariant': failure.invariant,
  'detail': failure.detail,
  'failingStep': failure.step,
  'originalSteps': originalSteps,
  'setup': setup.toJson(),
  'steps': [for (final s in steps) s.toJson()],
});
