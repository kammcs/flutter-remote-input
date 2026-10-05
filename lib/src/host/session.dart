import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show listEquals;

import '../keys.dart';
import '../link.dart';
import '../protocol/codec.dart';
import '../protocol/messages.dart';
import '../protocol/serial.dart';
import '../protocol/wire_types.dart';
import '../session_state.dart';
import '../surface.dart';
import '../util/state_value.dart';
import '../util/token_bucket.dart';
import 'host_types.dart';
import 'options.dart';
import 'platform.dart';

/// More violations than this within [_violationWindow] stop the session.
const int _maxViolations = 50;
const Duration _violationWindow = Duration(seconds: 10);

/// How often a blocked session checks whether the condition cleared.
const Duration _blockPollInterval = Duration(milliseconds: 250);

/// Creates a session. Internal: `RemoteInputHost.enable` is the public way.
ControlSession createControlSession({
  required HostPlatform platform,
  required InputLink link,
  required SharedSurface surface,
  required HostOptions options,
  required void Function(ControlSession) onStopped,
}) => ControlSession._(platform, link, surface, options, onStopped).._start();

/// Stops [session] for `RemoteInputHost.stopAll`. Internal.
void stopSessionForAll(ControlSession? session) =>
    session?._stop(StopReason.stopAll);

/// One viewer's control of this machine, from `RemoteInputHost.enable`
/// until it stops (`docs/design.md` §6).
///
/// The host app follows [stateChanges] for its banner ("Paused while you
/// use your mouse", "Can't control an app run as administrator") and calls
/// [stop] from its revoke hotkey or Stop button.
final class ControlSession {
  ControlSession._(
    this._platform,
    this._link,
    this._surface,
    this.options,
    this._onStopped,
  ) : limits = options.limits ?? InputLimits() {
    _eventBucket = TokenBucket(
      rate: limits.eventRate.toDouble(),
      burst: limits.eventBurst,
    );
    _textBucket = TokenBucket(
      rate: limits.textRate.toDouble(),
      burst: limits.textBurst,
    );
    _moveIntervalMicros = 1000000 ~/ limits.moveRate;
  }

  final HostPlatform _platform;
  final InputLink _link;
  final void Function(ControlSession) _onStopped;

  /// The options the session was enabled with.
  final HostOptions options;

  /// The limits in force: [HostOptions.limits], or the defaults.
  final InputLimits limits;

  final StateValue<SessionState> _state = StateValue(const SessionWaiting());
  final Uint8List _nonce = _randomNonce();
  late final int _tag = sessionTagOf(_nonce);

  SharedSurface _surface;
  int _epoch = 0;

  // The flags the state derives from (_deriveState).
  bool _stopped = false;
  StopReason? _stopReason;
  bool _handshakeDone = false;
  bool _hostPaused = false;
  bool _localPaused = false;
  BlockReason? _blocked;
  InputKind? _blockedKind;

  bool _helloSent = false;
  bool _wasOpen = false;
  PeerPlatform? _viewerPlatform;
  int _viewerCapabilities = 0;
  bool _swapModifiers = false;

  int? _lastReliableSeq;
  int? _lastPointerSeq;
  Offset? _lastPointerPoint;
  final Set<int> _heldKeys = <int>{};
  final Set<PointerButton> _heldButtons = <PointerButton>{};

  final ListQueue<InputMessage> _queue = ListQueue();
  late final TokenBucket _eventBucket;
  late final TokenBucket _textBucket;
  Timer? _drainTimer;

  PointerMove? _pendingMove;
  Timer? _moveTimer;
  late final int _moveIntervalMicros;
  int? _lastMoveMicros;

  final ListQueue<int> _violationTimes = ListQueue();
  final List<StreamSubscription<Object?>> _subscriptions = [];
  Timer? _expiryTimer;
  Timer? _heartbeatTimer;
  Timer? _resumeTimer;
  Timer? _blockPollTimer;

  int _received = 0;
  int _injected = 0;
  int _ignored = 0;
  final Map<DropReason, int> _dropped = {};
  final Map<ViolationKind, int> _violations = {};

  // --- Public API -----------------------------------------------------------

  /// The state now.
  SessionState get state => _state.value;

  /// [state], replaying the current value to each new listener, then each
  /// change. Completes after the session stops.
  Stream<SessionState> get stateChanges => _state.stream;

  /// The shared surface.
  SharedSurface get surface => _surface;

  /// The surface epoch: incremented by each [changeSurface]. Pointer input
  /// aimed at an earlier epoch is dropped.
  int get surfaceEpoch => _epoch;

  /// The viewer's OS, once the handshake has finished.
  PeerPlatform? get viewerPlatform => _viewerPlatform;

  /// Whether the viewer runs in a web browser, once the handshake has
  /// finished.
  bool get viewerIsWeb => _viewerCapabilities & ViewerCapabilities.web != 0;

  /// Counters for diagnostics: counts only, never content.
  SessionStats get stats => SessionStats(
    received: _received,
    injected: _injected,
    ignored: _ignored,
    dropped: Map.unmodifiable(_dropped),
    violations: Map.unmodifiable(_violations),
  );

  /// Stops the session, with [StopReason.byHost].
  ///
  /// Synchronous: the session's stopped flag is set before this returns,
  /// and the only input injected afterwards is the release of keys and
  /// buttons the session held, done before this returns. Calling it again
  /// does nothing.
  void stop() => _stop(StopReason.byHost);

  /// Pauses injection, with [PauseReason.byHost], until [resume]. Held keys
  /// and buttons are released.
  void pause() {
    if (_stopped || _hostPaused) return;
    _hostPaused = true;
    _update();
  }

  /// Resumes after [pause], or after local input with
  /// [ResumePolicy.manual] (or early with [ResumePolicy.automatic]).
  void resume() {
    if (_stopped) return;
    _hostPaused = false;
    _localPaused = false;
    _resumeTimer?.cancel();
    _update();
  }

  /// Replaces the shared surface. The epoch increments and the viewer is
  /// told, so a click aimed at the old surface never lands on the new one.
  /// Held buttons are released.
  ///
  /// Throws a [StateError] after the session stopped, and an [ArgumentError]
  /// if [surface] can't be found.
  void changeSurface(SharedSurface surface) {
    if (_stopped) throw StateError('The session has stopped');
    final geometry = _geometryOf(surface);
    if (geometry == null) {
      throw ArgumentError.value(surface, 'surface', 'is not available');
    }
    _releaseButtons();
    _surface = surface;
    _epoch = (_epoch + 1) & 0xFFFF;
    _dropPendingMove(DropReason.staleEpoch);
    if (_helloSent) {
      _send(
        SurfaceMessage(
          surfaceEpoch: _epoch,
          width: _pixels(geometry.pixelSize.width),
          height: _pixels(geometry.pixelSize.height),
        ),
      );
    }
  }

  // --- Lifecycle ------------------------------------------------------------

  void _start() {
    final geometry = _geometryOf(_surface);
    if (geometry == null) {
      throw ArgumentError.value(_surface, 'surface', 'is not available');
    }
    final expiresAt = options.expiresAt;
    if (expiresAt != null) {
      final remaining = expiresAt.difference(clock.now());
      if (remaining <= Duration.zero) {
        throw ArgumentError.value(expiresAt, 'expiresAt', 'has passed');
      }
      _expiryTimer = Timer(remaining, () => _stop(StopReason.expired));
    }

    final reliable = _link.reliable;
    final unreliable = _link.unreliable;
    _subscriptions.add(
      reliable.messages.listen(
        (m) => _onBytes(m, fromReliable: true),
        onDone: () => _stop(StopReason.linkClosed),
      ),
    );
    if (!identical(unreliable, reliable)) {
      _subscriptions.add(
        unreliable.messages.listen((m) => _onBytes(m, fromReliable: false)),
      );
    }
    _subscriptions.add(reliable.openChanges.listen(_onOpenChanged));
    final activity = _platform.localActivity?.activity;
    if (activity != null) {
      _subscriptions.add(activity.listen((_) => _onLocalActivity()));
    }
    if (reliable.isOpen) _onOpenChanged(true);
  }

  void _onOpenChanged(bool open) {
    if (_stopped) return;
    if (open) {
      _wasOpen = true;
      if (!_helloSent) _sendHostHello();
    } else if (_wasOpen) {
      _stop(StopReason.linkClosed);
    }
  }

  void _sendHostHello() {
    final geometry = _geometryOf(_surface);
    if (geometry == null) {
      _stop(StopReason.surfaceGone);
      return;
    }
    _helloSent = true;
    _send(
      HostHello(
        minVersion: remoteInputProtocolVersion,
        maxVersion: remoteInputProtocolVersion,
        nonce: _nonce,
        hostPlatform: _platform.platform,
        capabilities: 0,
        surfaceEpoch: _epoch,
        surfaceWidth: _pixels(geometry.pixelSize.width),
        surfaceHeight: _pixels(geometry.pixelSize.height),
      ),
    );
  }

  void _stop(StopReason reason) {
    if (_stopped) return;
    _stopped = true;
    _stopReason = reason;
    for (final t in [
      _expiryTimer,
      _heartbeatTimer,
      _resumeTimer,
      _blockPollTimer,
      _drainTimer,
      _moveTimer,
    ]) {
      t?.cancel();
    }
    _queue.clear();
    _pendingMove = null;
    _releaseHeld();
    if (_helloSent) _sendState(SessionStopped(reason));
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
    _state.set(SessionStopped(reason));
    _state.close();
    _onStopped(this);
  }

  // --- State ----------------------------------------------------------------

  SessionState _deriveState() {
    if (_stopped) return SessionStopped(_stopReason!);
    if (!_handshakeDone) return const SessionWaiting();
    if (_hostPaused) return const SessionPaused(PauseReason.byHost);
    if (_localPaused) return const SessionPaused(PauseReason.localInput);
    final blocked = _blocked;
    if (blocked != null) return SessionBlocked(blocked);
    return const SessionActive();
  }

  void _update() {
    final next = _deriveState();
    if (next == _state.value) return;
    if (next is SessionPaused || next is SessionBlocked) {
      _releaseHeld();
      _queue.clear();
      _dropPendingMove(DropReason.inactive);
    }
    if (next is SessionBlocked) {
      _blockPollTimer ??= Timer.periodic(
        _blockPollInterval,
        (_) => _pollBlock(),
      );
    } else {
      _blockPollTimer?.cancel();
      _blockPollTimer = null;
    }
    _state.set(next);
    if (_helloSent) _sendState(next);
  }

  void _sendState(SessionState s) {
    final (code, reason) = switch (s) {
      SessionActive() => (HostStateCode.active, 0),
      SessionPaused(:final reason) => (HostStateCode.paused, reason.code),
      SessionBlocked(:final reason) => (HostStateCode.blocked, reason.code),
      SessionStopped(:final reason) => (HostStateCode.stopped, reason.code),
      SessionWaiting() => (null, 0),
    };
    if (code == null) return;
    _send(HostState(state: code, reason: reason, surfaceEpoch: _epoch));
  }

  void _onLocalActivity() {
    if (_stopped) return;
    _localPaused = true;
    _update();
    _resumeTimer?.cancel();
    if (options.resumePolicy == ResumePolicy.automatic) {
      _resumeTimer = Timer(options.localIdle, () {
        _localPaused = false;
        _update();
      });
    }
  }

  void _setBlocked(BlockReason reason, InputKind kind) {
    if (_blocked == reason && _blockedKind == kind) return;
    _blocked = reason;
    _blockedKind = kind;
    _update();
  }

  void _clearBlocked() {
    if (_blocked == null) return;
    _blocked = null;
    _blockedKind = null;
    _update();
  }

  void _pollBlock() {
    final blocked = _blocked;
    if (_stopped || blocked == null) return;
    if (blocked == BlockReason.surfaceHidden) {
      final g = _geometryOf(_surface);
      if (g == null) {
        _stop(StopReason.surfaceGone);
      } else if (!g.isHidden) {
        _clearBlocked();
      }
      return;
    }
    final probe = _platform.secureContext;
    final reason = probe?.check(
      _blockedKind ?? InputKind.keyboard,
      point: _lastPointerPoint,
    );
    if (reason == null) {
      _clearBlocked();
    } else if (reason != blocked) {
      _setBlocked(reason, _blockedKind ?? InputKind.keyboard);
    }
  }

  /// Whether input of [kind] may be injected, as far as the state goes
  /// (blocks are checked per event, in [_secureAllows]).
  bool _notPaused() =>
      !_stopped && _handshakeDone && !_hostPaused && !_localPaused;

  // --- Receiving ------------------------------------------------------------

  void _onBytes(Uint8List bytes, {required bool fromReliable}) {
    if (_stopped) return;
    _received++;
    _touchHeartbeat();
    if (bytes.length > limits.maxMessageBytes) {
      _violation(ViolationKind.oversized);
      return;
    }
    switch (decodeMessage(bytes)) {
      case DecodeIgnored():
        _ignored++;
      case DecodeFailed():
        _violation(ViolationKind.malformed);
      case Decoded(:final sessionTag, :final message):
        if (sessionTag != _tag) {
          _violation(ViolationKind.wrongSession);
          return;
        }
        _onMessage(message, fromReliable: fromReliable);
    }
  }

  void _onMessage(WireMessage message, {required bool fromReliable}) {
    switch (message) {
      case HostHello() || HostState() || SurfaceMessage() || Pong():
        _violation(ViolationKind.wrongDirection);
      case PointerMove m:
        _onMove(m);
      case _ when !fromReliable:
        _violation(ViolationKind.wrongChannel);
      case Hello m:
        _onHello(m);
      case Bye():
        _stop(StopReason.viewerLeft);
      case Ping m:
        _send(Pong(id: m.id, viewerMicros: m.viewerMicros));
      case InputMessage m:
        _onReliableInput(m);
    }
  }

  void _onHello(Hello m) {
    if (_handshakeDone) return;
    if (!listEquals(m.nonce, _nonce)) {
      _violation(ViolationKind.wrongSession);
      return;
    }
    if (m.version != remoteInputProtocolVersion) {
      _send(const Bye(ByeReason.unsupportedVersion));
      return;
    }
    _viewerPlatform = m.viewerPlatform;
    _viewerCapabilities = m.capabilities;
    _swapModifiers =
        options.modifierMapping == ModifierMapping.auto &&
        m.viewerPlatform != PeerPlatform.unknown &&
        m.viewerPlatform.isApple != _platform.platform.isApple;
    _handshakeDone = true;
    _update();
  }

  void _onMove(PointerMove m) {
    if (!_handshakeDone) return _drop(DropReason.notReady);
    if (!_notPaused()) return _drop(DropReason.inactive);
    final last = _lastPointerSeq;
    if (last != null && !seqAfter(m.seq, last)) {
      return _drop(DropReason.staleMove);
    }
    final pending = _pendingMove;
    if (pending != null) {
      if (!seqAfter(m.seq, pending.seq)) return _drop(DropReason.staleMove);
      _drop(DropReason.coalesced);
    }
    _pendingMove = m;
    _scheduleMove();
  }

  void _onReliableInput(InputMessage m) {
    _acceptReliable(m);
    // A held move may have been waiting for this message.
    _scheduleMove();
  }

  void _acceptReliable(InputMessage m) {
    if (!_handshakeDone) return _drop(DropReason.notReady);
    final last = _lastReliableSeq;
    if (last != null && !seqAfter(m.seq, last)) {
      _violation(ViolationKind.replayed);
      return;
    }
    _lastReliableSeq = m.seq;
    if (m is ReleaseAll) {
      _queue.clear();
      _releaseHeld();
      return;
    }
    if (!_notPaused()) return _drop(DropReason.inactive);
    var input = m;
    if (input is KeyMessage || input is TextMessage) {
      if (!options.allowKeyboard) return _drop(DropReason.keyboardDisabled);
      if (input is TextMessage) {
        final clean = stripControlCharacters(input.text);
        if (clean.isEmpty) return _drop(DropReason.filtered);
        input = TextMessage(input.seq, clean);
      }
    }
    if (_queue.length >= limits.maxQueuedEvents) {
      _stop(StopReason.flooding);
      return;
    }
    _queue.add(input);
    _drain();
  }

  void _violation(ViolationKind kind) {
    _violations[kind] = (_violations[kind] ?? 0) + 1;
    final now = clock.now().microsecondsSinceEpoch;
    _violationTimes.add(now);
    final cutoff = now - _violationWindow.inMicroseconds;
    while (_violationTimes.isNotEmpty && _violationTimes.first <= cutoff) {
      _violationTimes.removeFirst();
    }
    if (_violationTimes.length > _maxViolations) {
      _stop(StopReason.protocolViolation);
    }
  }

  void _drop(DropReason reason) {
    _dropped[reason] = (_dropped[reason] ?? 0) + 1;
  }

  void _touchHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    if (_heldKeys.isEmpty && _heldButtons.isEmpty) return;
    _heartbeatTimer = Timer(options.heartbeatTimeout, () {
      if (!_stopped) _releaseHeld();
    });
  }

  // --- Rate limiting and dispatch -------------------------------------------

  void _drain() {
    _drainTimer?.cancel();
    _drainTimer = null;
    while (_queue.isNotEmpty && !_stopped) {
      final m = _queue.first;
      if (m is TextMessage) {
        final available = _textBucket.available;
        if (available == 0) {
          _scheduleDrain(_textBucket.timeUntil());
          return;
        }
        final runes = m.text.runes;
        if (runes.length <= available) {
          _textBucket.tryTake(runes.length);
          _queue.removeFirst();
          _dispatchText(m.text);
        } else {
          _textBucket.tryTake(available);
          final chunk = String.fromCharCodes(runes.take(available));
          final rest = String.fromCharCodes(runes.skip(available));
          _queue
            ..removeFirst()
            ..addFirst(TextMessage(m.seq, rest));
          _dispatchText(chunk);
        }
      } else {
        if (!_eventBucket.tryTake()) {
          _scheduleDrain(_eventBucket.timeUntil());
          return;
        }
        _queue.removeFirst();
        switch (m) {
          case PointerButtonMessage m:
            _dispatchButton(m);
          case Wheel m:
            _dispatchWheel(m);
          case KeyMessage m:
            _dispatchKey(m);
          case TextMessage() || PointerMove() || ReleaseAll():
            break; // Handled elsewhere; never queued.
        }
      }
    }
    if (_queue.isEmpty) _scheduleMove();
  }

  void _scheduleDrain(Duration after) {
    _drainTimer = Timer(after, _drain);
  }

  void _scheduleMove() {
    if (_pendingMove == null || _queue.isNotEmpty || _moveTimer != null) {
      return;
    }
    final now = clock.now().microsecondsSinceEpoch;
    final last = _lastMoveMicros;
    final wait = last == null ? 0 : last + _moveIntervalMicros - now;
    if (wait <= 0) {
      _applyMove();
    } else {
      _moveTimer = Timer(Duration(microseconds: wait), () {
        _moveTimer = null;
        _applyMove();
      });
    }
  }

  void _dropPendingMove(DropReason reason) {
    if (_pendingMove == null) return;
    _pendingMove = null;
    _moveTimer?.cancel();
    _moveTimer = null;
    _drop(reason);
  }

  void _applyMove() {
    final m = _pendingMove;
    if (m == null || _stopped || _queue.isNotEmpty) return;
    _pendingMove = null;
    final last = _lastPointerSeq;
    if (last != null && !seqAfter(m.seq, last)) {
      return _drop(DropReason.staleMove);
    }
    if (_awaitsReliable(m)) {
      // The click this move follows is still in flight: hold the move until
      // it arrives (or a newer move replaces it).
      _pendingMove = m;
      return;
    }
    if (m.surfaceEpoch != _epoch) return _drop(DropReason.staleEpoch);
    if (m.buttons != PointerButton.maskOf(_heldButtons)) {
      return _drop(DropReason.inconsistentMove);
    }
    final point = _pointFor(m);
    if (point == null) return;
    if (!_onSurface(point)) return _drop(DropReason.occluded);
    if (!_secureAllows(InputKind.pointer, point)) {
      return _drop(DropReason.inactive);
    }
    _lastPointerSeq = m.seq;
    _lastMoveMicros = clock.now().microsecondsSinceEpoch;
    final held = Set<PointerButton>.unmodifiable(_heldButtons);
    final r = _inject(
      InputKind.pointer,
      () => _platform.injector.movePointer(point, heldButtons: held),
    );
    if (r == InjectResult.injected) _lastPointerPoint = point;
  }

  /// Whether [m] follows reliable input that hasn't arrived yet.
  bool _awaitsReliable(PointerMove m) {
    if (m.reliableSeq == m.seq) return false;
    final last = _lastReliableSeq;
    return last == null || seqAfter(m.reliableSeq, last);
  }

  void _notePointerSeq(int seq) {
    final last = _lastPointerSeq;
    if (last == null || seqAfter(seq, last)) _lastPointerSeq = seq;
  }

  void _dispatchButton(PointerButtonMessage m) {
    _notePointerSeq(m.seq);
    if (m.surfaceEpoch != _epoch) return _drop(DropReason.staleEpoch);
    final held = _heldButtons.contains(m.button);
    if (m.down == held) return _drop(DropReason.notHeld);
    final point = _pointFor(m);
    if (point == null) return;
    if (m.down) {
      if (!_onSurface(point)) return _drop(DropReason.occluded);
      if (!_secureAllows(InputKind.pointer, point)) {
        return _drop(DropReason.inactive);
      }
    }
    final r = _inject(
      InputKind.pointer,
      () => _platform.injector.pointerButton(
        point,
        m.button,
        down: m.down,
        clickCount: max(1, m.clickCount),
      ),
    );
    if (m.down) {
      if (r == InjectResult.injected) _heldButtons.add(m.button);
    } else {
      _heldButtons.remove(m.button);
    }
    if (r == InjectResult.injected) _lastPointerPoint = point;
    _touchHeartbeat();
  }

  void _dispatchWheel(Wheel m) {
    _notePointerSeq(m.seq);
    if (m.surfaceEpoch != _epoch) return _drop(DropReason.staleEpoch);
    final point = _pointFor(m);
    if (point == null) return;
    if (!_onSurface(point)) return _drop(DropReason.occluded);
    if (!_secureAllows(InputKind.pointer, point)) {
      return _drop(DropReason.inactive);
    }
    final cap = m.unit == WheelUnit.pixel
        ? limits.maxWheelPixels
        : limits.maxWheelLines;
    _inject(
      InputKind.pointer,
      () => _platform.injector.wheel(
        point,
        dx: m.dx.clamp(-cap, cap),
        dy: m.dy.clamp(-cap, cap),
        unit: m.unit,
      ),
    );
  }

  void _dispatchKey(KeyMessage m) {
    var usage = m.usage;
    var modifiers = m.modifiers;
    if (_swapModifiers) {
      usage = swapControlMetaUsage(usage);
      modifiers = swapControlMetaBits(modifiers);
    }
    // Drift: release injected modifiers the viewer no longer reports.
    for (final held in _heldKeys.toList()) {
      final bit = HidModifier.bitOf(held);
      if (bit != 0 && held != usage && modifiers & bit == 0) {
        _releaseKey(held);
      }
    }
    final held = _heldKeys.contains(usage);
    if (m.action == KeyAction.up) {
      if (!held) return _drop(DropReason.notHeld);
      _releaseKey(usage);
      return;
    }
    final repeat = held;
    if (m.action == KeyAction.repeat && !held) {
      return _drop(DropReason.notHeld);
    }
    if (!repeat) {
      if (_heldKeys.length >= limits.maxHeldKeys) {
        return _drop(DropReason.tooManyKeys);
      }
      final filter = options.keyFilter;
      if (filter != null) {
        final press = KeyPress(
          usage: usage,
          heldModifiers: Set.unmodifiable(
            _heldKeys.where(HidModifier.isModifier),
          ),
        );
        if (!filter(press)) return _drop(DropReason.filtered);
      }
    }
    if (!_hasKeyboardFocus()) return _drop(DropReason.notFocused);
    if (!_secureAllows(InputKind.keyboard, null)) {
      return _drop(DropReason.inactive);
    }
    final r = _inject(
      InputKind.keyboard,
      () => _platform.injector.key(usage, down: true, repeat: repeat),
    );
    if (r == InjectResult.injected) {
      _heldKeys.add(usage);
      _touchHeartbeat();
    }
  }

  void _dispatchText(String text) {
    if (!_hasKeyboardFocus()) return _drop(DropReason.notFocused);
    if (!_secureAllows(InputKind.keyboard, null)) {
      return _drop(DropReason.inactive);
    }
    _inject(InputKind.keyboard, () => _platform.injector.text(text));
  }

  /// Calls the injector, unless the session has stopped: the stop flag is
  /// checked immediately before every OS call (`docs/design.md` §6.2).
  InjectResult? _inject(InputKind kind, InjectResult Function() call) {
    if (_stopped) return null;
    final r = call();
    switch (r) {
      case InjectResult.injected:
        _injected++;
      case InjectResult.elevatedTarget:
        _drop(DropReason.failed);
        _setBlocked(BlockReason.elevatedTarget, kind);
      case InjectResult.permissionDenied:
        _drop(DropReason.failed);
        _stop(StopReason.permissionDenied);
      case InjectResult.unmappedKey:
        _drop(DropReason.unmapped);
      case InjectResult.failed:
        _drop(DropReason.failed);
    }
    return r;
  }

  // --- Surfaces and checks --------------------------------------------------

  SurfaceGeometry? _geometryOf(SharedSurface surface) => switch (surface) {
    RectSurface s when s.isClosed => null,
    RectSurface s => SurfaceGeometry(bounds: s.bounds, pixelSize: s.pixelSize),
    _ => _platform.surfaces.resolve(surface),
  };

  /// The desktop point for [m], or `null` (and the session stopped or
  /// blocked) when the surface is gone or hidden.
  Offset? _pointFor(PointerMessage m) {
    final g = _geometryOf(_surface);
    if (g == null) {
      _stop(StopReason.surfaceGone);
      return null;
    }
    if (g.isHidden) {
      _drop(DropReason.inactive);
      _setBlocked(BlockReason.surfaceHidden, InputKind.pointer);
      return null;
    }
    if (_blocked == BlockReason.surfaceHidden) _clearBlocked();
    final bounds = _surface.contentInsets.deflateRect(g.bounds);
    return mapNormalizedPoint(m.x, m.y, bounds);
  }

  bool _onSurface(Offset point) => switch (_surface) {
    WindowSurface s => _platform.surfaces.isOnSurface(s, point),
    _ => true,
  };

  bool _hasKeyboardFocus() => switch (_surface) {
    WindowSurface s => _platform.surfaces.hasKeyboardFocus(s),
    _ => true,
  };

  /// Probes for a secure context, updating the blocked state. Returns
  /// whether [kind] input may be injected.
  bool _secureAllows(InputKind kind, Offset? point) {
    final reason = _platform.secureContext?.check(kind, point: point);
    if (reason != null) {
      _setBlocked(reason, kind);
      return false;
    }
    if (_blocked != null && _blockedKind == kind) _clearBlocked();
    final blocked = _blocked;
    return blocked == null ||
        (kind == InputKind.pointer && !blocked.blocksPointer);
  }

  // --- Releasing ------------------------------------------------------------

  /// Releases every key and button the session holds. The one kind of
  /// input allowed after [stop], so nothing stays stuck down.
  void _releaseHeld() {
    for (final usage in _heldKeys.toList()) {
      _releaseKey(usage);
    }
    _releaseButtons();
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _releaseKey(int usage) {
    _heldKeys.remove(usage);
    _guarded(() => _platform.injector.key(usage, down: false));
  }

  void _releaseButtons() {
    final point = _lastPointerPoint;
    for (final button in _heldButtons.toList()) {
      _heldButtons.remove(button);
      if (point != null) {
        _guarded(
          () => _platform.injector.pointerButton(
            point,
            button,
            down: false,
            clickCount: 1,
          ),
        );
      }
    }
  }

  /// Calls [release], counting it, and never lets a failure stop the other
  /// releases.
  void _guarded(InjectResult Function() release) {
    try {
      if (release() == InjectResult.injected) _injected++;
    } catch (_) {
      _drop(DropReason.failed);
    }
  }

  // --- Sending --------------------------------------------------------------

  void _send(WireMessage message) {
    final channel = _link.reliable;
    if (!channel.isOpen) return;
    channel.send(encodeMessage(message, sessionTag: _tag));
  }
}

/// [text] without control characters, which would act like keys (Escape,
/// Backspace). Tab, line feed and carriage return are kept.
String stripControlCharacters(String text) {
  var clean = true;
  for (final r in text.runes) {
    if (_isStripped(r)) {
      clean = false;
      break;
    }
  }
  if (clean) return text;
  return String.fromCharCodes(text.runes.where((r) => !_isStripped(r)));
}

bool _isStripped(int r) =>
    (r < 0x20 && r != 0x09 && r != 0x0A && r != 0x0D) ||
    (r >= 0x7F && r <= 0x9F);

Uint8List _randomNonce() {
  final random = Random.secure();
  return Uint8List.fromList(
    List.generate(nonceBytes, (_) => random.nextInt(256)),
  );
}

int _pixels(double v) => v.isFinite ? v.round().clamp(0, 0xFFFFFFFF) : 0;
