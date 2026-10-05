import '../platform.dart';
import 'macos_ffi.dart';
import 'macos_host.dart';

HostPlatform? _platform;
bool _looked = false;

/// The macOS [HostPlatform] (roadmap M3), created once per process, or
/// `null` if the plugin's native code isn't in this process (for example
/// under `flutter test`).
HostPlatform? macosHostPlatform() {
  if (!_looked) {
    _looked = true;
    final native = FfiMacosNative.open();
    if (native != null) _platform = MacosHostPlatform(native);
  }
  return _platform;
}
