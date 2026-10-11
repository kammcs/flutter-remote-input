import '../keys.dart' show HidModifier;
import '../protocol/wire_types.dart' show KeyModifiers, PeerPlatform;
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
/// Called for each key press and repeat after modifier mapping, never for
/// releases. A press that's dropped is never injected, so its release has
/// nothing to release. When a modifier is pressed, the keys already held
/// are filtered again with it, and those it rejects are released. To
/// combine filters, call them in one: `(p) => KeyFilters.windowShare(p) &&
/// myFilter(p)`.
///
/// [KeyFilters] has a preset for window shares.
typedef KeyFilter = bool Function(KeyPress press);

/// The package's ready-made [KeyFilter]s, and the rule behind
/// [HostOptions.allowSystemKeys] (`docs/design.md` §6.4).
abstract final class KeyFilters {
  /// Whether [usage] is a **system key**, which a session drops unless
  /// [HostOptions.allowSystemKeys] is true:
  ///
  /// - every usage on HID page 0x01, generic desktop: System Sleep, Wake
  ///   Up, Power Down;
  /// - every usage on page 0x0C, consumer: media keys, Eject, LaunchApp1
  ///   and 2 ("This PC" and the calculator on Windows), LaunchMail, the
  ///   Browser keys;
  /// - Power on the keyboard page (`0x70066`);
  /// - every usage on page 0x00, the page Flutter uses for keys HID has no
  ///   usage for: **Fn** (`0x12`), FnLock, Suspend, Resume and others. Fn
  ///   is the Globe key on a Mac: alone it switches the input source,
  ///   opens the emoji picker or starts dictation, and with a letter it
  ///   opens the Dock, Notification Center, Control Center or Quick Note,
  ///   all outside the shared window. Nothing is lost by dropping it: a
  ///   Mac keyboard turns Fn with an arrow, Delete or an F-key into that
  ///   key (Home, Forward Delete, F1) before the viewer sends it, and
  ///   Windows has no scan code for Fn.
  ///
  /// These act on the whole machine, whatever window has focus: they can
  /// put it to sleep or launch apps.
  static bool isSystemKey(int usage) {
    final page = usage >> 16;
    return page == 0x00 || page == 0x01 || page == 0x0C || usage == _power;
  }

  /// A preset for window shares (`SharedSurface.window`): drops the
  /// shortcuts that act outside the shared window, which the keyboard
  /// confinement of window surfaces can't stop, because the OS acts on
  /// the shortcut itself before any window sees it. **Not on by default:**
  /// host apps should pass it for window shares,
  /// `HostOptions(keyFilter: KeyFilters.windowShare)`.
  ///
  /// It follows the host's OS ([KeyPress.hostPlatform]), because it sees
  /// keys after modifier mapping, and the shortcut modifier differs: on a
  /// Mac host, Command is what copy and paste use (a Windows viewer's
  /// Ctrl+C arrives as Cmd+C), so Command can't be dropped there as the
  /// Windows key is on a Windows host.
  ///
  /// **On a Windows host** it drops:
  /// - the Windows key itself, and any other key pressed while it's held
  ///   (by the host or by the viewer; other modifiers aside): Win+R, Win+L,
  ///   Win+A, Win+H, Win+D, Win+Tab, Win+1…9 and the rest;
  /// - Escape with Control held: Ctrl+Shift+Esc (Task Manager), Ctrl+Esc
  ///   (Start);
  /// - Tab or Escape with Alt held: Alt+Tab, Alt+Shift+Tab, Ctrl+Alt+Tab,
  ///   Alt+Esc (window switching).
  ///
  /// **On a Mac host** it drops, with Command held:
  /// - Tab: Cmd+Tab and Cmd+Shift+Tab (the app switcher);
  /// - Space: Cmd+Space (Spotlight), Cmd+Option+Space (Finder search),
  ///   Ctrl+Cmd+Space (the character viewer);
  /// - Escape: Cmd+Option+Esc (Force Quit Applications);
  /// - Q with Control or Shift: Ctrl+Cmd+Q (lock), Cmd+Shift+Q and
  ///   Cmd+Option+Shift+Q (log out);
  /// - F1–F12: Cmd+F5 (VoiceOver) and Cmd+Option+F5 (accessibility
  ///   shortcuts);
  ///
  /// and with Control held:
  /// - F1–F12: keyboard focus to the menu bar, the Dock or the status menus
  ///   (Ctrl+F2, F3, F8);
  /// - the arrow keys without Alt or Command: Mission Control, App Exposé,
  ///   and moving between Spaces.
  ///
  /// Plain Cmd+Q, Cmd+W, Cmd+H and Cmd+M still work: they act on the
  /// shared app, as Alt+F4 does on Windows.
  ///
  /// **Where the host's OS is unknown**, both lists apply. System keys
  /// ([isSystemKey]) are dropped too, even with
  /// [HostOptions.allowSystemKeys].
  ///
  /// Ordinary typing and shortcuts (Ctrl+C, V, X, Z and A on Windows,
  /// Cmd+C and the others on a Mac, Shift and Alt characters, Enter, Tab,
  /// Escape and the arrows) pass. Repeats of a dropped combination are
  /// dropped too.
  ///
  /// **What it doesn't stop:** shortcuts an app or the user has added
  /// (Alfred, Raycast, custom global hotkeys); F-keys the OS assigns
  /// without a modifier (Show Desktop and Mission Control on some Macs);
  /// screenshots (PrtScn, Cmd+Shift+3, 4 and 5); and anything typed into a
  /// window that isn't the shared one, which window surfaces block anyway
  /// while it's in front (`BlockReason.windowNotInFront`).
  static bool windowShare(KeyPress press) {
    final usage = press.usage;
    if (isSystemKey(usage)) return false;
    var mods = press.modifiers;
    for (final m in press.heldModifiers) {
      mods |= HidModifier.bitOf(m);
    }
    bool has(int bit) => mods & bit != 0;
    final control = has(KeyModifiers.control);
    final alt = has(KeyModifiers.alt);
    final meta = has(KeyModifiers.meta);
    final host = press.hostPlatform;
    if (host != PeerPlatform.macos) {
      if (usage == HidModifier.metaLeft || usage == HidModifier.metaRight) {
        return false;
      }
      // Other modifiers pass: alone they're no shortcut, and dropping
      // Shift would leave the viewer's next letters in the wrong case.
      if (meta && !HidModifier.isModifier(usage)) return false;
      if (usage == _escape && (control || alt)) return false;
      if (usage == _tab && alt) return false;
    }
    if (host != PeerPlatform.windows) {
      final fKey = usage >= _f1 && usage <= _f12;
      if (meta) {
        if (usage == _tab || usage == _space || usage == _escape) return false;
        if (usage == _keyQ && (control || has(KeyModifiers.shift))) {
          return false;
        }
        if (fKey) return false;
      }
      if (control) {
        if (fKey) return false;
        if (usage >= _right && usage <= _up && !alt && !meta) return false;
      }
    }
    return true;
  }

  static const int _keyQ = 0x00070014;
  static const int _escape = 0x00070029;
  static const int _tab = 0x0007002B;
  static const int _space = 0x0007002C;
  static const int _f1 = 0x0007003A;
  static const int _f12 = 0x00070045;
  // Right, Left, Down, Up.
  static const int _right = 0x0007004F;
  static const int _up = 0x00070052;
  static const int _power = 0x00070066;
}

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
    this.allowSystemKeys = false,
    this.limits,
    this.protectHostWindows = true,
    this.allowElevatedHost = false,
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

  /// Drops key presses the app doesn't want (for example Win+R). None by
  /// default; for window shares, pass [KeyFilters.windowShare].
  final KeyFilter? keyFilter;

  /// Whether system keys ([KeyFilters.isSystemKey]: power, sleep, media,
  /// app-launch and browser keys, and Fn) are injected. False by default:
  /// they act on the whole machine, whatever window is shared, and are
  /// dropped (`DropReason.systemKey`). Checked before [keyFilter], which
  /// never sees them unless this is true.
  final bool allowSystemKeys;

  /// Rate limits and bounds; `null` for the defaults.
  final InputLimits? limits;

  /// Whether the viewer is kept out of the host app's own windows: pointer
  /// input over them is dropped, and keys are blocked while the host app is
  /// in front, so a viewer can't click its consent dialog, its Stop button
  /// or its chat. On by default; only tests that inject into their own
  /// window turn it off.
  final bool protectHostWindows;

  /// Whether a session may start while the host runs elevated (Windows:
  /// "Run as administrator", integrity level High or above). False by
  /// default, and `RemoteInputHost.enable` throws
  /// `HostUnavailableException(HostUnavailableReason.elevatedHost)`:
  /// an elevated host's input reaches elevated apps, so a viewer could
  /// open Task Manager and run anything as administrator. With true, the
  /// viewer can drive apps at the host's level, as the presenter could;
  /// UAC prompts and the secure desktop stay out of reach
  /// (`docs/design.md` §6.5). No effect on macOS.
  final bool allowElevatedHost;
}
