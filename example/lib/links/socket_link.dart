// An InputLink over one WebSocket, for two machines on a LAN.
//
// DEVELOPMENT ONLY: the socket is plaintext (ws://), so anyone on the network
// path can read the keystrokes and inject their own. Real apps use an
// encrypted, authenticated transport, such as WebRTC DataChannels
// (docs/design.md §4 and §11).
//
// Frames on the socket:
// - **Text frames** carry the pairing handshake, as small JSON objects
//   ([PairingMessage]).
// - **Binary frames** carry one remote_input protocol message each, after a
//   one-byte channel prefix: [reliableChannelPrefix] or
//   [unreliableChannelPrefix]. A WebSocket is ordered and reliable, so both
//   channels are reliable in practice; the package's stale-move dropping
//   keeps that correct (docs/design.md §4).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:remote_input/remote_input.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// The default TCP port the example's host listens on.
const int defaultHostPort = 47800;

/// The channel prefix of a binary frame for [InputLink.reliable].
const int reliableChannelPrefix = 0;

/// The channel prefix of a binary frame for [InputLink.unreliable].
const int unreliableChannelPrefix = 1;

/// The pairing handshake's message types (text frames).
abstract final class PairingMessage {
  /// Viewer → host: `{"type": "pair", "code": "123456", "name": "..."}`.
  static const String pair = 'pair';

  /// Host → viewer: the person at the host allowed control. Binary frames
  /// follow.
  static const String accepted = 'accepted';

  /// Host → viewer: the person at the host said no.
  static const String denied = 'denied';

  /// Host → viewer: the code was wrong.
  static const String badCode = 'badCode';

  /// Host → viewer: another viewer is connected or waiting.
  static const String busy = 'busy';
}

/// One WebSocket to the other machine: the pairing messages, then an
/// [InputLink].
///
/// The link's channels are closed until [openLink] is called, which each
/// side does once the host has said [PairingMessage.accepted]. A few binary
/// frames that arrive before that are kept for it; more are dropped.
final class SocketConnection {
  /// Wraps [socket], which must already be connected.
  SocketConnection(this._socket) {
    _subscription = _socket.stream.listen(
      _onFrame,
      onDone: _onDone,
      onError: (Object _) => _onDone(),
      cancelOnError: true,
    );
  }

  final WebSocketChannel _socket;
  late final StreamSubscription<Object?> _subscription;
  final StreamController<Map<String, Object?>> _control =
      StreamController.broadcast();
  final StreamController<bool> _openChanges = StreamController.broadcast();
  final Completer<void> _done = Completer();
  bool _linkOpen = false;
  bool _closed = false;

  // Binary frames that arrived before [openLink]: the host's first message
  // can overtake the viewer's handling of the pairing answer. Bounded, so a
  // peer can't make the other side buffer before consent.
  final List<Uint8List> _early = [];
  static const int _maxEarlyFrames = 16;

  late final _SocketChannel _reliable = _SocketChannel(
    this,
    reliableChannelPrefix,
  );
  late final _SocketChannel _unreliable = _SocketChannel(
    this,
    unreliableChannelPrefix,
  );

  /// The input link on this socket.
  late final InputLink link = _SocketInputLink(_reliable, _unreliable);

  /// Pairing messages from the other side.
  Stream<Map<String, Object?>> get control => _control.stream;

  /// Completes when the socket has closed, from either side.
  Future<void> get done => _done.future;

  /// Whether the socket has closed.
  bool get isClosed => _closed;

  /// Sends a pairing message.
  void sendControl(Map<String, Object?> message) {
    if (_closed) return;
    _socket.sink.add(jsonEncode(message));
  }

  /// Opens [link]'s channels: binary frames flow from now on.
  void openLink() {
    if (_closed || _linkOpen) return;
    _linkOpen = true;
    _openChanges.add(true);
    for (final frame in _early) {
      _deliver(frame);
    }
    _early.clear();
  }

  /// Closes the socket. The link's channels close with it.
  Future<void> close() async {
    if (_closed) return;
    unawaited(_socket.sink.close());
    _onDone();
  }

  bool get _isOpen => _linkOpen && !_closed;

  void _send(int prefix, Uint8List message) {
    if (!_isOpen) return;
    final frame = Uint8List(message.length + 1)
      ..[0] = prefix
      ..setRange(1, message.length + 1, message);
    _socket.sink.add(frame);
  }

  void _onFrame(Object? frame) {
    if (_closed) return;
    if (frame is String) {
      // Pairing messages are tiny; anything else is a misbehaving peer.
      if (frame.length > 1024) return;
      try {
        final decoded = jsonDecode(frame);
        if (decoded is Map<String, Object?>) _control.add(decoded);
      } on FormatException {
        // Ignore it.
      }
      return;
    }
    final bytes = switch (frame) {
      Uint8List b => b,
      ByteBuffer b => b.asUint8List(),
      List<int> l => Uint8List.fromList(l),
      _ => null,
    };
    if (bytes == null || bytes.isEmpty) return;
    if (_linkOpen) {
      _deliver(bytes);
    } else if (_early.length < _maxEarlyFrames) {
      _early.add(bytes);
    }
  }

  void _deliver(Uint8List bytes) {
    final payload = Uint8List.sublistView(bytes, 1);
    switch (bytes[0]) {
      case reliableChannelPrefix:
        _reliable._incoming.add(payload);
      case unreliableChannelPrefix:
        _unreliable._incoming.add(payload);
    }
  }

  void _onDone() {
    if (_closed) return;
    _closed = true;
    _early.clear();
    unawaited(_subscription.cancel());
    if (_linkOpen) _openChanges.add(false);
    unawaited(_openChanges.close());
    unawaited(_control.close());
    unawaited(_reliable._incoming.close());
    unawaited(_unreliable._incoming.close());
    _done.complete();
  }
}

final class _SocketInputLink implements InputLink {
  _SocketInputLink(this.reliable, this.unreliable);

  @override
  final InputChannel reliable;

  @override
  final InputChannel unreliable;
}

final class _SocketChannel implements InputChannel {
  _SocketChannel(this._connection, this._prefix);

  final SocketConnection _connection;
  final int _prefix;

  // Single-subscription, so frames that arrive between the pairing answer
  // and the session (or viewer) listening are buffered, not lost.
  final StreamController<Uint8List> _incoming = StreamController();

  @override
  Stream<Uint8List> get messages => _incoming.stream;

  @override
  bool get isOpen => _connection._isOpen;

  @override
  Stream<bool> get openChanges => _connection._openChanges.stream;

  @override
  void send(Uint8List message) => _connection._send(_prefix, message);

  @override
  int? get bufferedAmount => null;
}
