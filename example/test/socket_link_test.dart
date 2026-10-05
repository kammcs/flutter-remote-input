// The development WebSocket link and its pairing, over real sockets on the
// loopback interface. Nothing is injected: the host runs on fakes.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/testing.dart';
import 'package:remote_input_example/links/host_server.dart';
import 'package:remote_input_example/links/viewer_client.dart';

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
