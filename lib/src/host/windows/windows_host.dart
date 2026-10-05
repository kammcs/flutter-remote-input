import '../../protocol/wire_types.dart';
import '../platform.dart';
import 'win32_api.dart';
import 'windows_activity.dart';
import 'windows_injector.dart';
import 'windows_secure_context.dart';
import 'windows_surfaces.dart';

/// The Windows [HostPlatform] (`docs/design.md` §7.2), on a [Win32Api]: the
/// FFI one in an app (`windowsHostPlatform()`), a fake in unit tests.
final class WindowsHostPlatform implements HostPlatform {
  /// Creates the platform on [api] and [activity].
  WindowsHostPlatform(
    this.api,
    NativeActivity activity, {
    PointerPlacement placement = PointerPlacement.absolute,
  }) : injector = WindowsInjector(api, placement: placement),
       surfaces = WindowsSurfaceResolver(api),
       localActivity = WindowsLocalActivity(activity),
       secureContext = WindowsSecureContextProbe(api);

  /// The Win32 calls.
  final Win32Api api;

  @override
  PeerPlatform get platform => PeerPlatform.windows;

  /// [HostUnavailableReason.dpiUnaware] unless the calling thread is
  /// per-monitor DPI aware (V2), as Flutter's runner manifest makes it.
  /// Otherwise Windows would virtualize the coordinates the package reads
  /// and posts.
  @override
  HostUnavailableReason? checkAvailable() =>
      api.isPerMonitorAwareV2() ? null : HostUnavailableReason.dpiUnaware;

  @override
  final WindowsInjector injector;

  @override
  final WindowsSurfaceResolver surfaces;

  @override
  final WindowsLocalActivity localActivity;

  @override
  final WindowsSecureContextProbe secureContext;
}
