import 'protocol/wire_types.dart';

/// A control session's state, on the host (`ControlSession.state`) and as
/// the viewer mirrors it (`RemoteInputViewer.state`).
///
/// The viewer's copy is informational: the host enforces it, and a viewer
/// must not present it as a security guarantee (`docs/design.md` §11).
sealed class SessionState {
  const SessionState();

  /// Whether input is injected in this state. True only for
  /// [SessionActive]. In [SessionBlocked] with
  /// [BlockReason.secureInput], the pointer still is.
  bool get isActive => false;

  /// Whether the session is over.
  bool get isStopped => false;
}

/// Waiting for the handshake: on the host, for the viewer's `Hello`; on the
/// viewer, for the host's `HostHello` and its first state.
final class SessionWaiting extends SessionState {
  /// Creates a [SessionWaiting].
  const SessionWaiting();

  @override
  bool operator ==(Object other) => other is SessionWaiting;

  @override
  int get hashCode => (SessionWaiting).hashCode;

  @override
  String toString() => 'SessionWaiting()';
}

/// Input is injected.
final class SessionActive extends SessionState {
  /// Creates a [SessionActive].
  const SessionActive();

  @override
  bool get isActive => true;

  @override
  bool operator ==(Object other) => other is SessionActive;

  @override
  int get hashCode => (SessionActive).hashCode;

  @override
  String toString() => 'SessionActive()';
}

/// Injection is suspended, and held keys and buttons were released. It
/// resumes by itself or when the host app says so.
final class SessionPaused extends SessionState {
  /// Creates a [SessionPaused].
  const SessionPaused(this.reason);

  /// Why.
  final PauseReason reason;

  @override
  bool operator ==(Object other) =>
      other is SessionPaused && other.reason == reason;

  @override
  int get hashCode => Object.hash(SessionPaused, reason);

  @override
  String toString() => 'SessionPaused(${reason.name})';
}

/// The OS can't or shouldn't take the input now. Input is dropped, never
/// queued, and the session resumes when the condition clears.
final class SessionBlocked extends SessionState {
  /// Creates a [SessionBlocked].
  const SessionBlocked(this.reason);

  /// Why.
  final BlockReason reason;

  @override
  bool operator ==(Object other) =>
      other is SessionBlocked && other.reason == reason;

  @override
  int get hashCode => Object.hash(SessionBlocked, reason);

  @override
  String toString() => 'SessionBlocked(${reason.name})';
}

/// The session is over. Control needs a new one.
final class SessionStopped extends SessionState {
  /// Creates a [SessionStopped].
  const SessionStopped(this.reason);

  /// Why.
  final StopReason reason;

  @override
  bool get isStopped => true;

  @override
  bool operator ==(Object other) =>
      other is SessionStopped && other.reason == reason;

  @override
  int get hashCode => Object.hash(SessionStopped, reason);

  @override
  String toString() => 'SessionStopped(${reason.name})';
}
