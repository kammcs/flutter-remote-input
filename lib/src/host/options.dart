import 'host_types.dart';

/// Rate limits and bounds for a session (`docs/design.md` §6.4).
///
/// The defaults suit a person typing and pointing. An app may lower them,
/// but not raise them past the caps: the constructor throws an
/// [ArgumentError] for a value over its cap.
final class InputLimits {
  /// Creates limits. Every value must be positive and at most its cap.
  InputLimits({
    this.maxMessageBytes = 2048,
    this.textRate = 200,
    this.textBurst = 400,
    this.moveRate = 250,
    this.eventRate = 60,
    this.eventBurst = 120,
    this.maxWheelPixels = 1200,
    this.maxWheelLines = 10,
    this.maxHeldKeys = 8,
    this.maxQueuedEvents = 64,
  }) {
    _check('maxMessageBytes', maxMessageBytes, 4096);
    _check('textRate', textRate, 1000);
    _check('textBurst', textBurst, 2000);
    _check('moveRate', moveRate, 500);
    _check('eventRate', eventRate, 200);
    _check('eventBurst', eventBurst, 400);
    _check('maxWheelPixels', maxWheelPixels, 1200);
    _check('maxWheelLines', maxWheelLines, 10);
    _check('maxHeldKeys', maxHeldKeys, 16);
    _check('maxQueuedEvents', maxQueuedEvents, 256);
  }

  static void _check(String name, int value, int cap) {
    if (value < 1 || value > cap) {
      throw ArgumentError.value(value, name, 'must be between 1 and $cap');
    }
  }

  /// The largest message accepted, in bytes. Cap 4096.
  final int maxMessageBytes;

  /// Characters of text typed per second. Cap 1000.
  final int textRate;

  /// Characters of text typed in a burst. Cap 2000.
  final int textBurst;

  /// Pointer moves injected per second; the rest are coalesced. Cap 500.
  final int moveRate;

  /// Keys, buttons and wheel events per second. Cap 200.
  final int eventRate;

  /// Keys, buttons and wheel events in a burst. Cap 400.
  final int eventBurst;

  /// The largest wheel delta per message in pixels; larger ones are
  /// clamped. Cap 1200.
  final int maxWheelPixels;

  /// The largest wheel delta per message in lines; larger ones are clamped.
  /// Cap 10.
  final int maxWheelLines;

  /// Keys held down at once; more presses are dropped. Cap 16.
  final int maxHeldKeys;

  /// Reliable input waiting for the rate limits. Overflowing it stops the
  /// session with `StopReason.flooding`. Cap 256.
  final int maxQueuedEvents;
}

/// How a session comes back after local input paused it.
enum ResumePolicy {
  /// After `HostOptions.localIdle` without local input.
  automatic,

  /// When the app calls `ControlSession.resume`.
  manual,
}

/// How the viewer's shortcut modifiers map onto the host's.
enum ModifierMapping {
  /// When exactly one end is an Apple platform (macOS, iOS), swap Control
  /// and Command (Meta/Windows key), so copy, paste and undo work as each
  /// person expects. Alt and Option map to each other either way.
  auto,

  /// Keys arrive by position, unchanged.
  none,
}

/// A host app's filter for key presses: return `false` to drop [press].
///
/// Called for each key press after modifier mapping, never for releases.
typedef KeyFilter = bool Function(KeyPress press);

/// Options for a control session.
final class HostOptions {
  /// Creates options.
  const HostOptions({
    this.expiresAt,
    this.allowKeyboard = true,
    this.resumePolicy = ResumePolicy.automatic,
    this.localIdle = const Duration(milliseconds: 1500),
    this.heartbeatTimeout = const Duration(seconds: 5),
    this.modifierMapping = ModifierMapping.auto,
    this.keyFilter,
    this.limits,
  });

  /// When the session stops by itself, with `StopReason.expired`: a local
  /// backstop for the app's own grant. Must be in the future.
  final DateTime? expiresAt;

  /// Whether keys and text are injected. When false they're dropped, and
  /// only the pointer is controlled.
  final bool allowKeyboard;

  /// How the session resumes after local input pauses it.
  final ResumePolicy resumePolicy;

  /// How long without local input before an automatic resume.
  final Duration localIdle;

  /// How long without any message from the viewer, while keys or buttons
  /// are held, before the host releases them.
  final Duration heartbeatTimeout;

  /// How shortcut modifiers map between the two ends.
  final ModifierMapping modifierMapping;

  /// Drops key presses the app doesn't want (for example Win+R). The package
  /// blocks nothing by default.
  final KeyFilter? keyFilter;

  /// Rate limits and bounds; `null` for the defaults.
  final InputLimits? limits;
}
