import 'dart:async';

import '../host_types.dart';
import '../platform.dart';
import 'linux_native.dart';

/// The Linux [LocalActivityMonitor] (`docs/design.md` §6.3 and §7.5).
///
/// The plugin's native thread counts the presenter's own input:
/// - **X11:** XInput 2 raw events from every device except the XTEST ones,
///   where the package's XTest input comes from (as Windows' injected flag
///   tells injected input apart): any key, any button or wheel notch, and
///   pointer movement past 4 pixels of travel within 100 ms.
/// - **Wayland:** GNOME's idle time, read every 15 ms. libei input resets
///   it too, so a reset counts only when it's more than 40 ms after the
///   package's last post. While the viewer's input is continuous, the
///   presenter's input isn't seen until its next pause (a gap the app opts
///   into with `HostOptions.allowWayland`).
///
/// This side polls the counter every [pollInterval] while [activity] has a
/// listener, and emits when it grows.
///
/// **Health.** [isMonitoring] is true only while the thread runs, its
/// source is healthy (X11: XInput 2 selected; Wayland: the last idle-time
/// read worked) and its heartbeat is at most [staleAfter] old. When it
/// recovers from being unhealthy, it emits once, since input in the gap
/// went unseen.
///
/// **Lost devices (RIN-41).** udev removals of keyboards and pointing
/// devices (and on X11 XInput 2 slave removals) stop the session. If udev
/// can't be read, the monitor isn't monitoring: it fails closed.
///
/// **Checked before each event (RIN-42).** [checkNow] reads the same
/// counters as a poll, two atomic loads.
final class LinuxLocalActivity
    implements
        LocalActivityMonitor,
        LocalDeviceMonitor,
        LocalActivityCheck,
        LocalInputDiagnostics {
  /// Creates a monitor on [native].
  LinuxLocalActivity(
    this._native, {
    this.pollInterval = const Duration(milliseconds: 10),
    this.retryInterval = const Duration(seconds: 1),
    this.staleAfter = const Duration(milliseconds: 400),
  });

  final LinuxNative _native;

  /// How often the counters and health are read.
  final Duration pollInterval;

  /// How often starting the thread is retried while it's down.
  final Duration retryInterval;

  /// How old the thread's heartbeat (at least every 100 ms) may be.
  final Duration staleAfter;

  late final StreamController<void> _controller = StreamController.broadcast(
    onListen: _start,
    onCancel: _stop,
  );
  final StreamController<void> _devices = StreamController.broadcast();

  Timer? _timer;
  int _last = 0;
  int _lastDevicesLost = 0;
  bool _healthy = false;
  bool _wasUnhealthy = false;
  int _unhealthyPolls = 0;
  int _monitorGaps = 0;

  @override
  Stream<void> get activity => _controller.stream;

  @override
  Stream<void> get devicesLost => _devices.stream;

  @override
  bool get isMonitoring => _timer != null && _healthy;

  void _start() {
    _native.activityStart();
    _last = _native.activityCount();
    _lastDevicesLost = _native.activityDevicesLost();
    _healthy = _readHealth();
    _wasUnhealthy = false;
    _unhealthyPolls = 0;
    _timer ??= Timer.periodic(pollInterval, (_) => _tick());
  }

  void _tick() {
    final healthy = _readHealth();
    var local = false;
    if (!healthy) _wasUnhealthy = true;
    if (healthy && !_healthy && _wasUnhealthy) {
      // Back after a gap whose input went unseen.
      _monitorGaps++;
      local = true;
      _wasUnhealthy = false;
    }
    final c = _native.activityCount();
    if (c != _last) {
      _last = c;
      local = true;
    }
    final lost = _native.activityDevicesLost();
    final deviceLost = lost > _lastDevicesLost && _lastDevicesLost >= 0;
    _lastDevicesLost = lost;
    _healthy = healthy;
    if (healthy) {
      _unhealthyPolls = 0;
    } else if (pollInterval * ++_unhealthyPolls >= retryInterval) {
      _unhealthyPolls = 0;
      // Restarts the thread if it has exited.
      _native.activityStart();
    }
    if (local) _controller.add(null);
    if (deviceLost) _devices.add(null);
  }

  @override
  bool checkNow() {
    if (!isMonitoring) return false;
    var local = false;
    final c = _native.activityCount();
    if (c != _last) {
      _last = c;
      local = true;
    }
    final lost = _native.activityDevicesLost();
    if (lost > _lastDevicesLost && _lastDevicesLost >= 0) {
      _lastDevicesLost = lost;
      _devices.add(null);
      local = true;
    }
    return local;
  }

  bool _readHealth() {
    if (!_native.activityHealthy()) return false;
    // Without udev, a removed keyboard or mouse would go unseen.
    if (_native.activityDevicesLost() < 0) return false;
    final age = _native.activityHeartbeatAgeMs();
    return age >= 0 && age <= staleAfter.inMilliseconds;
  }

  @override
  LocalInputCounts get localInputCounts {
    int n(LinuxActivityReason r) => _native.activityReason(r);
    final counted = <LocalInputSource, int>{
      LocalInputSource.key: n(LinuxActivityReason.key),
      LocalInputSource.button: n(LinuxActivityReason.button),
      LocalInputSource.move: n(LinuxActivityReason.move),
      LocalInputSource.idleTime: n(LinuxActivityReason.idle),
      LocalInputSource.monitorGap: _monitorGaps,
    }..removeWhere((_, v) => v == 0);
    final details = <String, int>{'devicesLost': _native.activityDevicesLost()}
      ..removeWhere((_, v) => v <= 0);
    return LocalInputCounts(
      counted: Map.unmodifiable(counted),
      stalls: n(LinuxActivityReason.stall),
      longestGapMs: _native.activityLongestGapMs(),
      details: Map.unmodifiable(details),
    );
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _healthy = false;
    _native.activityStop();
  }
}
