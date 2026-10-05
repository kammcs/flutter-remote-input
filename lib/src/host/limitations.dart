import '../protocol/wire_types.dart';

/// Something a host can't control, for apps to show in their UI
/// (`docs/design.md` §7.4). Localize by value; [description] is English.
enum HostLimitation {
  /// Windows: apps run as administrator, Task Manager and elevated
  /// installers (UIPI).
  elevatedApps('Apps run as administrator, such as Task Manager'),

  /// Windows: UAC prompts, the lock screen and the Ctrl+Alt+Del screen.
  secureDesktop('Administrator prompts, the lock screen and Ctrl+Alt+Del'),

  /// Windows: the Ctrl+Alt+Del key combination itself.
  ctrlAltDel('The Ctrl+Alt+Del key combination'),

  /// Windows: games that read raw input or use anti-cheat.
  someGames('Some games'),

  /// macOS: typing into password fields and other secure input. The
  /// pointer still works there.
  passwordFields('Typing into password fields'),

  /// macOS: the login window, the lock screen and fast user switching.
  lockScreen('The login window and the lock screen'),

  /// macOS: nothing at all until the app has the Accessibility permission.
  accessibilityPermission(
    'Anything, until this app is allowed in Accessibility settings',
  ),

  /// Web, iOS, Android and Linux can't be controlled at all.
  unsupportedPlatform('This device can be a viewer, but cannot be controlled');

  const HostLimitation(this.description);

  /// A short English description, for a list headed "Can't be controlled".
  final String description;

  /// What a host on [platform] can't control. Browsers report the OS they
  /// run on, so pass `isWeb` for them.
  static List<HostLimitation> forPlatform(
    PeerPlatform platform, {
    bool isWeb = false,
  }) {
    if (isWeb) return const [unsupportedPlatform];
    return switch (platform) {
      PeerPlatform.windows => const [
        elevatedApps,
        secureDesktop,
        ctrlAltDel,
        someGames,
      ],
      PeerPlatform.macos => const [
        accessibilityPermission,
        passwordFields,
        lockScreen,
      ],
      _ => const [unsupportedPlatform],
    };
  }
}
