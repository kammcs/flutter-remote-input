/// How the capture widget routes each keystroke: by physical key or by
/// text (`docs/design.md` §5.4). Pure functions, so the routing is tested
/// apart from any platform.
library;

import '../../keys.dart';
import '../../protocol/wire_types.dart';

/// How a `RemoteInputCapture` sends keys (`docs/design.md` §5.4).
enum KeyboardMode {
  /// Printable characters typed without Ctrl, Alt or Meta go by **text**:
  /// letters, digits, punctuation, dead-key results, IME commits, emoji
  /// and soft keyboards. Everything else goes by **physical key**: Enter,
  /// Tab, Escape, Backspace, the arrows, function keys, and any key pressed
  /// with Ctrl, Alt (Option) or Meta (Command, the Windows key) held, so
  /// shortcuts work. Modifier keys are sent physically; Caps Lock and Num
  /// Lock aren't sent, because the text carries the case.
  ///
  /// AltGr characters (a character typed with Ctrl and Alt both held, as
  /// Windows reports AltGr) go by text, so `@` on a German keyboard arrives
  /// as `@` whatever the host's layout.
  auto,

  /// Every key by position, lock keys included, and no text input. For
  /// games, terminals, or the same layout on both ends. A soft keyboard,
  /// which produces only text, still types by text.
  physical,

  /// Like [auto], but every key that produces a character goes by text,
  /// including characters typed with Alt or Option (`å`, `™`) and Option
  /// dead keys on Apple keyboards. Only keys with Ctrl or Meta held, Alt
  /// with keys that produce no character, and non-printing keys go
  /// physically.
  text,
}

/// USB HID usages (keyboard page 7) of the keys the capture and the key bar
/// send, as Flutter's `PhysicalKeyboardKey.usbHidUsage` reports them.
abstract final class HidKey {
  /// The letter A; the rest of the alphabet follows in order.
  static const int a = 0x00070004;

  /// The digit 1; 2 to 9 follow, then 0 at [digit0].
  static const int digit1 = 0x0007001E;

  /// The digit 0.
  static const int digit0 = 0x00070027;

  /// Enter (Return).
  static const int enter = 0x00070028;

  /// Escape.
  static const int escape = 0x00070029;

  /// Backspace (Delete on Apple keyboards).
  static const int backspace = 0x0007002A;

  /// Tab.
  static const int tab = 0x0007002B;

  /// Space.
  static const int space = 0x0007002C;

  /// Caps Lock.
  static const int capsLock = 0x00070039;

  /// F1; F2 to F12 follow in order.
  static const int f1 = 0x0007003A;

  /// F4.
  static const int f4 = 0x0007003D;

  /// Scroll Lock.
  static const int scrollLock = 0x00070047;

  /// Insert.
  static const int insert = 0x00070049;

  /// Home.
  static const int home = 0x0007004A;

  /// Page Up.
  static const int pageUp = 0x0007004B;

  /// Delete (forward delete).
  static const int delete = 0x0007004C;

  /// End.
  static const int end = 0x0007004D;

  /// Page Down.
  static const int pageDown = 0x0007004E;

  /// Right arrow.
  static const int arrowRight = 0x0007004F;

  /// Left arrow.
  static const int arrowLeft = 0x00070050;

  /// Down arrow.
  static const int arrowDown = 0x00070051;

  /// Up arrow.
  static const int arrowUp = 0x00070052;

  /// Num Lock.
  static const int numLock = 0x00070053;

  /// Enter on the keypad.
  static const int numpadEnter = 0x00070058;

  /// The usage of function key [n] (1 to 12).
  static int function(int n) {
    RangeError.checkValueInInterval(n, 1, 12, 'n');
    return f1 + n - 1;
  }
}

/// Where one keystroke goes.
enum KeyRoute {
  /// Sent as a `Key` message by position; the platform's text input never
  /// sees it.
  physical,

  /// Left to the platform's text input, which commits it as text (or, with
  /// no text input attached, the key event's own character is sent).
  text,

  /// Left to the platform (an IME, a lock key) and not sent at all.
  platform,
}

const int _page7 = 0x00070000;

bool _onPage7(int usage, int from, int to) =>
    usage >= _page7 + from && usage <= _page7 + to;

/// Whether [usage] is a lock key: Caps Lock, Num Lock or Scroll Lock.
bool isLockKey(int usage) =>
    usage == HidKey.capsLock ||
    usage == HidKey.numLock ||
    usage == HidKey.scrollLock;

/// Whether [usage] is an IME control key (Kana/Hiragana, Henkan, Muhenkan,
/// Hangul, Hanja and the other LANG keys). These switch the viewer's own
/// input method, so outside `physical` mode they stay with the platform.
bool isImeKey(int usage) =>
    usage == _page7 + 0x88 ||
    usage == _page7 + 0x8A ||
    usage == _page7 + 0x8B ||
    _onPage7(usage, 0x90, 0x98);

/// Whether [usage] is on the keypad and produces a character with Num Lock
/// on (digits, the decimal point, the operators).
bool isKeypadCharacterKey(int usage) =>
    _onPage7(usage, 0x54, 0x57) ||
    _onPage7(usage, 0x59, 0x63) ||
    usage == _page7 + 0x67 ||
    _onPage7(usage, 0x85, 0x86);

/// Whether [usage] is a key whose job is to produce a character: letters,
/// digits, Space, punctuation, the international keys and the keypad's
/// character keys. Every other key (Enter, Tab, the arrows, F-keys, media
/// keys, modifiers) is non-printing.
bool isPrintablePosition(int usage) =>
    _onPage7(usage, 0x04, 0x27) || // A–Z, 1–0
    _onPage7(usage, 0x2C, 0x38) || // Space and punctuation, Non-US #
    usage == _page7 + 0x64 || // Non-US \
    usage == _page7 + 0x87 || // International1 (Ro)
    usage == _page7 + 0x89 || // International3 (Yen)
    isKeypadCharacterKey(usage);

/// Whether [character] is text to type: not empty, no control characters,
/// and not one of Apple's private-use function-key characters.
bool isPrintableCharacter(String? character) {
  if (character == null || character.isEmpty) return false;
  for (final r in character.runes) {
    if (r < 0x20 || r == 0x7F || (r >= 0x80 && r < 0xA0)) return false;
    if (r >= 0xF700 && r <= 0xF8FF) return false;
  }
  return true;
}

/// Routes a key press (a down or repeat event) in [mode].
///
/// [modifiers] is the [KeyModifiers] state the viewer holds, including
/// sticky modifiers from a key bar. [composing] is true while the
/// platform's input method has composing text, and [processKey] when the
/// platform says an IME is handling the key (the web's `Process` key):
/// then every key belongs to the IME.
KeyRoute routeKeyDown({
  required KeyboardMode mode,
  required int usage,
  required String? character,
  required int modifiers,
  bool composing = false,
  bool processKey = false,
}) {
  if (mode == KeyboardMode.physical) return KeyRoute.physical;
  if (composing || processKey) return KeyRoute.platform;
  if (HidModifier.isModifier(usage)) return KeyRoute.physical;
  if (isLockKey(usage) || isImeKey(usage)) return KeyRoute.platform;
  if (!isPrintablePosition(usage)) return KeyRoute.physical;

  final printable = isPrintableCharacter(character);
  // A key that produces no character at a printable position is a dead key
  // (or one an IME takes): the platform composes it. The keypad without
  // Num Lock is the exception: its keys are navigation keys then.
  final deadKey =
      (character == null || character.isEmpty) && !isKeypadCharacterKey(usage);
  final control = modifiers & KeyModifiers.control != 0;
  final alt = modifiers & KeyModifiers.alt != 0;
  final meta = modifiers & KeyModifiers.meta != 0;

  if (control || meta) {
    // AltGr: Windows (and browsers on it) report it as Control and Alt.
    if (control && alt && !meta && printable) return KeyRoute.text;
    return KeyRoute.physical;
  }
  if (alt) {
    if (mode == KeyboardMode.text && (printable || deadKey)) {
      return KeyRoute.text;
    }
    return KeyRoute.physical;
  }
  if (printable || deadKey) return KeyRoute.text;
  return KeyRoute.physical;
}

/// The US-layout key that types [character], and whether it needs Shift,
/// or `null` if there is none. Used to turn soft-keyboard text into keys
/// when a sticky Ctrl, Alt or Meta is held, so Ctrl + "c" is Ctrl+C.
(int usage, bool shift)? usKeyForCharacter(String character) {
  if (character.length != 1) return null;
  final c = character.codeUnitAt(0);
  if (c >= 0x61 && c <= 0x7A) return (HidKey.a + c - 0x61, false); // a–z
  if (c >= 0x41 && c <= 0x5A) return (HidKey.a + c - 0x41, true); // A–Z
  if (c >= 0x31 && c <= 0x39) return (HidKey.digit1 + c - 0x31, false);
  if (c == 0x30) return (HidKey.digit0, false);
  final unshifted = _usPunctuation.indexOf(character);
  if (unshifted >= 0) return (_usPunctuationUsages[unshifted], false);
  final shifted = _usShiftedPunctuation.indexOf(character);
  if (shifted >= 0) return (_usShiftedPunctuationUsages[shifted], true);
  return null;
}

const String _usPunctuation = " -=[]\\;'`,./";
const List<int> _usPunctuationUsages = [
  0x0007002C, 0x0007002D, 0x0007002E, 0x0007002F, 0x00070030, 0x00070031, //
  0x00070033, 0x00070034, 0x00070035, 0x00070036, 0x00070037, 0x00070038,
];
const String _usShiftedPunctuation = '!@#\$%^&*()_+{}|:"~<>?';
const List<int> _usShiftedPunctuationUsages = [
  0x0007001E, 0x0007001F, 0x00070020, 0x00070021, 0x00070022, 0x00070023, //
  0x00070024, 0x00070025, 0x00070026, 0x00070027, 0x0007002D, 0x0007002E,
  0x0007002F, 0x00070030, 0x00070031, 0x00070033, 0x00070034, 0x00070035,
  0x00070036, 0x00070037, 0x00070038,
];

/// The [KeyModifiers] bits of the modifier keys in [usages].
int modifierBitsOf(Iterable<int> usages) {
  var bits = KeyModifiers.none;
  for (final u in usages) {
    bits |= HidModifier.bitOf(u);
  }
  return bits;
}
