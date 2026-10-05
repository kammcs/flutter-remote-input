import 'dart:async';

import '../platform.dart';
import 'win32_api.dart';

/// The Windows [LocalActivityMonitor] (`docs/design.md` §6.3).
///
/// The plugin's native code runs `WH_MOUSE_LL` and `WH_KEYBOARD_LL` hooks
/// on a thread of its own with a message loop, and counts every key, button
/// and wheel event, and every pointer movement past 4 pixels from the last
/// reference point, that doesn't carry the package's tag: physical input,
/// and input injected by other software. This side polls the counter every
/// [pollInterval] while [activity] has a listener, and emits when it
/// changes, so a session pauses within about one poll of the first local
/// event (the target is 50 ms).
final class WindowsLocalActivity implements LocalActivityMonitor {
  /// Creates a monitor on [native].
  WindowsLocalActivity(
    this._native, {
    this.pollInterval = const Duration(milliseconds: 10),
    this.retryInterval = const Duration(seconds: 1),
  });

  final NativeActivity _native;

  /// How often the counter is read.
  final Duration pollInterval;

  /// How often starting the hooks is retried if it failed.
  final Duration retryInterval;

  late final StreamController<void> _controller = StreamController.broadcast(
    onListen: _start,
    onCancel: _stop,
  );

  Timer? _timer;
  Timer? _retry;
  int _last = 0;

  @override
  Stream<void> get activity => _controller.stream;

  /// Whether the native hooks are being polled.
  bool get isMonitoring => _timer != null;

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
    _timer ??= Timer.periodic(pollInterval, (_) {
      final c = _native.count();
      if (c == _last) return;
      _last = c;
      _controller.add(null);
    });
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _retry?.cancel();
    _retry = null;
    _native.stop();
  }
}
