import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';

void main() {
  test('lists what each platform cannot control', () {
    expect(
      HostLimitation.forPlatform(PeerPlatform.windows),
      contains(HostLimitation.elevatedApps),
    );
    expect(
      HostLimitation.forPlatform(PeerPlatform.macos),
      contains(HostLimitation.passwordFields),
    );
    for (final p in [
      PeerPlatform.ios,
      PeerPlatform.android,
      PeerPlatform.linux,
    ]) {
      expect(HostLimitation.forPlatform(p), [
        HostLimitation.unsupportedPlatform,
      ]);
    }
    expect(HostLimitation.forPlatform(PeerPlatform.macos, isWeb: true), [
      HostLimitation.unsupportedPlatform,
    ]);
  });

  test('follows the current platform', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(RemoteInputHost.limitations, contains(HostLimitation.ctrlAltDel));
  });
}
