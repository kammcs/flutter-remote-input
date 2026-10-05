import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException;

/// Whether this app may inject input, as the OS sees it.
enum RemoteInputPermissionStatus {
  /// Granted: the host can inject (macOS: the app is allowed in System
  /// Settings > Privacy & Security > Accessibility).
  granted,

  /// Not granted (macOS). macOS doesn't say whether the person was never
  /// asked, declined, or later switched it off; in each case they turn it
  /// on in System Settings ([RemoteInputPermissions.openSettings]).
  denied,

  /// No permission is needed (Windows).
  notRequired,

  /// This platform can't be a host (web, Linux, Android, iOS), or the
  /// plugin's native code isn't in this process.
  unsupported,
}

/// The OS permission a host needs to inject input (`docs/design.md` §7.3).
///
/// On macOS that's the **Accessibility** permission (the PostEvent
/// service). An app's onboarding screen typically shows [status], calls
/// [request] once, offers [openSettings], and follows [statusChanges] until
/// it's granted. A grant is tied to the app's code signature.
///
/// Windows needs no permission ([RemoteInputPermissionStatus.notRequired]);
/// every other platform is [RemoteInputPermissionStatus.unsupported].
abstract final class RemoteInputPermissions {
  static const MethodChannel _channel = MethodChannel('remote_input');

  /// How often [statusChanges] checks while it has a listener.
  static const Duration pollInterval = Duration(seconds: 1);

  static bool get _isMacOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  static bool get _isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// The permission's status now. On macOS this asks the OS
  /// (`CGPreflightPostEventAccess`) off the UI thread.
  static Future<RemoteInputPermissionStatus> status() async {
    if (_isWindows) return RemoteInputPermissionStatus.notRequired;
    if (!_isMacOS) return RemoteInputPermissionStatus.unsupported;
    return _invokeStatus('postEventAccess');
  }

  /// Asks for the permission and returns the status now.
  ///
  /// On macOS this calls `CGRequestPostEventAccess()`, which shows the
  /// system's prompt the first time an app asks; after that it shows
  /// nothing, and the person grants it in System Settings ([openSettings]).
  /// The grant is asynchronous: this usually returns
  /// [RemoteInputPermissionStatus.denied], and [statusChanges] reports the
  /// grant when it happens.
  static Future<RemoteInputPermissionStatus> request() async {
    if (_isWindows) return RemoteInputPermissionStatus.notRequired;
    if (!_isMacOS) return RemoteInputPermissionStatus.unsupported;
    return _invokeStatus('requestPostEventAccess');
  }

  /// Opens the settings page where the permission is granted: on macOS,
  /// System Settings > Privacy & Security > Accessibility. Returns whether
  /// it opened; false where there's no such page.
  static Future<bool> openSettings() async {
    if (!_isMacOS) return false;
    try {
      return await _channel.invokeMethod<bool>('openAccessibilitySettings') ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  /// The status, then each change: checked every [pollInterval] on macOS
  /// while there's a listener. Elsewhere the status can't change, so the
  /// stream emits it once and stays open.
  static Stream<RemoteInputPermissionStatus> get statusChanges {
    late final StreamController<RemoteInputPermissionStatus> controller;
    Timer? timer;
    RemoteInputPermissionStatus? last;
    var checking = false;

    Future<void> check() async {
      if (checking) return;
      checking = true;
      try {
        final s = await status();
        if (!controller.isClosed && s != last) {
          last = s;
          controller.add(s);
        }
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      } finally {
        checking = false;
      }
    }

    controller = StreamController<RemoteInputPermissionStatus>(
      onListen: () {
        check();
        if (_isMacOS) timer = Timer.periodic(pollInterval, (_) => check());
      },
      onPause: () => timer?.cancel(),
      onResume: () {
        check();
        if (_isMacOS) timer = Timer.periodic(pollInterval, (_) => check());
      },
      onCancel: () => timer?.cancel(),
    );
    return controller.stream;
  }

  static Future<RemoteInputPermissionStatus> _invokeStatus(
    String method,
  ) async {
    try {
      final granted = await _channel.invokeMethod<bool>(method);
      return granted == true
          ? RemoteInputPermissionStatus.granted
          : RemoteInputPermissionStatus.denied;
    } on MissingPluginException {
      return RemoteInputPermissionStatus.unsupported;
    }
  }
}
