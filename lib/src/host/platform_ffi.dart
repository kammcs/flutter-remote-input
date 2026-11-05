import 'dart:io' show Platform;

import 'linux/linux_native.dart' show LinuxBackend;
import 'linux/linux_platform.dart';
import 'macos/macos_platform.dart';
import 'platform.dart';
import 'windows/windows_platform.dart';

/// This platform's [HostPlatform], or `null` where there is no injector
/// (Android, iOS, and Linux without an X11 or Wayland session:
/// `docs/design.md` §2.2).
HostPlatform? defaultHostPlatform() {
  if (Platform.isWindows) return windowsHostPlatform();
  if (Platform.isMacOS) return macosHostPlatform();
  if (Platform.isLinux) return linuxHostPlatform();
  return null;
}

/// Whether this is a Linux host that injects through Wayland.
bool isLinuxWaylandHost() => Platform.isLinux && linuxIsWayland();

/// The Linux host's permission, for `RemoteInputPermissions`: 0 no host
/// (not Linux, or no plugin library), 1 none needed (X11), 2 granted (a
/// Wayland portal session is open), 3 denied (Wayland without one).
int linuxPermissionState() {
  if (!Platform.isLinux) return 0;
  return switch (linuxBackend()) {
    LinuxBackend.x11 => 1,
    LinuxBackend.wayland => linuxPortalConnected() ? 2 : 3,
    _ => 0,
  };
}
