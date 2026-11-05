import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException;

import 'host/linux/linux_portal.dart';
import 'host/platform_default.dart' show linuxPermissionState;

/// Whether this app may inject input, as the OS sees it.
enum RemoteInputPermissionStatus {
  /// Granted: the host can inject (macOS: the app is allowed in System
  /// Settings > Privacy & Security > Accessibility; Wayland: a
  /// RemoteDesktop portal session is open).
  granted,

  /// Not granted. macOS doesn't say whether the person was never asked,
  /// declined, or later switched it off; in each case they turn it on in
  /// System Settings ([RemoteInputPermissions.openSettings]). On Wayland,
  /// no portal session is open: [RemoteInputPermissions.request] opens
  /// one.
  denied,

  /// No permission is needed (Windows, and Linux on X11).
  notRequired,

  /// This platform can't be a host (web, Android, iOS), or the plugin's
  /// native code isn't in this process.
  unsupported,
}

/// The OS permission a host needs to inject input (`docs/design.md` §7.3).
///
/// On macOS that's the **Accessibility** permission (the PostEvent
/// service). An app's onboarding screen typically shows [status], calls
/// [request] once, offers [openSettings], and follows [statusChanges] until
/// it's granted. A grant is tied to the app's code signature.
///
/// On Linux under Wayland it's an open **RemoteDesktop portal session**
/// ([RemoteInputPortal]): [request] opens one, which shows the system's
/// dialog every time, and it ends when the session closes.
///
/// Windows and X11 need no permission
/// ([RemoteInputPermissionStatus.notRequired]); every other platform is
/// [RemoteInputPermissionStatus.unsupported].
abstract final class RemoteInputPermissions {
  static const MethodChannel _channel = MethodChannel('remote_input');

  /// How often [statusChanges] checks while it has a listener.
  static const Duration pollInterval = Duration(seconds: 1);

  static bool get _isMacOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  static bool get _isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  static bool get _isLinux =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  static bool get _polls => _isMacOS || _isLinux;

  static RemoteInputPermissionStatus _linuxStatus() =>
      switch (linuxPermissionState()) {
        1 => RemoteInputPermissionStatus.notRequired,
        2 => RemoteInputPermissionStatus.granted,
        3 => RemoteInputPermissionStatus.denied,
        _ => RemoteInputPermissionStatus.unsupported,
      };

  /// The permission's status now. On macOS this asks the OS
  /// (`CGPreflightPostEventAccess`) off the UI thread.
  static Future<RemoteInputPermissionStatus> status() async {
    if (_isWindows) return RemoteInputPermissionStatus.notRequired;
    if (_isLinux) return _linuxStatus();
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
  ///
  /// On Wayland this opens a RemoteDesktop portal session for control only
  /// ([RemoteInputPortal.start]; to share and control with one dialog, call
  /// that with `screenCast` instead), and returns once the person has
  /// answered the system's dialog.
  static Future<RemoteInputPermissionStatus> request() async {
    if (_isWindows) return RemoteInputPermissionStatus.notRequired;
    if (_isLinux) {
      if (_linuxStatus() == RemoteInputPermissionStatus.denied) {
        await RemoteInputPortal.start();
      }
      return _linuxStatus();
    }
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
  /// and Linux while there's a listener. Elsewhere the status can't change, so the
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
        if (_polls) timer = Timer.periodic(pollInterval, (_) => check());
      },
      onPause: () => timer?.cancel(),
      onResume: () {
        check();
        if (_polls) timer = Timer.periodic(pollInterval, (_) => check());
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
