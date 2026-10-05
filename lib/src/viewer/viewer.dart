import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Offset, Size;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, listEquals;

import '../keys.dart';
import '../link.dart';
import '../protocol/codec.dart';
import '../protocol/messages.dart';
import '../protocol/serial.dart';
import '../protocol/wire_types.dart';
import '../session_state.dart';
import '../util/state_value.dart';

/// Options for a [RemoteInputViewer].
final class ViewerOptions {
  /// Creates options.
  const ViewerOptions({
    this.platform,
    this.moveInterval = const Duration(milliseconds: 8),
    this.maxBufferedMoveBytes = 16 * 1024,
    this.pingInterval = const Duration(seconds: 1),
    this.hostTimeout = const Duration(seconds: 10),
    this.maxTextBytes = 16 * 1024,
  });

  /// The OS to report in the handshake, which decides the host's shortcut
  /// mapping (Command or Control). Defaults to the OS this runs on (the
  /// browser's OS on the web).
  final PeerPlatform? platform;

  /// The shortest time between two pointer moves sent; moves in between
  /// are coalesced into the newest. The capture widget sends at most one per
  /// frame anyway.
  final Duration moveInterval;

  /// Moves are skipped while the unreliable channel has more than this
  /// queued, so they never back up behind each other
  /// (`docs/design.md` §4).
  final int maxBufferedMoveBytes;

  /// How often to ping the host while a session is up: round-trip times,
  /// and a heartbeat so the host knows held keys aren't stuck.
  final Duration pingInterval;

  /// How long without any message from the host (pings are answered, so a
  /// live host is never quiet this long) before the viewer gives up on the
  /// session with [StopReason.timedOut]. It keeps listening, so a host that
  /// comes back with a new session is picked up.
  final Duration hostTimeout;

  /// The most UTF-8 bytes one [RemoteInputViewer.text] call sends; the rest
  /// is dropped, and the call returns false. The host types about 200
  /// characters a second and stops a session whose queue overflows, so a
  /// long paste must be cut (`docs/design.md` §13, question 15).
  final int maxTextBytes;
}

/// The surface the host shares, as it announced it.
final class RemoteSurface {
  /// Creates a [RemoteSurface].
  const RemoteSurface({required this.epoch, required this.pixelSize});

  /// The surface epoch: pointer input is stamped with it.
  final int epoch;

  /// The surface's size in pixels. Once video frames arrive, their size is
  /// what the viewer should lay out by.
  final Size pixelSize;
}

/// Counters for a viewer. Counts and timings only.
final class ViewerStats {
  /// Creates a [ViewerStats].
  const ViewerStats({
    required this.sent,
    required this.movesCoalesced,
    required this.movesSkippedForBackpressure,
    required this.droppedWhileInactive,
    required this.roundTripTime,
    this.textTruncated = 0,
    this.roundTripP50,
    this.roundTripP95,
  });

  /// Messages sent to the host.
  final int sent;

  /// Pointer moves replaced by a newer one before they were sent.
  final int movesCoalesced;

  /// Pointer-move sends postponed because the unreliable channel was
  /// backed up.
  final int movesSkippedForBackpressure;

  /// Input dropped because the session wasn't active.
  final int droppedWhileInactive;

  /// The latest round-trip time to the host, if measured.
  final Duration? roundTripTime;

  /// [RemoteInputViewer.text] calls cut at [ViewerOptions.maxTextBytes].
  final int textTruncated;

  /// The median round-trip time over the last minute of pings.
  final Duration? roundTripP50;

  /// The 95th-percentile round-trip time over the last minute of pings.
  final Duration? roundTripP95;
}

/// The viewer's side: sends a person's pointer and keyboard input to the
/// host at the other end of [link] (`docs/design.md` §8).
///
/// It answers the host's handshake, keeps the sequence numbers, coalesces
/// moves, and mirrors the host's state for the app's UI. It sends no input
/// until the host says the session is active.
///
/// Points are **normalized**: `Offset(0, 0)` is the top-left corner of the
/// shared surface's picture and `Offset(1, 1)` its bottom-right, excluding
/// any letterbox. Points outside are clamped to the edge. The
/// `RemoteInputCapture` widget (roadmap M4) maps Flutter events to these;
/// apps can also call the methods directly, for example from their own
/// gesture handling or a "Send keys" menu.
final class RemoteInputViewer {
  /// Creates a viewer on [link] and starts listening for the host.
  RemoteInputViewer({required this.link, this.options = const ViewerOptions()})
    : _platform = options.platform ?? _currentPlatform() {
    final reliable = link.reliable;
    _subscriptions
      ..add(reliable.messages.listen(_onBytes, onDone: _onLinkDone))
      ..add(
        reliable.openChanges.listen((open) {
          // A link may start closed and replay that: only a close after it
          // was open ends the viewer.
          if (open) {
            _wasOpen = true;
          } else if (_wasOpen && !_closed) {
            _end(StopReason.linkClosed);
          }
        }),
      );
    if (!identical(link.unreliable, reliable)) {
      _subscriptions.add(link.unreliable.messages.listen(_onBytes));
    }
  }

  /// The link to the host.
  final InputLink link;

  /// The viewer's options.
  final ViewerOptions options;

  final PeerPlatform _platform;
  final StateValue<SessionState> _state = StateValue(const SessionWaiting());
  final StateValue<RemoteSurface?> _surface = StateValue(null);
  final List<StreamSubscription<Object?>> _subscriptions = [];

  bool _closed = false;
  bool _wasOpen = false;
  bool _quietOnce = false;
  int _textTruncated = 0;
  int? _tag;
  bool _helloSent = false;
  int _seq = 0;
  int? _lastReliableSeq;
  final Set<PointerButton> _heldButtons = {};

  PointerMove? _pendingMove;
  Timer? _moveTimer;
  int? _lastMoveMicros;

  Timer? _pingTimer;
  int _pingId = 0;
  Duration? _rtt;
  final ListQueue<int> _rttSamples = ListQueue();
  Uint8List? _lastNonce;
  PeerPlatform? _hostPlatform;
  int _lastHeardMicros = 0;

  int _sent = 0;
  int _coalesced = 0;
  int _backpressure = 0;
  int _droppedInactive = 0;

  /// The host's state as last reported: [SessionWaiting] until the
  /// handshake finishes. Informational; the host enforces it.
  SessionState get state => _state.value;

  /// [state], replaying the current value to each new listener, then each
  /// change. Completes after [close].
  ///
  /// A [SessionStopped] from the host isn't final for the viewer: if the
  /// host starts a new session on the same link, the state goes back to
  /// [SessionWaiting]. After [close], or when the link closes, it is.
  Stream<SessionState> get stateChanges => _state.stream;

  /// The shared surface, once the host has announced it.
  RemoteSurface? get surface => _surface.value;

  /// [surface], replaying the current value, then each change.
  Stream<RemoteSurface?> get surfaceChanges => _surface.stream;

  /// Counters for diagnostics.
  ViewerStats get stats => ViewerStats(
    sent: _sent,
    movesCoalesced: _coalesced,
    movesSkippedForBackpressure: _backpressure,
    droppedWhileInactive: _droppedInactive,
    roundTripTime: _rtt,
    textTruncated: _textTruncated,
    roundTripP50: _rttPercentile(0.50),
    roundTripP95: _rttPercentile(0.95),
  );

  /// The OS this viewer reports in the handshake: [ViewerOptions.platform],
  /// or the one it runs on.
  PeerPlatform get platform => _platform;

  /// The host's OS, from its latest handshake; `null` until the first one.
  /// For labels like "Cmd" or "Win", and "Controlling a Mac".
  PeerPlatform? get hostPlatform => _hostPlatform;

  Duration? _rttPercentile(double p) {
    if (_rttSamples.isEmpty) return null;
    final sorted = _rttSamples.toList()..sort();
    final i = ((sorted.length - 1) * p).round();
    return Duration(microseconds: sorted[i]);
  }

  /// The buttons this viewer holds down on the host.
  Set<PointerButton> get heldButtons => Set.unmodifiable(_heldButtons);

  // --- Input ----------------------------------------------------------------

  /// Moves the pointer to normalized [point]. Coalesced: only the newest
  /// move in each [ViewerOptions.moveInterval] is sent.
  void pointerMove(Offset point) {
    if (!_canSend()) return;
    final (x, y) = _normalize(point);
    if (_pendingMove != null) _coalesced++;
    _pendingMove = PointerMove(
      0, // Numbered when sent, so it orders after earlier input.
      surfaceEpoch: _epoch,
      x: x,
      y: y,
      buttons: PointerButton.maskOf(_heldButtons),
      reliableSeq: 0, // Set when sent.
    );
    _scheduleMove();
  }

  /// Presses or releases [button] at normalized [point]. [clickCount] is
  /// the viewer's own count: 2 for the second press of a double click.
  void pointerButton(
    Offset point,
    PointerButton button, {
    required bool down,
    int clickCount = 1,
  }) {
    if (!_canSend()) return;
    if (down == _heldButtons.contains(button)) return;
    _discardPendingMove();
    final (x, y) = _normalize(point);
    _sendInput(
      (seq) => PointerButtonMessage(
        seq,
        surfaceEpoch: _epoch,
        x: x,
        y: y,
        button: button,
        down: down,
        clickCount: clickCount.clamp(1, 255),
      ),
    );
    down ? _heldButtons.add(button) : _heldButtons.remove(button);
  }

  /// Presses and releases [button] at [point]: a click.
  void click(
    Offset point, {
    PointerButton button = PointerButton.left,
    int clickCount = 1,
  }) {
    pointerButton(point, button, down: true, clickCount: clickCount);
    pointerButton(point, button, down: false, clickCount: clickCount);
  }

  /// Scrolls at normalized [point]. Positive [dy] reveals what's below,
  /// positive [dx] what's to the right. Deltas past ±32767 are clamped, and
  /// the host clamps further (`docs/design.md` §6.4).
  void wheel(
    Offset point, {
    double dx = 0,
    double dy = 0,
    WheelUnit unit = WheelUnit.pixel,
  }) {
    if (!_canSend()) return;
    final ix = dx.round().clamp(-0x8000, 0x7FFF);
    final iy = dy.round().clamp(-0x8000, 0x7FFF);
    if (ix == 0 && iy == 0) return;
    _discardPendingMove();
    final (x, y) = _normalize(point);
    _sendInput(
      (seq) => Wheel(
        seq,
        surfaceEpoch: _epoch,
        x: x,
        y: y,
        dx: ix,
        dy: iy,
        unit: unit,
      ),
    );
  }

  /// Sends a physical key, by its USB HID [usage] (Flutter's
  /// `PhysicalKeyboardKey.usbHidUsage`). [modifiers] is the viewer's
  /// modifier state after the event ([KeyModifiers]).
  void key(int usage, KeyAction action, {int modifiers = KeyModifiers.none}) {
    if (!_canSend()) return;
    if (usage < 0 || usage > 0xFFFFFFFF) {
      throw RangeError('usage is out of range 0..0xFFFFFFFF');
    }
    _sendInput(
      (seq) => KeyMessage(
        seq,
        usage: usage,
        action: action,
        modifiers: modifiers & 0xFFFF,
      ),
    );
  }

  /// Types [text] on the host by Unicode, whatever the keyboard layouts.
  /// Long text is split into messages of at most 1024 UTF-8 bytes; the host
  /// types about 200 characters a second. Text past
  /// [ViewerOptions.maxTextBytes] is dropped: returns whether all of it was
  /// sent, so an app can say a paste was cut.
  bool text(String text) {
    if (text.isEmpty) return true;
    if (!_canSend()) return false;
    final chunks = splitUtf8(text, maxTextBytes);
    var sentBytes = 0;
    var all = true;
    for (final chunk in chunks) {
      final n = utf8.encode(chunk).length;
      if (sentBytes + n > options.maxTextBytes) {
        all = false;
        break;
      }
      sentBytes += n;
      _sendInput((seq) => TextMessage(seq, chunk));
    }
    if (!all) _textTruncated++;
    return all;
  }

  /// Presses [usages] in order, then releases them in reverse: a shortcut
  /// the viewer's own OS would take first (Alt+Tab, Command+Space), for a
  /// "Send keys" menu. Modifier state is derived from the modifier keys in
  /// [usages]. With [mapModifiers] false, the host applies no Command/Control
  /// mapping, so a Mac viewer can send the Windows key itself.
  /// [heldModifiers] are modifier bits already held on the host (a key
  /// bar's locked Ctrl), kept in every key's state so the host doesn't
  /// release them.
  void sendShortcut(
    List<int> usages, {
    bool mapModifiers = true,
    int heldModifiers = KeyModifiers.none,
  }) {
    var modifiers =
        (mapModifiers ? KeyModifiers.none : KeyModifiers.unmapped) |
        heldModifiers;
    for (final u in usages) {
      modifiers |= HidModifier.bitOf(u);
      key(u, KeyAction.down, modifiers: modifiers);
    }
    for (final u in usages.reversed) {
      modifiers &= ~(HidModifier.bitOf(u) & ~heldModifiers);
      key(u, KeyAction.up, modifiers: modifiers);
    }
  }

  /// Releases every key and button held on the host. The capture widget
  /// calls this when it loses focus.
  void releaseAll() {
    _heldButtons.clear();
    if (!_canSend()) return;
    _discardPendingMove();
    _sendInput(ReleaseAll.new);
  }

  /// Leaves: says goodbye to the host and stops listening. The state ends
  /// as [SessionStopped] with [StopReason.viewerClosed].
  Future<void> close() async {
    if (_closed) return;
    if (_tag != null) _sendControl(const Bye(ByeReason.closed));
    _end(StopReason.viewerClosed);
  }

  // --- Sending --------------------------------------------------------------

  bool _canSend() {
    if (_state.value.isActive && _tag != null) return true;
    _droppedInactive++;
    return false;
  }

  int get _epoch => _surface.value?.epoch ?? 0;

  void _sendInput(InputMessage Function(int seq) build) {
    final tag = _tag;
    if (tag == null) return;
    final message = build(_seq);
    if (message is! PointerMove) _lastReliableSeq = message.seq;
    _seq = seqNext(_seq);
    _sent++;
    final channel = message is PointerMove ? link.unreliable : link.reliable;
    if (channel.isOpen) {
      channel.send(encodeMessage(message, sessionTag: tag));
    }
  }

  void _sendControl(WireMessage message) {
    final tag = _tag;
    if (tag == null || !link.reliable.isOpen) return;
    _sent++;
    link.reliable.send(encodeMessage(message, sessionTag: tag));
  }

  void _scheduleMove() {
    if (_moveTimer != null) return;
    final now = clock.now().microsecondsSinceEpoch;
    final last = _lastMoveMicros;
    final wait = last == null
        ? 0
        : last + options.moveInterval.inMicroseconds - now;
    if (wait <= 0) {
      _flushMove();
    } else {
      _moveTimer = Timer(Duration(microseconds: wait), () {
        _moveTimer = null;
        _flushMove();
      });
    }
  }

  void _flushMove() {
    final m = _pendingMove;
    if (m == null) return;
    if (!_state.value.isActive) {
      _pendingMove = null;
      return;
    }
    final buffered = link.unreliable.bufferedAmount;
    if (buffered != null && buffered > options.maxBufferedMoveBytes) {
      _backpressure++;
      _moveTimer = Timer(options.moveInterval, () {
        _moveTimer = null;
        _flushMove();
      });
      return;
    }
    _pendingMove = null;
    _lastMoveMicros = clock.now().microsecondsSinceEpoch;
    _sendInput(
      (seq) => PointerMove(
        seq,
        surfaceEpoch: m.surfaceEpoch,
        x: m.x,
        y: m.y,
        buttons: m.buttons,
        reliableSeq: _lastReliableSeq ?? seq,
      ),
    );
  }

  /// Drops a move not yet sent: a button or wheel event carries its own
  /// point, and a move sent after it would pull the pointer back.
  void _discardPendingMove() {
    if (_pendingMove == null) return;
    _pendingMove = null;
    _coalesced++;
    _moveTimer?.cancel();
    _moveTimer = null;
  }

  // --- Receiving ------------------------------------------------------------

  void _onBytes(Uint8List bytes) {
    if (_closed) return;
    final result = decodeMessage(bytes);
    if (result is! Decoded) return;
    final message = result.message;
    if (message is HostHello) {
      _onHostHello(message);
      return;
    }
    if (result.sessionTag != _tag) return;
    _lastHeardMicros = clock.now().microsecondsSinceEpoch;
    switch (message) {
      case HostState m:
        _onHostState(m);
      case SurfaceMessage m:
        _surface.set(
          RemoteSurface(
            epoch: m.surfaceEpoch,
            pixelSize: Size(m.width.toDouble(), m.height.toDouble()),
          ),
        );
      case Pong m:
        final now = clock.now().microsecondsSinceEpoch;
        if (m.viewerMicros <= now) {
          final micros = now - m.viewerMicros;
          _rtt = Duration(microseconds: micros);
          _rttSamples.add(micros);
          final keep = max(
            1,
            60000000 ~/ max(1, options.pingInterval.inMicroseconds),
          );
          while (_rttSamples.length > keep) {
            _rttSamples.removeFirst();
          }
        }
      case Bye(:final reason):
        _resetSession();
        _state.set(
          SessionStopped(
            reason == ByeReason.unsupportedVersion
                ? StopReason.unsupportedVersion
                : StopReason.hostLeft,
          ),
        );
      case HostHello() || Hello() || Ping() || InputMessage():
        break; // Not for a viewer.
    }
  }

  void _onHostHello(HostHello m) {
    // The host re-sends HostHello until it hears Hello; one per session.
    final last = _lastNonce;
    if (last != null && listEquals(last, m.nonce)) return;
    _lastNonce = m.nonce;
    _resetSession();
    _hostPlatform = m.hostPlatform;
    _lastHeardMicros = clock.now().microsecondsSinceEpoch;
    _tag = sessionTagOf(m.nonce);
    _surface.set(
      RemoteSurface(
        epoch: m.surfaceEpoch,
        pixelSize: Size(m.surfaceWidth.toDouble(), m.surfaceHeight.toDouble()),
      ),
    );
    if (remoteInputProtocolVersion < m.minVersion ||
        remoteInputProtocolVersion > m.maxVersion) {
      _sendControl(const Bye(ByeReason.unsupportedVersion));
      _tag = null;
      _state.set(const SessionStopped(StopReason.unsupportedVersion));
      return;
    }
    _sendControl(
      Hello(
        version: remoteInputProtocolVersion,
        nonce: m.nonce,
        viewerPlatform: _platform,
        capabilities: kIsWeb ? ViewerCapabilities.web : 0,
      ),
    );
    _helloSent = true;
    if (_state.value is! SessionWaiting) _state.set(const SessionWaiting());
    _ping();
    _pingTimer = Timer.periodic(options.pingInterval, (_) => _ping());
  }

  void _onHostState(HostState m) {
    if (!_helloSent) return;
    final next = switch (m.state) {
      HostStateCode.active => const SessionActive(),
      HostStateCode.paused => SessionPaused(PauseReason.fromCode(m.reason)),
      HostStateCode.blocked => SessionBlocked(BlockReason.fromCode(m.reason)),
      HostStateCode.stopped => SessionStopped(StopReason.fromCode(m.reason)),
    };
    if (!next.isActive) {
      // The host released everything it held for us.
      _heldButtons.clear();
      _discardPendingMove();
    }
    if (next.isStopped) _resetSession();
    if (m.surfaceEpoch != _epoch && _surface.value != null) {
      _surface.set(
        RemoteSurface(
          epoch: m.surfaceEpoch,
          pixelSize: _surface.value!.pixelSize,
        ),
      );
    }
    if (next != _state.value) _state.set(next);
  }

  void _ping() {
    final quiet = clock.now().microsecondsSinceEpoch - _lastHeardMicros;
    if (quiet > options.hostTimeout.inMicroseconds) {
      // One ping's grace: after a suspend, this timer can fire before the
      // host's queued replies are read.
      if (!_quietOnce) {
        _quietOnce = true;
      } else {
        // Tell the host, so both ends agree control is over.
        _sendControl(const Bye(ByeReason.closed));
        _resetSession();
        _state.set(const SessionStopped(StopReason.timedOut));
        return;
      }
    } else {
      _quietOnce = false;
    }
    _sendControl(
      Ping(id: _pingId, viewerMicros: clock.now().microsecondsSinceEpoch),
    );
    _pingId = (_pingId + 1) & 0xFFFFFFFF;
  }

  void _resetSession() {
    _tag = null;
    _helloSent = false;
    _seq = 0;
    _quietOnce = false;
    _lastReliableSeq = null;
    _heldButtons.clear();
    _pendingMove = null;
    _moveTimer?.cancel();
    _moveTimer = null;
    _lastMoveMicros = null;
    _pingTimer?.cancel();
    _pingTimer = null;
  }

  void _onLinkDone() {
    if (!_closed) _end(StopReason.linkClosed);
  }

  void _end(StopReason reason) {
    if (_closed) return;
    _closed = true;
    _resetSession();
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
    _state
      ..set(SessionStopped(reason))
      ..close();
    _surface.close();
  }
}

/// Splits [text] into pieces of at most [maxBytes] UTF-8 bytes, without
/// splitting a code point.
List<String> splitUtf8(String text, int maxBytes) {
  final out = <String>[];
  final buffer = StringBuffer();
  var bytes = 0;
  for (final r in text.runes) {
    final n = r < 0x80
        ? 1
        : r < 0x800
        ? 2
        : r < 0x10000
        ? 3
        : 4;
    if (bytes + n > maxBytes) {
      out.add(buffer.toString());
      buffer.clear();
      bytes = 0;
    }
    buffer.writeCharCode(r);
    bytes += n;
  }
  if (buffer.isNotEmpty) out.add(buffer.toString());
  assert(out.every((s) => utf8.encode(s).length <= maxBytes));
  return out;
}

(int, int) _normalize(Offset p) => (_unit(p.dx), _unit(p.dy));

int _unit(double v) {
  if (v.isNaN) return 0;
  return (v * 65536).floor().clamp(0, 65535);
}

PeerPlatform _currentPlatform() => switch (defaultTargetPlatform) {
  TargetPlatform.windows => PeerPlatform.windows,
  TargetPlatform.macOS => PeerPlatform.macos,
  TargetPlatform.linux => PeerPlatform.linux,
  TargetPlatform.iOS => PeerPlatform.ios,
  TargetPlatform.android => PeerPlatform.android,
  TargetPlatform.fuchsia => PeerPlatform.fuchsia,
};
