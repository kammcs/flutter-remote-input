import 'dart:io' show Platform;

import 'macos/macos_platform.dart';
import 'platform.dart';
import 'windows/windows_platform.dart';

/// This platform's [HostPlatform], or `null` where there is no injector
/// (Linux, Android, iOS: `docs/design.md` §2.2).
HostPlatform? defaultHostPlatform() {
  if (Platform.isWindows) return windowsHostPlatform();
  if (Platform.isMacOS) return macosHostPlatform();
  return null;
}
