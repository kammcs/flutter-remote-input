import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

import 'pairing_request.dart';
import 'socket_link.dart';

/// Wrong codes in a row before the code is replaced.
const int _maxBadCodes = 5;

/// How long a new socket has to send its pairing message.
const Duration _pairTimeout = Duration(seconds: 10);

/// The host's WebSocket server, for two machines on a LAN.
///
/// **Development only, plaintext.** It listens on every IPv4 interface.
/// A viewer must send the current six-digit [code]; then the person at the
/// host is asked ([requests]) and decides. One viewer at a time: others get
/// [PairingMessage.busy]. A code is used once: after a right guess, or
/// [_maxBadCodes] wrong ones, it's replaced.
final class HostServer extends ChangeNotifier {
  HostServer._(this._server) {
    _server.listen(_onRequest);
  }

  /// Whether this platform can run the server.
  static bool get isSupported => true;

  /// Starts listening on [port] (0 picks a free one).
  static Future<HostServer> start({int port = defaultHostPort}) async =>
      HostServer._(await HttpServer.bind(InternetAddress.anyIPv4, port));

  final HttpServer _server;
  final Random _random = Random.secure();
  final StreamController<PairingRequest> _requests =
      StreamController.broadcast();
  late String _code = _newCode();
  int _badCodes = 0;
  SocketConnection? _current;
  bool _closed = false;

  /// The port it listens on.
  int get port => _server.port;

  /// The pairing code the viewer must enter.
  String get code => _code;

  /// Viewers that gave the right code, waiting for consent.
  Stream<PairingRequest> get requests => _requests.stream;

  /// Whether a viewer is connected or waiting for consent.
  bool get isBusy => !(_current?.isClosed ?? true);

  /// Replaces the code.
  void newCode() {
    _code = _newCode();
    _badCodes = 0;
    if (!_closed) notifyListeners();
  }

  /// This machine's IPv4 addresses on its network interfaces, for the
  /// viewer to connect to.
  Future<List<String>> addresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      return [
        for (final i in interfaces)
          for (final a in i.addresses) a.address,
      ];
    } on SocketException {
      return const [];
    }
  }

  /// Stops listening, and closes the connection to the current viewer.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _current?.close();
    await _server.close(force: true);
    await _requests.close();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }

  String _newCode() => _random.nextInt(1000000).toString().padLeft(6, '0');

  Future<void> _onRequest(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response
        ..statusCode = HttpStatus.upgradeRequired
        ..write('remote_input example host: connect with the example app.');
      await request.response.close();
      return;
    }
    final remoteAddress = request.connectionInfo?.remoteAddress.address;
    final WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(request)
        // A viewer that vanishes (Wi-Fi off, laptop closed) closes the
        // socket within seconds, and the session stops with linkClosed.
        ..pingInterval = const Duration(seconds: 5);
    } on Object {
      return;
    }
    final connection = SocketConnection(IOWebSocketChannel(socket));
    if (_closed) {
      await connection.close();
      return;
    }
    Map<String, Object?> hello;
    try {
      hello = await connection.control
          .firstWhere((m) => m['type'] == PairingMessage.pair)
          .timeout(_pairTimeout);
    } on Object {
      await connection.close();
      return;
    }
    if (_closed) {
      await connection.close();
      return;
    }
    if (isBusy) {
      connection.sendControl({'type': PairingMessage.busy});
      await connection.close();
      return;
    }
    if (hello['code'] != _code) {
      connection.sendControl({'type': PairingMessage.badCode});
      await connection.close();
      if (++_badCodes >= _maxBadCodes) newCode();
      return;
    }
    // The code is used up, whatever the person at the host decides.
    newCode();
    final name = hello['name'];
    _current = connection;
    unawaited(
      connection.done.then((_) {
        if (identical(_current, connection)) _current = null;
        if (!_closed) notifyListeners();
      }),
    );
    _requests.add(
      PairingRequest(
        connection,
        name: name is String && name.trim().isNotEmpty
            ? name.trim().substring(0, min(name.trim().length, 64))
            : 'A viewer',
        remoteAddress: remoteAddress,
      ),
    );
    notifyListeners();
  }
}
