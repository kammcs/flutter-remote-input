import '../protocol/wire_types.dart';

/// Something a host can't control, or a gap in what it can prevent, for
/// apps to show in their UI (`docs/design.md` §7.4). Localize by value;
/// [description] is English.
///
/// Most are things a viewer **can't control** ("Can't be controlled").
/// Those with [isGap] are the opposite: things the host's controls **don't
/// prevent**, which an app lists apart ("Not prevented").
enum HostLimitation {
  /// Windows: anything, while the host app runs as administrator, unless
  /// the app opts in (`HostOptions.allowElevatedHost`).
  elevatedHost('Anything, while this app runs as administrator'),

  /// Windows: apps run as administrator, Task Manager and elevated
  /// installers (UIPI).
  elevatedApps('Apps run as administrator, such as Task Manager'),

  /// Windows: UAC prompts, the lock screen and the Ctrl+Alt+Del screen.
  secureDesktop('Administrator prompts, the lock screen and Ctrl+Alt+Del'),

  /// Windows: the Ctrl+Alt+Del key combination itself.
  ctrlAltDel('The Ctrl+Alt+Del key combination'),

  /// Windows: games that read raw input or use anti-cheat.
  someGames('Some games'),

  /// Both: power, sleep, media, app-launch and browser keys, and Fn (the
  /// Globe key on a Mac), unless the app allows them
  /// (`HostOptions.allowSystemKeys`).
  systemKeys('Power, sleep, media and app-launch keys, and Fn'),

  /// macOS: typing into password fields and other secure input. The
  /// pointer still works there, and can type through an on-screen keyboard
  /// ([pointerTyping]).
  passwordFields('Typing into password fields'),

  /// macOS: the login window, the lock screen and fast user switching.
  lockScreen('The login window and the lock screen'),

  /// macOS: nothing at all until the app has the Accessibility permission.
  accessibilityPermission(
    'Anything, until this app is allowed in Accessibility settings',
  ),

  /// Web, iOS, Android and Linux can't be controlled at all.
  unsupportedPlatform('This device can be a viewer, but cannot be controlled'),

  /// Both, a gap ([isGap]): `HostOptions.allowKeyboard: false`, the
  /// macOS password-field block ([passwordFields]) and every `KeyFilter`
  /// cover keys sent as keys. With the pointer alone a viewer can still
  /// type, and use shortcuts, through an on-screen keyboard (the macOS
  /// Accessibility Keyboard and Character Viewer; the Windows touch
  /// keyboard and `osk.exe`), and paste from an Edit or context menu
  /// (`docs/design.md` §6.5, RIN-49).
  pointerTyping(
    'Typing and pasting with the pointer, through an on-screen keyboard '
    'or a menu, even with keys turned off',
    isGap: true,
  );

  const HostLimitation(this.description, {this.isGap = false});

  /// A short English description: for a list headed "Can't be
  /// controlled", or for one headed "Not prevented" when [isGap].
  final String description;

  /// Whether this is a gap in what the host prevents, rather than
  /// something a viewer can't control: list it apart from the others.
  final bool isGap;

  /// What a host on [platform] can't control. Browsers report the OS they
  /// run on, so pass `isWeb` for them.
  static List<HostLimitation> forPlatform(
    PeerPlatform platform, {
    bool isWeb = false,
  }) {
    if (isWeb) return const [unsupportedPlatform];
    return switch (platform) {
      PeerPlatform.windows => const [
        elevatedHost,
        elevatedApps,
        secureDesktop,
        ctrlAltDel,
        someGames,
        systemKeys,
        pointerTyping,
      ],
      PeerPlatform.macos => const [
        accessibilityPermission,
        passwordFields,
        lockScreen,
        systemKeys,
        pointerTyping,
      ],
      _ => const [unsupportedPlatform],
    };
  }
}
