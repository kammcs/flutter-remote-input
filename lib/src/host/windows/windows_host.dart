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
  ///
  /// Then [HostUnavailableReason.elevatedHost] when this process
  /// [isElevated], unless [allowElevatedHost].
  @override
  HostUnavailableReason? checkAvailable({bool allowElevatedHost = false}) {
    if (!api.isPerMonitorAwareV2()) return HostUnavailableReason.dpiUnaware;
    if (!allowElevatedHost && isElevated) {
      return HostUnavailableReason.elevatedHost;
    }
    return null;
  }

  /// Whether this process runs elevated: its integrity level is High
  /// ("Run as administrator", or any app of an administrator with UAC
  /// off) or above (System). A level that can't be read counts as
  /// elevated: fail closed.
  bool get isElevated {
    final level = api.ownIntegrityLevel;
    return level == null || level >= IntegrityLevel.high;
  }

  @override
  final WindowsInjector injector;

  @override
  final WindowsSurfaceResolver surfaces;

  @override
  final WindowsLocalActivity localActivity;

  @override
  final WindowsSecureContextProbe secureContext;
}
