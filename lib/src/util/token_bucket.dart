import 'package:clock/clock.dart';

/// A token bucket: [rate] tokens a second, holding at most [burst].
///
/// Internal: not exported.
final class TokenBucket {
  /// Creates a full bucket.
  TokenBucket({required this.rate, required this.burst})
    : _tokens = burst.toDouble(),
      _lastMicros = _now();

  /// Tokens added per second.
  final double rate;

  /// The most tokens the bucket holds.
  final int burst;

  double _tokens;
  int _lastMicros;

  static int _now() => clock.now().microsecondsSinceEpoch;

  void _refill() {
    final now = _now();
    final elapsed = now - _lastMicros;
    _lastMicros = now;
    if (elapsed > 0) {
      _tokens = (_tokens + elapsed * rate / 1e6).clamp(0, burst.toDouble());
    }
  }

  /// The whole tokens available now.
  int get available {
    _refill();
    return _tokens.floor();
  }

  /// Takes [n] tokens if there are that many, and says whether it did.
  bool tryTake([int n = 1]) {
    _refill();
    if (_tokens < n) return false;
    _tokens -= n;
    return true;
  }

  /// How long until [n] tokens are available (zero if they are now).
  Duration timeUntil([int n = 1]) {
    _refill();
    final missing = n - _tokens;
    if (missing <= 0) return Duration.zero;
    return Duration(microseconds: (missing * 1e6 / rate).ceil());
  }
}
