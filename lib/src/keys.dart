import 'protocol/wire_types.dart';

/// USB HID usages of the modifier keys (keyboard page 0x07), as Flutter's
/// `PhysicalKeyboardKey.usbHidUsage` reports them.
abstract final class HidModifier {
  /// Left Control.
  static const int controlLeft = 0x000700E0;

  /// Left Shift.
  static const int shiftLeft = 0x000700E1;

  /// Left Alt (Option).
  static const int altLeft = 0x000700E2;

  /// Left Meta (Command, Windows key).
  static const int metaLeft = 0x000700E3;

  /// Right Control.
  static const int controlRight = 0x000700E4;

  /// Right Shift.
  static const int shiftRight = 0x000700E5;

  /// Right Alt (Option, AltGr).
  static const int altRight = 0x000700E6;

  /// Right Meta (Command, Windows key).
  static const int metaRight = 0x000700E7;

  /// Whether [usage] is a modifier key.
  static bool isModifier(int usage) =>
      usage >= controlLeft && usage <= metaRight;

  /// The [KeyModifiers] bit of modifier key [usage], or 0 for other keys.
  static int bitOf(int usage) => switch (usage) {
    controlLeft || controlRight => KeyModifiers.control,
    shiftLeft || shiftRight => KeyModifiers.shift,
    altLeft || altRight => KeyModifiers.alt,
    metaLeft || metaRight => KeyModifiers.meta,
    _ => 0,
  };
}

/// Swaps Control and Meta, in a key usage.
int swapControlMetaUsage(int usage) => switch (usage) {
  HidModifier.controlLeft => HidModifier.metaLeft,
  HidModifier.metaLeft => HidModifier.controlLeft,
  HidModifier.controlRight => HidModifier.metaRight,
  HidModifier.metaRight => HidModifier.controlRight,
  _ => usage,
};

/// Swaps the Control and Meta bits of a [KeyModifiers] mask.
int swapControlMetaBits(int modifiers) {
  const both = KeyModifiers.control | KeyModifiers.meta;
  final m = modifiers & both;
  if (m == 0 || m == both) return modifiers;
  return modifiers ^ both;
}
