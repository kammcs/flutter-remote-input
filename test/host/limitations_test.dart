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
    for (final p in [PeerPlatform.windows, PeerPlatform.macos]) {
      expect(
        HostLimitation.forPlatform(p),
        contains(HostLimitation.systemKeys),
      );
    }
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

  test('pointer typing is a gap on both host platforms (RIN-49)', () {
    for (final p in [PeerPlatform.windows, PeerPlatform.macos]) {
      expect(
        HostLimitation.forPlatform(p),
        contains(HostLimitation.pointerTyping),
      );
    }
    expect(HostLimitation.pointerTyping.isGap, isTrue);
    expect(
      HostLimitation.forPlatform(PeerPlatform.android),
      isNot(contains(HostLimitation.pointerTyping)),
    );
    // Only it is a gap: the rest are what can't be controlled.
    expect(HostLimitation.values.where((l) => l.isGap), [
      HostLimitation.pointerTyping,
    ]);
  });

  test('follows the current platform', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(RemoteInputHost.limitations, contains(HostLimitation.ctrlAltDel));
  });
}
