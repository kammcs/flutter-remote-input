// The development WebSocket link and its pairing, over real sockets on the
// loopback interface. Nothing is injected: the host runs on fakes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/testing.dart';
import 'package:remote_input_example/links/host_server.dart';
import 'package:remote_input_example/links/socket_link.dart';
import 'package:remote_input_example/links/viewer_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late HostServer server;
  late Uri uri;

  setUp(() async {
    server = await HostServer.start(port: 0);
    uri = Uri.parse('ws://127.0.0.1:${server.port}');
  });

  tearDown(() async {
    RemoteInputHost.stopAll();
    await server.close();
  });

  test('parses what a viewer types as the address', () {
    expect(hostUri('192.168.1.20'), Uri.parse('ws://192.168.1.20:47800'));
    expect(hostUri('192.168.1.20:1234'), Uri.parse('ws://192.168.1.20:1234'));
    expect(hostUri('ws://my-mac.local'), Uri.parse('ws://my-mac.local:47800'));
    expect(hostUri(''), isNull);
    expect(hostUri('http://x'), isNull);
  });

  test('a viewer with the code, once allowed, controls the host', () async {
    final platform = FakeHostPlatform();
    ControlSession? session;
    final sub = server.requests.listen((request) {
      expect(request.name, 'Test viewer');
      final connection = request.accept();
      session = RemoteInputHost(platform: platform)
          .enable(link: connection.link, surface: SharedSurface.display(1));
    });
    final code = server.code;
    final connection = await connectToHost(
      uri,
      code: code,
      name: 'Test viewer',
    );
    expect(server.code, isNot(code), reason: 'A code works once');
    expect(server.isBusy, isTrue);

    final viewer = RemoteInputViewer(link: connection.link);
    await _until(() => viewer.state.isActive);
    expect(viewer.surface?.pixelSize.width, 1920);

    viewer.click(const Offset(0.5, 0.5));
    await _until(() => platform.injector.events.length >= 2);
    expect(platform.injector.events.first, isA<InjectedButton>());

    session!.stop();
    await _until(() => viewer.state.isStopped);
    expect(viewer.state, const SessionStopped(StopReason.byHost));

    await viewer.close();
    await connection.close();
    await sub.cancel();
  });

  test('a wrong code is refused', () async {
    final wrong = server.code == '000000' ? '111111' : '000000';
    await expectLater(
      connectToHost(uri, code: wrong, name: 'x'),
      throwsA(
        isA<PairingException>().having(
          (e) => e.failure,
          'failure',
          PairingFailure.badCode,
        ),
      ),
    );
  });

  test('the person at the host can say no', () async {
    final sub = server.requests.listen((request) => request.deny());
    await expectLater(
      connectToHost(uri, code: server.code, name: 'x'),
      throwsA(
        isA<PairingException>().having(
          (e) => e.failure,
          'failure',
          PairingFailure.denied,
        ),
      ),
    );
    await sub.cancel();
  });

  test('one viewer at a time', () async {
    final first = Completer<PairingRequest>();
    final sub = server.requests.listen(first.complete);
    unawaited(
      connectToHost(
        uri,
        code: server.code,
        name: 'first',
      ).then((c) => c.close(), onError: (Object _) {}),
    );
    final waiting = await first.future;
    await expectLater(
      connectToHost(uri, code: server.code, name: 'second'),
      throwsA(
        isA<PairingException>().having(
          (e) => e.failure,
          'failure',
          PairingFailure.busy,
        ),
      ),
    );
    waiting.deny();
    await sub.cancel();
  });

  group('guessing the code', () {
    Matcher fails(PairingFailure failure) => throwsA(
      isA<PairingException>().having((e) => e.failure, 'failure', failure),
    );

    String wrongCode() => server.code == '000000' ? '111111' : '000000';

    test('wrong codes never replace it; five refuse the address for a '
        'while', () async {
      await server.close();
      server = await HostServer.start(
        port: 0,
        lockout: const Duration(milliseconds: 600),
      );
      uri = Uri.parse('ws://127.0.0.1:${server.port}');
      final code = server.code;
      for (var i = 0; i < 5; i++) {
        await expectLater(
          connectToHost(uri, code: wrongCode(), name: 'x'),
          fails(PairingFailure.badCode),
        );
      }
      expect(server.code, code, reason: "A guesser can't rotate the code");

      // Refused now, even with the right code, and told how long to wait.
      await expectLater(
        connectToHost(uri, code: code, name: 'x'),
        throwsA(
          isA<PairingException>()
              .having(
                (e) => e.failure,
                'failure',
                PairingFailure.tooManyAttempts,
              )
              .having((e) => e.retryAfter, 'retryAfter', isNotNull),
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 700));
      final sub = server.requests.listen((r) => r.deny());
      await expectLater(
        connectToHost(uri, code: code, name: 'x'),
        fails(PairingFailure.denied),
      );
      await sub.cancel();
    });

    test('parallel guesses from one address get five tries', () async {
      final results = await Future.wait([
        for (var i = 0; i < 20; i++)
          connectToHost(uri, code: wrongCode(), name: 'x').then<Object>(
            (c) => c.close(),
            onError: (Object e) => (e as PairingException).failure,
          ),
      ]);
      expect(results.where((f) => f == PairingFailure.badCode), hasLength(5));
      expect(
        results.where((f) => f == PairingFailure.tooManyAttempts),
        hasLength(15),
      );
    });

    test("a guesser can't lock out a viewer at another address", () async {
      await server.close();
      try {
        // Dual-stack: 127.0.0.1 and ::1 are two addresses.
        server = await HostServer.start(
          port: 0,
          address: InternetAddress.anyIPv6,
        );
      } on SocketException {
        markTestSkipped('No IPv6 loopback here');
        return;
      }
      final guesser = Uri.parse('ws://127.0.0.1:${server.port}');
      final viewer = Uri.parse('ws://[::1]:${server.port}');
      final code = server.code;
      for (var i = 0; i < 6; i++) {
        await expectLater(
          connectToHost(guesser, code: wrongCode(), name: 'x'),
          throwsA(isA<PairingException>()),
        );
      }
      final sub = server.requests.listen((r) => r.deny());
      await expectLater(
        connectToHost(viewer, code: code, name: 'x'),
        fails(PairingFailure.denied),
      );
      await sub.cancel();
    });
  });

  group('frames before pairing', () {
    Future<WebSocketChannel> open() async {
      final socket = WebSocketChannel.connect(uri);
      await socket.ready;
      return socket;
    }

    test('a few are kept', () async {
      final request = server.requests.first;
      final socket = await open();
      for (var i = 0; i < SocketConnection.maxEarlyFrames; i++) {
        socket.sink.add(Uint8List(1));
      }
      socket.sink.add(
        jsonEncode({'type': PairingMessage.pair, 'code': server.code}),
      );
      (await request.timeout(const Duration(seconds: 5))).deny();
      await socket.sink.close();
    });

    for (final (what, count, size) in [
      ('too many', SocketConnection.maxEarlyFrames + 1, 1),
      ('too many bytes', 2, SocketConnection.maxEarlyBytes ~/ 2 + 1),
    ]) {
      test('$what drop the socket', () async {
        final socket = await open();
        for (var i = 0; i < count; i++) {
          socket.sink.add(Uint8List(size));
        }
        // Closed by the host well before its 10 s pairing timeout.
        await socket.stream.drain<void>().timeout(const Duration(seconds: 5));
        expect(server.isBusy, isFalse);
      });
    }
  });

  test('an unreachable host is reported', () async {
    final port = server.port;
    await server.close();
    await expectLater(
      connectToHost(Uri.parse('ws://127.0.0.1:$port'), code: '1', name: 'x'),
      throwsA(
        isA<PairingException>().having(
          (e) => e.failure,
          'failure',
          PairingFailure.unreachable,
        ),
      ),
    );
  });
}
