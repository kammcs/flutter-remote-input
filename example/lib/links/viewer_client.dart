import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'socket_link.dart';

/// Why pairing with a host failed.
enum PairingFailure {
  /// The address couldn't be reached, or isn't the example's host.
  unreachable(
    'Couldn\'t reach the host. Check the address, and that both '
    'devices are on the same network.',
  ),

  /// The code was wrong (or already used: each code works once).
  badCode(
    'The code was wrong, or has been used. Codes work once: check the '
    'one the host shows now.',
  ),

  /// The person at the host said no.
  denied('The person at the host said no.'),

  /// Another viewer is connected or waiting.
  busy('Someone else is controlling, or asking to control, that computer.'),

  /// Too many wrong codes from this device: the host refuses it for a
  /// while ([PairingException.retryAfter]).
  tooManyAttempts(
    'Too many wrong codes from this device. Wait, then enter the code the '
    'host shows.',
  ),

  /// No answer in time.
  timeout('No answer from the host in time.'),

  /// The connection closed during pairing.
  closed('The host closed the connection.');

  const PairingFailure(this.message);

  /// A message for the viewer's UI.
  final String message;
}

/// Thrown by [connectToHost].
final class PairingException implements Exception {
  /// Creates a [PairingException].
  const PairingException(this.failure, {this.retryAfter});

  /// Why.
  final PairingFailure failure;

  /// For [PairingFailure.tooManyAttempts]: how long until the host takes a
  /// code from this device again, if it said.
  final Duration? retryAfter;

  /// [failure]'s message, with the wait if the host gave one.
  String get message {
    final wait = retryAfter;
    if (wait == null) return failure.message;
    final s = wait.inSeconds;
    final text = s < 120 ? '$s seconds' : '${(s / 60).ceil()} minutes';
    return '${failure.message} Try again in $text.';
  }

  @override
  String toString() => 'PairingException(${failure.name})';
}

/// Parses what the viewer typed as the host's address: `192.168.1.20`,
/// `192.168.1.20:47800`, `my-mac.local` or a full `ws://` URL. Returns
/// `null` if it can't be one.
Uri? hostUri(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;
  final withScheme = text.contains('://') ? text : 'ws://$text';
  final uri = Uri.tryParse(withScheme);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'ws' && uri.scheme != 'wss') return null;
  return uri.hasPort ? uri : uri.replace(port: defaultHostPort);
}

/// Connects to the example's host at [uri], gives [code], and waits for the
/// person at the host to allow control (up to [consentTimeout]).
///
/// Returns the connection with its link open, ready for a
/// `RemoteInputViewer`. Throws a [PairingException].
Future<SocketConnection> connectToHost(
  Uri uri, {
  required String code,
  required String name,
  Duration connectTimeout = const Duration(seconds: 8),
  Duration consentTimeout = const Duration(minutes: 2),
  Future<void>? cancel,
}) async {
  final WebSocketChannel socket;
  try {
    socket = WebSocketChannel.connect(uri);
    await socket.ready.timeout(connectTimeout);
  } on Object {
    throw const PairingException(PairingFailure.unreachable);
  }
  final connection = SocketConnection(socket);
  final answer = Completer<PairingFailure?>();
  Duration? retryAfter;
  final sub = connection.control.listen((m) {
    if (answer.isCompleted) return;
    switch (m['type']) {
      case PairingMessage.accepted:
        answer.complete(null);
      case PairingMessage.denied:
        answer.complete(PairingFailure.denied);
      case PairingMessage.badCode:
        answer.complete(PairingFailure.badCode);
      case PairingMessage.busy:
        answer.complete(PairingFailure.busy);
      case PairingMessage.tooManyAttempts:
        final seconds = m['retryAfter'];
        if (seconds is int && seconds >= 0 && seconds <= 24 * 3600) {
          retryAfter = Duration(seconds: seconds);
        }
        answer.complete(PairingFailure.tooManyAttempts);
    }
  });
  unawaited(
    connection.done.then((_) {
      if (!answer.isCompleted) answer.complete(PairingFailure.closed);
    }),
  );
  unawaited(
    cancel?.then((_) {
      if (!answer.isCompleted) answer.complete(PairingFailure.closed);
    }),
  );
  connection.sendControl({
    'type': PairingMessage.pair,
    'code': code.trim(),
    'name': name,
  });
  PairingFailure? failure;
  try {
    failure = await answer.future.timeout(consentTimeout);
  } on TimeoutException {
    failure = PairingFailure.timeout;
  } finally {
    await sub.cancel();
  }
  if (failure != null) {
    await connection.close();
    throw PairingException(
      failure,
      retryAfter: failure == PairingFailure.tooManyAttempts ? retryAfter : null,
    );
  }
  connection.openLink();
  return connection;
}
