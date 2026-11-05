import 'platform.dart';

/// This platform's [HostPlatform]: none on the web.
HostPlatform? defaultHostPlatform() => null;

/// Whether this is a Linux host that injects through Wayland: never on the
/// web.
bool isLinuxWaylandHost() => false;

/// The Linux host's permission state: no host on the web.
int linuxPermissionState() => 0;
