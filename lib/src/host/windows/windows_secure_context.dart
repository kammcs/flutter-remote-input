import 'dart:ui' show Offset;

import 'package:clock/clock.dart';

import '../../protocol/wire_types.dart';
import '../platform.dart';
import 'input_records.dart' show desktopPixel;
import 'win32_api.dart';

/// The Windows [SecureContextProbe] (`docs/design.md` §6.5).
///
/// - **Secure desktop:** the input desktop isn't `Default`
///   ([Win32Api.isInputDesktopDefault]): UAC prompts, Ctrl+Alt+Del, the
///   lock screen. Checked for every event; it's three cheap calls.
/// - **Elevated target (UIPI):** the process of the foreground window (for
///   keys) or of the window under the point (for the pointer) has a higher
///   integrity level than this one. A process whose token can't be queried
///   counts as elevated: a normal process can't read an elevated one's
///   token, which is the case the check exists for. This process's own
///   windows never block.
///
/// Each process's answer is kept for [cacheFor], so a pointer moving over
/// one window queries its token once rather than 250 times a second. A
/// process can't raise its own integrity level, so the cache can only be
/// wrong for a process id reused within that time.
final class WindowsSecureContextProbe implements SecureContextProbe {
  /// Creates a probe on [api].
  WindowsSecureContextProbe(
    this._api, {
    this.cacheFor = const Duration(seconds: 2),
  });

  final Win32Api _api;

  /// How long a process's answer is kept.
  final Duration cacheFor;

  final Map<int, ({DateTime at, bool elevated})> _cache = {};
  int? _own;

  /// The most processes kept in the cache before it's cleared.
  static const int _maxCached = 64;

  @override
  BlockReason? check(InputKind kind, {Offset? point}) {
    if (!_api.isInputDesktopDefault()) return BlockReason.secureDesktop;
    final hwnd = switch (kind) {
      InputKind.keyboard => _api.foregroundWindow(),
      InputKind.pointer when point != null => _api.windowFromPoint(
        desktopPixel(point.dx),
        desktopPixel(point.dy),
      ),
      InputKind.pointer => 0,
    };
    if (hwnd == 0) return null;
    final pid = _api.processIdOfWindow(hwnd);
    if (pid == 0 || pid == _api.currentProcessId) return null;
    return _isElevated(pid) ? BlockReason.elevatedTarget : null;
  }

  bool _isElevated(int pid) {
    final now = clock.now();
    final cached = _cache[pid];
    if (cached != null && now.difference(cached.at) < cacheFor) {
      return cached.elevated;
    }
    final own = _own ??= _api.ownIntegrityLevel ?? IntegrityLevel.medium;
    final level = _api.integrityLevel(pid);
    final elevated = level == null || level > own;
    if (_cache.length >= _maxCached) _cache.clear();
    _cache[pid] = (at: now, elevated: elevated);
    return elevated;
  }
}
