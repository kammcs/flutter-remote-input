import 'dart:async';

import '../host_types.dart';
import '../platform.dart';
import 'win32_api.dart';

/// The Windows [LocalActivityMonitor] (`docs/design.md` §6.3).
///
/// The plugin's native code runs `WH_MOUSE_LL` and `WH_KEYBOARD_LL` hooks
/// on a thread of its own with a message loop, and counts physical input
/// only: every key, button and wheel event Windows doesn't flag as
/// injected (by any process, with any tag), every burst of physical pointer
/// movement past 4 pixels of travel, measured apart from injected moves,
/// and every stall of the hook thread that hid input from the hooks (a
/// stall alone doesn't count). Both rules are from RIN-39. This side polls the counter
/// every [pollInterval] while [activity] has a listener, and emits when it
/// changes, so a session pauses within about one poll of the first local
/// event (the target is 50 ms).
///
/// **Health.** Windows silently removes a low-level hook whose thread
/// doesn't answer in time. The hook thread re-installs its hooks every 15 s
/// and after a stall, and beats a heartbeat every 100 ms. Each poll also
/// reads whether the hooks are installed and how old the heartbeat is:
/// [isMonitoring] is true only while they're installed and the heartbeat is
/// at most [staleAfter] old, so a stuck or dead hook thread blocks
/// injection rather than failing open. When the monitor recovers from its
/// hooks being out (not installed, or the thread not running), it emits
/// once, since input during the gap went unseen. A heartbeat that was only
/// late isn't such a gap: the hooks were still in, and the native side
/// counts the stall if it hid input. While it's down, starting
/// the hooks is retried every [retryInterval] (which restarts a hook thread
/// that has exited).
///
/// **Lost devices (RIN-41).** The hook thread also counts keyboards and
/// mice that leave the raw input device list (Bluetooth turned off, a
/// receiver unplugged), read on every heartbeat. Each poll that sees the
/// count grow emits on [devicesLost], and the session stops.
///
/// **Checked before each event (RIN-42).** [checkNow] reads the same two
/// counters as a poll, with two leaf FFI calls that load atomics, so the
/// session can ask before every injected event.
final class WindowsLocalActivity
    implements
        LocalActivityMonitor,
        LocalDeviceMonitor,
        LocalActivityCheck,
        LocalInputDiagnostics {
  /// Creates a monitor on [native].
  WindowsLocalActivity(
    this._native, {
    this.pollInterval = const Duration(milliseconds: 10),
    this.retryInterval = const Duration(seconds: 1),
    this.staleAfter = const Duration(milliseconds: 400),
  });

  final NativeActivity _native;

  /// How often the counter and the hooks' health are read.
  final Duration pollInterval;

  /// How often starting the hooks is retried while they're down.
  final Duration retryInterval;

  /// How old the hook thread's heartbeat (every 100 ms) may be before the
  /// thread counts as stuck.
  final Duration staleAfter;

  late final StreamController<void> _controller = StreamController.broadcast(
    onListen: _start,
    onCancel: _stop,
  );
  final StreamController<void> _devices = StreamController.broadcast();

  Timer? _timer;
  Timer? _retry;
  int _last = 0;
  int _lastDevicesLost = 0;
  bool _healthy = false;
  int _unhealthyPolls = 0;
  // Whether the hooks were out at some point since the monitor was last
  // healthy, so input may have gone unseen.
  bool _hooksWereOut = false;
  int _monitorGaps = 0;

  @override
  Stream<void> get activity => _controller.stream;

  /// Each poll that sees keyboards or mice removed since the last one
  /// (RIN-41). Watched while [activity] has a listener.
  @override
  Stream<void> get devicesLost => _devices.stream;

  /// Whether the native hooks are being polled, are installed, and their
  /// thread's heartbeat is fresh. As of the last poll, so reading it costs
  /// nothing.
  @override
  bool get isMonitoring => _timer != null && _healthy;

  void _start() {
    if (!_native.start()) {
      // Nothing is lost by retrying: until the hooks are in, there is no
      // count to miss.
      _retry ??= Timer.periodic(retryInterval, (_) {
        if (_controller.hasListener && _native.start()) {
          _retry?.cancel();
          _retry = null;
          _poll();
        }
      });
      return;
    }
    _poll();
  }

  void _poll() {
    _last = _native.count();
    _lastDevicesLost = _native.devicesLost();
    _healthy = _readHealth();
    _hooksWereOut = false;
    _unhealthyPolls = 0;
    _timer ??= Timer.periodic(pollInterval, (_) => _tick());
  }

  void _tick() {
    final healthy = _readHealth();
    final c = _native.count();
    // A heartbeat that's only late, with the hooks in, isn't a gap: the
    // native side judges the stall when its thread runs again.
    if (!healthy && _hooksOut()) _hooksWereOut = true;
    // Back after a gap whose input went unseen: count it as local input.
    var local = false;
    if (healthy && !_healthy && _hooksWereOut) {
      _monitorGaps++;
      local = true;
    }
    if (healthy) _hooksWereOut = false;
    if (c != _last) {
      _last = c;
      local = true;
    }
    final lost = _native.devicesLost();
    final deviceLost = lost != _lastDevicesLost;
    _lastDevicesLost = lost;
    _healthy = healthy;
    if (healthy) {
      _unhealthyPolls = 0;
    } else if (pollInterval * ++_unhealthyPolls >= retryInterval) {
      _unhealthyPolls = 0;
      // Restarts the hook thread if it has exited; otherwise just reports.
      _native.start();
    }
    if (local) _controller.add(null);
    if (deviceLost) _devices.add(null);
  }

  /// Reads the counters now (RIN-42): local input or a removed device since
  /// the last read counts, and is consumed. Health is left to the poll.
  @override
  bool checkNow() {
    if (!isMonitoring) return false;
    var local = false;
    final c = _native.count();
    if (c != _last) {
      _last = c;
      local = true;
    }
    final lost = _native.devicesLost();
    if (lost != _lastDevicesLost) {
      _lastDevicesLost = lost;
      _devices.add(null);
      local = true;
    }
    return local;
  }

  /// Whether the hooks are out: not installed, or no hook thread. A stale
  /// heartbeat with the hooks in isn't this.
  bool _hooksOut() => !_native.hooksInstalled() || _native.heartbeatAgeMs() < 0;

  bool _readHealth() {
    if (!_native.hooksInstalled()) return false;
    final age = _native.heartbeatAgeMs();
    return age >= 0 && age <= staleAfter.inMilliseconds;
  }

  @override
  LocalInputCounts get localInputCounts {
    int n(NativeActivityReason r) => _native.reasonCount(r);
    final counted = <LocalInputSource, int>{
      LocalInputSource.key: n(NativeActivityReason.key),
      LocalInputSource.button: n(NativeActivityReason.button),
      LocalInputSource.move: n(NativeActivityReason.move),
      LocalInputSource.missed: n(NativeActivityReason.missed),
      LocalInputSource.monitorGap: _monitorGaps,
    }..removeWhere((_, v) => v == 0);
    const tags = ['noTag', 'ours', 'otherProcess', 'otherTag'];
    final details = <String, int>{
      for (var i = 0; i < 8; i++)
        '${i < 4 ? 'physical' : 'injected'}Move.${tags[i % 4]}': _native
            .moveOriginCount(i),
      'largestPhysicalStepPx': _native.largestPhysicalStepPx(),
      'devicesLost': _native.devicesLost(),
      'inputDevices': _native.inputDevices(),
    }..removeWhere((_, v) => v <= 0);
    return LocalInputCounts(
      counted: Map.unmodifiable(counted),
      stalls: n(NativeActivityReason.stall),
      longestGapMs: _native.longestGapMs(),
      details: Map.unmodifiable(details),
    );
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _retry?.cancel();
    _retry = null;
    _healthy = false;
    _native.stop();
  }
}
