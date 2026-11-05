import '../platform.dart';
import 'linux_ffi.dart';
import 'linux_host.dart';
import 'linux_native.dart';
import 'linux_portal.dart';

LinuxNative? _native;
LinuxHostPlatform? _platform;
bool _looked = false;

LinuxNative? _open() {
  if (!_looked) {
    _looked = true;
    _native = FfiLinuxNative.open();
  }
  return _native;
}

/// The Linux [HostPlatform] (`docs/design.md` §7.5), created once per
/// process, or `null` if the plugin's library isn't in this process (a
/// plain `flutter test` run, say) or the session is neither X11 nor
/// Wayland.
HostPlatform? linuxHostPlatform() {
  final native = _open();
  if (native == null || native.backend == LinuxBackend.none) return null;
  return _platform ??= LinuxHostPlatform(
    native,
    revoked: RemoteInputPortal.closed.map((_) {}),
    contentSizeOf: RemoteInputPortal.contentSizeOf,
  );
}

/// Whether this Linux host injects through Wayland.
bool linuxIsWayland() => _open()?.backend == LinuxBackend.wayland;

/// The Linux backend, or `null` without the plugin's library.
LinuxBackend? linuxBackend() => _open()?.backend;

/// Whether a Wayland portal session is connected.
bool linuxPortalConnected() => _open()?.wlConnected() ?? false;
