import 'package:flutter/foundation.dart';

import 'pairing_request.dart';
import 'socket_link.dart';

/// The host's WebSocket server. Not available here: a web page can't
/// listen for connections.
final class HostServer extends ChangeNotifier {
  HostServer._();

  /// Whether this platform can run the server.
  static bool get isSupported => false;

  /// Throws an [UnsupportedError].
  static Future<HostServer> start({int port = defaultHostPort}) =>
      throw UnsupportedError('The host server needs dart:io');

  /// The port.
  int get port => 0;

  /// The pairing code.
  String get code => '';

  /// Viewers waiting for consent.
  Stream<PairingRequest> get requests => const Stream.empty();

  /// Whether a viewer is connected or waiting.
  bool get isBusy => false;

  /// Makes a new code.
  void newCode() {}

  /// This machine's LAN addresses.
  Future<List<String>> addresses() async => const [];

  /// Stops listening.
  Future<void> close() async {}
}
