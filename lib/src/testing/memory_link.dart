import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../link.dart';
import '../util/state_value.dart';

/// An in-memory [InputLink], for tests and one-process demos
/// (`docs/design.md` §4). Create a connected pair with [pair].
final class MemoryInputLink implements InputLink {
  MemoryInputLink._(this.reliable, this.unreliable);

  /// A connected pair: what one end sends, the other receives.
  ///
  /// The unreliable channel drops each message with probability [loss], and
  /// with [reorder] delivers them out of order. Both channels add [delay].
  /// The reliable channel never drops or reorders. [random] makes loss and
  /// reordering repeatable. With [open] false, the pair starts closed until
  /// [open] is called on either end.
  static ({MemoryInputLink host, MemoryInputLink viewer}) pair({
    double loss = 0,
    bool reorder = false,
    Duration delay = Duration.zero,
    Random? random,
    bool open = true,
  }) {
    if (loss < 0 || loss > 1) {
      throw ArgumentError.value(loss, 'loss', 'must be between 0 and 1');
    }
    final rng = random ?? Random();
    final core = _PairCore(open);
    MemoryInputChannel channel({required bool reliable}) {
      final c = MemoryInputChannel._(
        core,
        reliable: reliable,
        loss: reliable ? 0 : loss,
        reorder: !reliable && reorder,
        delay: delay,
        random: rng,
      );
      core.channels.add(c);
      return c;
    }

    final hostReliable = channel(reliable: true);
    final viewerReliable = channel(reliable: true);
    final hostUnreliable = channel(reliable: false);
    final viewerUnreliable = channel(reliable: false);
    hostReliable._peer = viewerReliable;
    viewerReliable._peer = hostReliable;
    hostUnreliable._peer = viewerUnreliable;
    viewerUnreliable._peer = hostUnreliable;
    return (
      host: MemoryInputLink._(hostReliable, hostUnreliable),
      viewer: MemoryInputLink._(viewerReliable, viewerUnreliable),
    );
  }

  @override
  final MemoryInputChannel reliable;

  @override
  final MemoryInputChannel unreliable;

  /// Opens the pair, for one created with `open: false`.
  void open() => reliable._core.state.set(true);

  /// Closes the pair, both ends and both channels, for good: the messages
  /// streams complete.
  void close() => reliable._core.close();
}

/// One channel of a [MemoryInputLink].
final class MemoryInputChannel implements InputChannel {
  MemoryInputChannel._(
    this._core, {
    required this.reliable,
    required this._loss,
    required this._reorder,
    required this._delay,
    required this._random,
  });

  final _PairCore _core;
  StateValue<bool> get _state => _core.state;

  /// Whether this is the reliable channel.
  final bool reliable;

  final double _loss;
  final bool _reorder;
  final Duration _delay;
  final Random _random;
  late final MemoryInputChannel _peer;
  final StreamController<Uint8List> _incoming = StreamController.broadcast();
  int _inFlight = 0;
  int _sent = 0;
  int _lost = 0;

  @override
  Stream<Uint8List> get messages => _incoming.stream;

  @override
  bool get isOpen => _state.value;

  @override
  Stream<bool> get openChanges => _state.stream;

  @override
  int? get bufferedAmount => _inFlight;

  /// Messages sent on this end.
  int get sentCount => _sent;

  /// Messages this end's sends lost to simulated loss.
  int get lostCount => _lost;

  @override
  void send(Uint8List message) {
    if (!_state.value) return;
    _sent++;
    if (_loss > 0 && _random.nextDouble() < _loss) {
      _lost++;
      return;
    }
    final copy = Uint8List.fromList(message);
    _inFlight += copy.length;
    void deliver() {
      _inFlight -= copy.length;
      if (_state.value && !_peer._incoming.isClosed) _peer._incoming.add(copy);
    }

    var delay = _delay;
    if (_reorder) {
      delay += Duration(microseconds: _random.nextInt(4000));
    }
    if (delay == Duration.zero) {
      scheduleMicrotask(deliver);
    } else {
      Timer(delay, deliver);
    }
  }
}

/// What the four channels of a pair share.
final class _PairCore {
  _PairCore(bool open) : state = StateValue<bool>(open);

  final StateValue<bool> state;
  final List<MemoryInputChannel> channels = [];

  void close() {
    if (state.isClosed) return;
    state
      ..set(false)
      ..close();
    for (final c in channels) {
      c._incoming.close();
    }
  }
}
