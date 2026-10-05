import 'dart:io' show Platform;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('remote_input');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <String>[];
  var granted = false;

  setUp(() {
    calls.clear();
    granted = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'postEventAccess' || 'requestPostEventAccess' => granted,
        'openAccessibilitySettings' => true,
        _ => null,
      };
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  group('macOS', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.macOS);

    test('status asks the native side', () async {
      expect(
        await RemoteInputPermissions.status(),
        RemoteInputPermissionStatus.denied,
      );
      granted = true;
      expect(
        await RemoteInputPermissions.status(),
        RemoteInputPermissionStatus.granted,
      );
      expect(calls, ['postEventAccess', 'postEventAccess']);
    });

    test('request asks for access', () async {
      expect(
        await RemoteInputPermissions.request(),
        RemoteInputPermissionStatus.denied,
      );
      expect(calls, ['requestPostEventAccess']);
    });

    test('openSettings opens the Accessibility pane', () async {
      expect(await RemoteInputPermissions.openSettings(), isTrue);
      expect(calls, ['openAccessibilitySettings']);
    });

    test('without the plugin: unsupported, and settings don\'t open', () async {
      messenger.setMockMethodCallHandler(channel, null);
      expect(
        await RemoteInputPermissions.status(),
        RemoteInputPermissionStatus.unsupported,
      );
      expect(await RemoteInputPermissions.openSettings(), isFalse);
    });

    test('statusChanges emits the status, then each change, while '
        'listened', () {
      fakeAsync((async) {
        final seen = <RemoteInputPermissionStatus>[];
        final sub = RemoteInputPermissions.statusChanges.listen(seen.add);
        async.flushMicrotasks();
        expect(seen, [RemoteInputPermissionStatus.denied]);
        async.elapse(const Duration(seconds: 3));
        expect(seen, [RemoteInputPermissionStatus.denied]);
        granted = true;
        async.elapse(const Duration(seconds: 1));
        expect(seen, [
          RemoteInputPermissionStatus.denied,
          RemoteInputPermissionStatus.granted,
        ]);
        sub.cancel();
        final polled = calls.length;
        async.elapse(const Duration(seconds: 5));
        expect(calls.length, polled);
      });
    });
  });

  group('Windows', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.windows);

    test('no permission is needed', () async {
      expect(
        await RemoteInputPermissions.status(),
        RemoteInputPermissionStatus.notRequired,
      );
      expect(
        await RemoteInputPermissions.request(),
        RemoteInputPermissionStatus.notRequired,
      );
      expect(await RemoteInputPermissions.openSettings(), isFalse);
      expect(calls, isEmpty);
    });

    test('statusChanges emits once', () {
      fakeAsync((async) {
        final seen = <RemoteInputPermissionStatus>[];
        RemoteInputPermissions.statusChanges.listen(seen.add);
        async.elapse(const Duration(seconds: 5));
        expect(seen, [RemoteInputPermissionStatus.notRequired]);
      });
    });
  });

  test('other platforms are unsupported', () async {
    for (final p in [
      TargetPlatform.linux,
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      debugDefaultTargetPlatformOverride = p;
      expect(
        await RemoteInputPermissions.status(),
        RemoteInputPermissionStatus.unsupported,
      );
      expect(
        await RemoteInputPermissions.request(),
        RemoteInputPermissionStatus.unsupported,
      );
    }
    expect(calls, isEmpty);
  });

  test('without the plugin linked in, a Mac is not a host', () {
    // `flutter test` runs without the plugin's native code, so the macOS
    // platform's symbol lookup finds nothing.
    expect(RemoteInputHost.isSupported, isFalse);
  }, skip: Platform.isWindows ? 'Windows injects without plugin code' : false);
}
