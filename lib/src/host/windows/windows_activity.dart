import 'dart:async';

import '../platform.dart';
import 'win32_api.dart';

/// The Windows [LocalActivityMonitor] (`docs/design.md` §6.3).
///
/// The plugin's native code runs `WH_MOUSE_LL` and `WH_KEYBOARD_LL` hooks
/// on a thread of its own with a message loop, and counts every key, button
/// and wheel event that doesn't carry the package's tag (physical input,
/// and input injected by other software), every burst of untagged pointer
/// movement past 4 pixels of travel, measured apart from the package's own
/// moves, and every stall of the hook thread. This side polls the counter
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
/// injection rather than failing open. When the monitor recovers, it emits
/// once, since input during the gap went unseen. While it's down, starting
/// the hooks is retried every [retryInterval] (which restarts a hook thread
/// that has exited).
final class WindowsLocalActivity implements LocalActivityMonitor {
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

  Timer? _timer;
  Timer? _retry;
  int _last = 0;
  bool _healthy = false;
  int _unhealthyPolls = 0;

  @override
  Stream<void> get activity => _controller.stream;

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
    _healthy = _readHealth();
    _unhealthyPolls = 0;
    _timer ??= Timer.periodic(pollInterval, (_) => _tick());
  }

  void _tick() {
    final healthy = _readHealth();
    final c = _native.count();
    // Back after a gap whose input went unseen: count it as local input.
    var local = healthy && !_healthy;
    if (c != _last) {
      _last = c;
      local = true;
    }
    _healthy = healthy;
    if (healthy) {
      _unhealthyPolls = 0;
    } else if (pollInterval * ++_unhealthyPolls >= retryInterval) {
      _unhealthyPolls = 0;
      // Restarts the hook thread if it has exited; otherwise just reports.
      _native.start();
    }
    if (local) _controller.add(null);
  }

  bool _readHealth() {
    if (!_native.hooksInstalled()) return false;
    final age = _native.heartbeatAgeMs();
    return age >= 0 && age <= staleAfter.inMilliseconds;
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
