import 'socket_link.dart';

/// A viewer that gave the right code and is waiting for the person at the
/// host to allow control.
final class PairingRequest {
  /// Creates a request on [connection]. The host server makes these.
  PairingRequest(this.connection, {required this.name, this.remoteAddress});

  /// The socket to the viewer.
  final SocketConnection connection;

  /// The name the viewer gave. **Self-reported:** nothing checks it, so the
  /// consent dialog says so.
  final String name;

  /// The viewer's IP address, if known.
  final String? remoteAddress;

  bool _answered = false;

  /// Whether [accept] or [deny] has been called.
  bool get isAnswered => _answered;

  /// Completes when the viewer leaves before (or after) an answer.
  Future<void> get cancelled => connection.done;

  /// Allows control: tells the viewer, and opens the link. The caller then
  /// enables a session on [SocketConnection.link].
  SocketConnection accept() {
    _answered = true;
    connection
      ..sendControl({'type': PairingMessage.accepted})
      ..openLink();
    return connection;
  }

  /// Refuses control, and closes the socket.
  void deny() {
    _answered = true;
    connection.sendControl({'type': PairingMessage.denied});
    connection.close();
  }
}
