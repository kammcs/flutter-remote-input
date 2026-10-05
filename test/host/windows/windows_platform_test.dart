import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/src/host/windows/windows_injector.dart';
import 'package:remote_input/src/host/windows/windows_platform.dart';

void main() {
  // `flutter test` runs without the app's plugin DLL, on any OS: there is
  // no Windows platform to inject with, and asking again is cheap.
  test('without the plugin library there is no Windows platform', () {
    expect(windowsHostPlatform(), isNull);
    expect(windowsHostPlatform(), isNull);
    expect(
      createWindowsHostPlatform(placement: PointerPlacement.setCursorPos),
      isNull,
    );
  });
}
