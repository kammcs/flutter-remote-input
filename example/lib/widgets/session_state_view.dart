import 'package:flutter/material.dart';
import 'package:remote_input/remote_input.dart';

/// Whose point of view a state is described from.
enum Side {
  /// The presenter: the person whose computer is controlled.
  host,

  /// The person controlling.
  viewer,
}

/// A session state in words, for either side's UI.
String describeState(SessionState state, Side side) {
  final host = side == Side.host;
  return switch (state) {
    SessionWaiting() =>
      host ? 'Waiting for the viewer' : 'Waiting for the host',
    SessionActive() => host ? 'Being controlled' : 'You are in control',
    SessionPaused(:final reason) => switch (reason) {
      PauseReason.localInput =>
        host
            ? 'Paused while you use your mouse or keyboard'
            : 'Paused: the person at the host is using their computer',
      PauseReason.byHost => host ? 'Paused by you' : 'Paused by the host',
      PauseReason.other => 'Paused',
    },
    SessionBlocked(:final reason) => _blocked(reason, host),
    SessionStopped(:final reason) => _stopped(reason, host),
  };
}

String _blocked(BlockReason reason, bool host) {
  final who = host ? 'Can\'t control' : 'The host can\'t take input in';
  return switch (reason) {
    BlockReason.elevatedTarget => '$who an app run as administrator',
    BlockReason.secureDesktop =>
      '$who the lock screen or an administrator prompt',
    BlockReason.secureInput =>
      'Typing is blocked while a password field has focus',
    BlockReason.sessionInactive => '$who the login window or lock screen',
    BlockReason.surfaceHidden => 'The shared window is minimized',
    BlockReason.windowNotInFront =>
      'Typing is blocked while the shared window isn\'t in front',
    BlockReason.localInputUnmonitored =>
      host
          ? 'Paused: can\'t watch for your own mouse and keyboard'
          : 'Paused: the host can\'t watch for its own input',
    BlockReason.hostAppInFront =>
      'Typing is blocked while the host app itself is in front',
    BlockReason.other => 'Input is blocked for now',
  };
}

String _stopped(StopReason reason, bool host) => switch (reason) {
  StopReason.byHost =>
    host ? 'You stopped control' : 'The host stopped control',
  StopReason.stopAll => 'Control was stopped',
  StopReason.linkClosed => 'The connection closed',
  StopReason.expired => 'Control expired',
  StopReason.surfaceGone => 'The shared screen went away',
  StopReason.protocolViolation => 'Stopped: invalid messages from the viewer',
  StopReason.flooding => 'Stopped: too much input from the viewer',
  StopReason.viewerLeft => host ? 'The viewer left' : 'You left',
  StopReason.permissionDenied =>
    host
        ? 'Stopped: this app lost the Accessibility permission'
        : 'Stopped: the host lost its permission to control',
  StopReason.viewerClosed => host ? 'The viewer left' : 'You left',
  StopReason.unsupportedVersion =>
    'The two apps speak different protocol versions',
  StopReason.hostLeft => 'The host left',
  StopReason.timedOut => 'Lost contact with the host',
  StopReason.other => 'Control stopped',
};

/// A coloured chip with the session's state in words.
class SessionStateChip extends StatelessWidget {
  /// Creates a chip for [state], described from [side].
  const SessionStateChip({super.key, required this.state, required this.side});

  /// The state.
  final SessionState state;

  /// Whose point of view.
  final Side side;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, background, foreground) = switch (state) {
      SessionActive() => (
        Icons.mouse,
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      SessionPaused() => (
        Icons.pause_circle,
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      SessionBlocked() => (
        Icons.block,
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
      SessionStopped() => (
        Icons.stop_circle,
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      SessionWaiting() => (
        Icons.hourglass_top,
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
    };
    return Semantics(
      container: true,
      label: 'Session state',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: foreground),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  describeState(state, side),
                  style: TextStyle(color: foreground),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A short "development only, unencrypted" warning, for the WebSocket
/// screens.
class DevOnlyBanner extends StatelessWidget {
  /// Creates the banner.
  const DevOnlyBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.lock_open, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Development only: this link is unencrypted (plain ws://). '
                'Anyone on the network can read what is typed. Use it only '
                'on a network you trust; real apps use an encrypted '
                'transport such as WebRTC DataChannels.',
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A label and a value, for stats rows.
class StatLine extends StatelessWidget {
  /// Creates a stat line.
  const StatLine(this.label, this.value, {super.key});

  /// What is counted.
  final String label;

  /// The count, already formatted.
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
          Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// A round-trip time, for display: `12 ms`, or a dash before the first one.
String formatRtt(Duration? rtt) {
  if (rtt == null) return '–';
  final ms = rtt.inMicroseconds / 1000;
  return ms < 10 ? '${ms.toStringAsFixed(1)} ms' : '${ms.round()} ms';
}

/// The last minute of round-trip times, sampled once a second (the
/// viewer pings once a second), for a p50/p95 read-out. The package keeps
/// only the latest (`ViewerStats.roundTripTime`).
class RttWindow {
  /// Creates a window of [capacity] samples.
  RttWindow({this.capacity = 60});

  /// How many samples are kept.
  final int capacity;

  final List<Duration> _samples = [];

  /// Samples kept.
  int get count => _samples.length;

  /// Adds [rtt], if measured.
  void add(Duration? rtt) {
    if (rtt == null) return;
    _samples.add(rtt);
    if (_samples.length > capacity) _samples.removeAt(0);
  }

  /// The [p]th percentile (0–100), or `null` without samples.
  Duration? percentile(int p) {
    if (_samples.isEmpty) return null;
    final sorted = [..._samples]..sort();
    final i = ((p / 100) * (sorted.length - 1)).round();
    return sorted[i.clamp(0, sorted.length - 1)];
  }
}

/// A platform's name, for display.
String platformName(PeerPlatform? platform) => switch (platform) {
  PeerPlatform.windows => 'Windows',
  PeerPlatform.macos => 'macOS',
  PeerPlatform.linux => 'Linux',
  PeerPlatform.ios => 'iOS',
  PeerPlatform.android => 'Android',
  PeerPlatform.fuchsia => 'Fuchsia',
  PeerPlatform.unknown || null => 'unknown',
};
