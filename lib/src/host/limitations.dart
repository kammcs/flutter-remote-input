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

  /// Every host: power, sleep, media, app-launch and browser keys, and Fn
  /// (the Globe key on a Mac), unless the app allows them
  /// (`HostOptions.allowSystemKeys`).
  systemKeys('Power, sleep, media and app-launch keys, and Fn'),

  /// macOS: typing into password fields and other secure input. The
  /// pointer still works there, and can type through an on-screen keyboard
  /// ([pointerTyping]).
  passwordFields('Typing into password fields'),

  /// macOS and Linux: the login window, the lock screen and fast user
  /// switching.
  lockScreen('The login window and the lock screen'),

  /// macOS: nothing at all until the app has the Accessibility permission.
  accessibilityPermission(
    'Anything, until this app is allowed in Accessibility settings',
  ),

  /// Web, iOS and Android can't be controlled at all, nor Linux without an
  /// X11 or Wayland session.
  unsupportedPlatform('This device can be a viewer, but cannot be controlled'),

  /// Every host, a gap ([isGap]): `HostOptions.allowKeyboard: false`, the
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
  ),

  /// Linux: anything, while the host app runs as root, unless the app opts
  /// in (`HostOptions.allowElevatedHost`).
  rootHost('Anything, while this app runs as root'),

  /// Linux, a gap ([isGap]): administrator password prompts (polkit) aren't
  /// detected, so a viewer can operate them: cancel, confirm, or type into
  /// them. The password itself still has to be known.
  adminPrompts('Administrator password prompts', isGap: true),

  /// Wayland: nothing at all until the presenter allows remote interaction
  /// in the system's dialog, which asks for every portal session.
  portalConsent(
    "Anything, until it's allowed in the system's Remote Desktop dialog",
  ),

  /// Wayland: text the presenter's keyboard layout can't type (another
  /// script, emoji). libei types with the compositor's keymap and can't
  /// change it.
  layoutText("Text the keyboard layout can't type, such as emoji"),

  /// Wayland, a gap ([isGap]): no app can see other input, so the
  /// presenter's own input is seen only through the desktop's idle time,
  /// which the package's input resets too. While the viewer's input is
  /// continuous (a long drag, fast typing), the presenter's mouse and
  /// keyboard don't pause the session until the viewer's next pause of
  /// about 40 ms.
  waylandLocalInput(
    "Taking over with this computer's own mouse and keyboard while the "
    "viewer's input is continuous",
    isGap: true,
  ),

  /// Wayland, a gap ([isGap]): no app is told where its windows are, so
  /// the host app's own windows are protected from the pointer only while
  /// GTK says the pointer is over one of them, which can lag a few
  /// milliseconds behind a move. Keys are blocked while the app has focus.
  waylandHostWindows(
    "Clicks on this app's own windows just after the pointer moves onto "
    'them',
    isGap: true,
  ),

  /// Wayland, a gap ([isGap]): on a window share, other windows over the
  /// shared one aren't detected, and keys go to whichever window has
  /// focus.
  waylandWindowShares(
    'On a window share, windows over the shared one, and keys typed '
    'while another window has focus',
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
    bool linuxWayland = false,
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
      PeerPlatform.linux when linuxWayland => const [
        portalConsent,
        rootHost,
        lockScreen,
        systemKeys,
        layoutText,
        pointerTyping,
        adminPrompts,
        waylandLocalInput,
        waylandHostWindows,
        waylandWindowShares,
      ],
      PeerPlatform.linux => const [
        rootHost,
        lockScreen,
        systemKeys,
        pointerTyping,
        adminPrompts,
      ],
      _ => const [unsupportedPlatform],
    };
  }
}
