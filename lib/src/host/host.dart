import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

import '../link.dart';
import '../protocol/wire_types.dart';
import '../surface.dart';
import 'limitations.dart';
import 'options.dart';
import 'platform.dart';
import 'platform_default.dart';
import 'session.dart';

/// The presenter's side: replays a viewer's input on this machine.
///
/// **Off by default.** Nothing is injected until the app calls [enable],
/// and then only for that session's link and surface
/// (`docs/design.md` §6.1).
///
/// ```dart
/// if (!RemoteInputHost.isSupported) return; // web, phones, Linux
/// final host = RemoteInputHost();
/// final session = host.enable(
///   link: link, // the app's InputLink to the granted viewer
///   surface: SharedSurface.display(displays.first.id),
/// );
/// // ...
/// session.stop(); // synchronous
/// ```
final class RemoteInputHost {
  /// Creates a host on this platform, or on [platform] (a fake in tests).
  ///
  /// Throws a [HostUnavailableException] with
  /// [HostUnavailableReason.unsupportedPlatform] when [platform] is omitted
  /// on a platform without an injector ([isSupported] is false).
  RemoteInputHost({HostPlatform? platform})
    : _platform =
          platform ??
          defaultHostPlatform() ??
          (throw const HostUnavailableException(
            HostUnavailableReason.unsupportedPlatform,
          ));

  final HostPlatform _platform;

  static ControlSession? _live;

  /// Whether this platform can inject input (Windows and macOS, once their
  /// injectors land: roadmap M2 and M3).
  static bool get isSupported => defaultHostPlatform() != null;

  /// What a host on this device can't control, for the app's UI
  /// (`docs/design.md` §7.4).
  static List<HostLimitation> get limitations =>
      HostLimitation.forPlatform(switch (defaultTargetPlatform) {
        TargetPlatform.windows => PeerPlatform.windows,
        TargetPlatform.macOS => PeerPlatform.macos,
        _ => PeerPlatform.unknown,
      }, isWeb: kIsWeb);

  /// The live session in this process, if any.
  static ControlSession? get activeSession => _live;

  /// Stops every session in this process, with [StopReason.stopAll]
  /// (`docs/design.md` §6.2). For the app's global revoke hotkey, tray menu
  /// or crash handler. Synchronous, like [ControlSession.stop].
  static void stopAll() => stopSessionForAll(_live);

  /// Why this host can't inject now, or `null` if it can: what [enable]
  /// would throw with the same [options].
  ///
  /// Without [options] (or with `allowElevatedHost` false), an elevated
  /// Windows host reports [HostUnavailableReason.elevatedHost]. An app that
  /// opts in passes the options it will enable with, and can call this
  /// once without them to learn that the host is elevated, for a warning
  /// in its UI: [HostUnavailableReason.elevatedHost] is reported only when
  /// nothing else stops the host.
  HostUnavailableReason? checkAvailable({
    HostOptions options = const HostOptions(),
  }) => _platform.checkAvailable(allowElevatedHost: options.allowElevatedHost);

  /// The host's displays, for [SharedSurface.display].
  Future<List<DisplayInfo>> displays() => _platform.surfaces.displays();

  /// Starts a control session for the viewer at the other end of [link],
  /// confined to [surface].
  ///
  /// The session sends its `HostHello` once [link]'s reliable channel is
  /// open, and injects nothing until the viewer completes the handshake.
  ///
  /// Throws:
  /// - a [StateError] if a session is already live in this process (one at
  ///   a time in v1);
  /// - a [HostUnavailableException] if the host can't inject now
  ///   ([checkAvailable] with [options]), including
  ///   [HostUnavailableReason.elevatedHost] for a Windows host run as
  ///   administrator, unless [HostOptions.allowElevatedHost];
  /// - an [ArgumentError] if [surface] can't be found or has a negative
  ///   `contentInsets` value, or [HostOptions.expiresAt] has passed.
  ControlSession enable({
    required InputLink link,
    required SharedSurface surface,
    HostOptions options = const HostOptions(),
  }) {
    if (_live != null) {
      throw StateError('A control session is already live in this process');
    }
    final unavailable = checkAvailable(options: options);
    if (unavailable != null) throw HostUnavailableException(unavailable);
    final session = createControlSession(
      platform: _platform,
      link: link,
      surface: surface,
      options: options,
      onStopped: (s) {
        if (identical(_live, s)) _live = null;
      },
    );
    if (!session.state.isStopped) _live = session;
    return session;
  }
}
