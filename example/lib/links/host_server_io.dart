import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

import 'pairing_request.dart';
import 'socket_link.dart';

/// Wrong codes from one address before it is refused for a while.
const int _maxBadCodes = 5;

/// The longest an address is refused.
const Duration _maxLockout = Duration(hours: 1);

/// The most addresses whose wrong codes are remembered.
const int _maxTrackedAddresses = 1024;

/// How long a new socket has to send its pairing message.
const Duration _pairTimeout = Duration(seconds: 10);

/// The host's WebSocket server, for two machines on a LAN.
///
/// **Development only, plaintext.** It listens on every IPv4 interface.
/// A viewer must send the current six-digit [code]; then the person at the
/// host is asked ([requests]) and decides. One viewer at a time: others get
/// [PairingMessage.busy].
///
/// A code is used once: it's replaced after a right guess, or when the
/// person at the host asks ([newCode]). Wrong guesses never replace it, so
/// someone guessing can't lock the real viewer out. Instead each address
/// gets [_maxBadCodes] wrong codes, then is refused
/// ([PairingMessage.tooManyAttempts]) for [lockout], twice as long each
/// time, up to an hour: a handful of guesses an hour at a million codes.
final class HostServer extends ChangeNotifier {
  HostServer._(this._server, this.lockout) {
    _server.listen(_onRequest);
  }

  /// Whether this platform can run the server.
  static bool get isSupported => true;

  /// Starts listening on [port] (0 picks a free one), on every IPv4
  /// interface or on [address]. An address that sends [_maxBadCodes] wrong
  /// codes is refused for [lockout], then twice as long each time.
  static Future<HostServer> start({
    int port = defaultHostPort,
    InternetAddress? address,
    Duration lockout = const Duration(seconds: 30),
  }) async => HostServer._(
    await HttpServer.bind(address ?? InternetAddress.anyIPv4, port),
    lockout,
  );

  final HttpServer _server;

  /// How long an address is refused after its first [_maxBadCodes] wrong
  /// codes.
  final Duration lockout;

  final Random _random = Random.secure();
  final StreamController<PairingRequest> _requests =
      StreamController.broadcast();
  late String _code = _newCode();
  final Map<String, _Guesses> _guesses = {};
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
    final address = remoteAddress ?? '';
    if (_refuseIfLocked(connection, address)) return;
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
    // Again: guesses on other sockets from the address may have locked it
    // while this one waited. The check and the count below run without a
    // gap, so parallel sockets get no more than [_maxBadCodes] guesses.
    if (_refuseIfLocked(connection, address)) return;
    if (isBusy) {
      connection.sendControl({'type': PairingMessage.busy});
      await connection.close();
      return;
    }
    if (hello['code'] != _code) {
      _wrongCode(address);
      connection.sendControl({'type': PairingMessage.badCode});
      await connection.close();
      return;
    }
    // The code is used up, whatever the person at the host decides.
    _guesses.remove(address);
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

  /// If [address] is refused now, tells the viewer how long to wait and
  /// closes. Decides synchronously, so no other socket's guess runs between
  /// the check and the caller's next step.
  bool _refuseIfLocked(SocketConnection connection, String address) {
    final wait = _guesses[address]?.lockedFor(DateTime.now());
    if (wait == null) return false;
    connection
      ..sendControl({
        'type': PairingMessage.tooManyAttempts,
        'retryAfter': (wait.inMilliseconds / 1000).ceil(),
      })
      ..close();
    return true;
  }

  void _wrongCode(String address) {
    final now = DateTime.now();
    if (!_guesses.containsKey(address) &&
        _guesses.length >= _maxTrackedAddresses) {
      _guesses.removeWhere((_, g) => g.isStale(now));
      if (_guesses.length >= _maxTrackedAddresses) {
        // Still full: forget the oldest address that isn't refused now.
        final oldest = _guesses.entries
            .where((e) => e.value.lockedFor(now) == null)
            .firstOrNull;
        if (oldest != null) _guesses.remove(oldest.key);
      }
    }
    _guesses.putIfAbsent(address, _Guesses.new).wrong(lockout, now);
  }
}

/// The wrong codes from one address.
final class _Guesses {
  int _wrong = 0;
  int _lockouts = 0;
  DateTime? _lockedUntil;
  DateTime _last = DateTime.now();

  /// How much longer the address is refused, or `null` if it isn't.
  Duration? lockedFor(DateTime now) {
    final until = _lockedUntil;
    if (until == null || !until.isAfter(now)) return null;
    return until.difference(now);
  }

  /// Nothing worth remembering: not refused, and quiet for the longest
  /// lockout.
  bool isStale(DateTime now) =>
      lockedFor(now) == null && now.difference(_last) > _maxLockout;

  /// Counts a wrong code. Every [_maxBadCodes]th refuses the address for
  /// [base], doubled for each earlier time, up to [_maxLockout].
  void wrong(Duration base, DateTime now) {
    _last = now;
    if (++_wrong < _maxBadCodes) return;
    _wrong = 0;
    final lock = base * (1 << min(_lockouts++, 16));
    _lockedUntil = now.add(lock > _maxLockout ? _maxLockout : lock);
  }
}
