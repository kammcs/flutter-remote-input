import '../platform.dart';
import 'win32_ffi.dart';
import 'windows_host.dart';
import 'windows_injector.dart';

WindowsHostPlatform? _instance;
bool _opened = false;

/// The Windows [HostPlatform] (roadmap M2, `docs/design.md` §7.2): one
/// instance per isolate, or `null` if the plugin's native library isn't
/// loaded (a plain `flutter test` run, for example).
HostPlatform? windowsHostPlatform() {
  if (!_opened) {
    _opened = true;
    final api = FfiWin32Api.open();
    if (api != null) _instance = WindowsHostPlatform(api, api);
  }
  return _instance;
}

/// A separate Windows platform that places the pointer with [placement],
/// for the integration test that compares the two placements. It shares
/// the native activity hooks with [windowsHostPlatform]'s, so only one of
/// them may be in use at a time.
WindowsHostPlatform? createWindowsHostPlatform({
  required PointerPlacement placement,
}) {
  final api = FfiWin32Api.open();
  return api == null
      ? null
      : WindowsHostPlatform(api, api, placement: placement);
}
