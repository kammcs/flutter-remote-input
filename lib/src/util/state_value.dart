import 'dart:async';

/// A value that changes over time, observable as a broadcast [stream] that
/// replays the current value to each new listener, then every change.
///
/// - [value] is readable synchronously, and updated before [set] returns.
/// - Events are delivered asynchronously, in order.
/// - After [close], new listeners get the last value, then done.
///
/// Internal: not exported.
final class StateValue<T> {
  /// Creates a holder that starts at [initial].
  StateValue(T initial) : _value = initial;

  final StreamController<T> _changes = StreamController<T>.broadcast(
    sync: true,
  );
  T _value;

  /// The current value.
  T get value => _value;

  /// Whether [close] has been called.
  bool get isClosed => _changes.isClosed;

  /// [value], then each change. Completes after [close].
  Stream<T> get stream => Stream<T>.multi((c) {
    c.add(_value);
    if (_changes.isClosed) {
      c.close();
      return;
    }
    final sub = _changes.stream.listen(c.add, onDone: c.close);
    c.onCancel = sub.cancel;
  }, isBroadcast: true);

  /// Sets the value and notifies listeners. Ignored after [close].
  void set(T value) {
    if (_changes.isClosed) return;
    _value = value;
    _changes.add(value);
  }

  /// Completes [stream] for every listener.
  void close() {
    if (!_changes.isClosed) _changes.close();
  }
}
