// Pure helpers for the macOS injector: event types, modifier flags, scroll
// signs and text chunks. No dart:ffi, so they're unit-tested on any OS.

import '../../keys.dart';
import '../../keys/key_tables.g.dart';
import '../../protocol/wire_types.dart';

/// `CGEventType` values the injector posts (`CGEventTypes.h`).
abstract final class MacEventType {
  /// `kCGEventLeftMouseDown`.
  static const int leftMouseDown = 1;

  /// `kCGEventLeftMouseUp`.
  static const int leftMouseUp = 2;

  /// `kCGEventRightMouseDown`.
  static const int rightMouseDown = 3;

  /// `kCGEventRightMouseUp`.
  static const int rightMouseUp = 4;

  /// `kCGEventMouseMoved`.
  static const int mouseMoved = 5;

  /// `kCGEventLeftMouseDragged`.
  static const int leftMouseDragged = 6;

  /// `kCGEventRightMouseDragged`.
  static const int rightMouseDragged = 7;

  /// `kCGEventOtherMouseDown`.
  static const int otherMouseDown = 25;

  /// `kCGEventOtherMouseUp`.
  static const int otherMouseUp = 26;

  /// `kCGEventOtherMouseDragged`.
  static const int otherMouseDragged = 27;
}

/// `CGEventFlags` bits for the modifier keys, with the left and right
/// device bits (`NX_DEVICE*KEYMASK` in IOKit's `IOLLEvent.h`) that a real
/// keyboard sets.
abstract final class MacEventFlags {
  /// `kCGEventFlagMaskShift`.
  static const int shift = 0x00020000;

  /// `kCGEventFlagMaskControl`.
  static const int control = 0x00040000;

  /// `kCGEventFlagMaskAlternate` (Option).
  static const int alternate = 0x00080000;

  /// `kCGEventFlagMaskCommand`.
  static const int command = 0x00100000;

  /// Left Control's device bit.
  static const int deviceLeftControl = 0x00000001;

  /// Left Shift's device bit.
  static const int deviceLeftShift = 0x00000002;

  /// Right Shift's device bit.
  static const int deviceRightShift = 0x00000004;

  /// Left Command's device bit.
  static const int deviceLeftCommand = 0x00000008;

  /// Right Command's device bit.
  static const int deviceRightCommand = 0x00000010;

  /// Left Option's device bit.
  static const int deviceLeftAlternate = 0x00000020;

  /// Right Option's device bit.
  static const int deviceRightAlternate = 0x00000040;

  /// Right Control's device bit.
  static const int deviceRightControl = 0x00002000;

  /// Every bit above: the ones the injector sets on each event. The native
  /// side keeps all other bits as the event was created (Caps Lock, Fn, the
  /// numeric-pad flag on arrow keys).
  static const int modifierMask =
      shift |
      control |
      alternate |
      command |
      deviceLeftControl |
      deviceLeftShift |
      deviceRightShift |
      deviceLeftCommand |
      deviceRightCommand |
      deviceLeftAlternate |
      deviceRightAlternate |
      deviceRightControl;
}

/// The `CGEventFlags` for the modifier keys in [heldUsages] (USB HID
/// usages, `HidModifier`). Other usages are ignored.
///
/// Every injected event carries these flags explicitly, computed from what
/// the session holds, so the local user's own modifiers never mix into
/// injected keys and clicks (open question 10).
int macModifierFlags(Iterable<int> heldUsages) {
  var flags = 0;
  for (final usage in heldUsages) {
    flags |= switch (usage) {
      HidModifier.controlLeft =>
        MacEventFlags.control | MacEventFlags.deviceLeftControl,
      HidModifier.shiftLeft =>
        MacEventFlags.shift | MacEventFlags.deviceLeftShift,
      HidModifier.altLeft =>
        MacEventFlags.alternate | MacEventFlags.deviceLeftAlternate,
      HidModifier.metaLeft =>
        MacEventFlags.command | MacEventFlags.deviceLeftCommand,
      HidModifier.controlRight =>
        MacEventFlags.control | MacEventFlags.deviceRightControl,
      HidModifier.shiftRight =>
        MacEventFlags.shift | MacEventFlags.deviceRightShift,
      HidModifier.altRight =>
        MacEventFlags.alternate | MacEventFlags.deviceRightAlternate,
      HidModifier.metaRight =>
        MacEventFlags.command | MacEventFlags.deviceRightCommand,
      _ => 0,
    };
  }
  return flags;
}

/// The macOS virtual key code (`CGKeyCode`, `kVK_*`) for USB HID [usage],
/// or `null` if it has none.
int? macKeyCode(int usage) => hidToMacKeyCode[usage];

/// The `CGMouseButton` number of [button]: 0 left, 1 right, 2 middle,
/// 3 back, 4 forward (`kCGMouseEventButtonNumber`).
int macButtonNumber(PointerButton button) => switch (button) {
  PointerButton.left => 0,
  PointerButton.right => 1,
  PointerButton.middle => 2,
  PointerButton.back => 3,
  PointerButton.forward => 4,
};

/// The event type for pressing ([down]) or releasing [button].
int macButtonEventType(PointerButton button, {required bool down}) =>
    switch (button) {
      PointerButton.left =>
        down ? MacEventType.leftMouseDown : MacEventType.leftMouseUp,
      PointerButton.right =>
        down ? MacEventType.rightMouseDown : MacEventType.rightMouseUp,
      _ => down ? MacEventType.otherMouseDown : MacEventType.otherMouseUp,
    };

/// The event type and button number for moving the pointer while
/// [heldButtons] are down.
///
/// With a button held the move is a drag (`kCGEventLeftMouseDragged` and
/// the others), or apps don't see a drag (`docs/design.md` §5.3). Left
/// wins over right, and right over the others, as on a real mouse.
({int type, int button}) macMoveEvent(Set<PointerButton> heldButtons) {
  if (heldButtons.isEmpty) return (type: MacEventType.mouseMoved, button: 0);
  if (heldButtons.contains(PointerButton.left)) {
    return (type: MacEventType.leftMouseDragged, button: 0);
  }
  if (heldButtons.contains(PointerButton.right)) {
    return (type: MacEventType.rightMouseDragged, button: 1);
  }
  final others = heldButtons.map(macButtonNumber).toList()..sort();
  return (type: MacEventType.otherMouseDragged, button: others.first);
}

/// `CGScrollEventUnit` for [unit]: 0 pixels, 1 lines.
int macScrollUnit(WheelUnit unit) => switch (unit) {
  WheelUnit.pixel => 0,
  WheelUnit.line => 1,
};

/// The wheel values for a protocol delta: `wheel1` vertical, `wheel2`
/// horizontal.
///
/// The protocol's positive [dy] reveals content below and positive [dx]
/// content to the right (`RemoteInputViewer.wheel`). Core Graphics' wheel
/// values are the other way round (positive scrolls up and left), and the
/// system applies the user's "natural scrolling" setting to hardware only,
/// so both signs flip.
({int wheel1, int wheel2}) macWheels({required int dx, required int dy}) =>
    (wheel1: _int32(-dy), wheel2: _int32(-dx));

int _int32(int v) => v.clamp(-0x80000000, 0x7FFFFFFF);

/// The most UTF-16 code units one Unicode keyboard event carries: macOS
/// truncates longer strings (`CGEventKeyboardSetUnicodeString`).
const int macMaxTextUnits = 20;

/// [text] as UTF-16 chunks of at most [maxUnits] code units, never
/// splitting a surrogate pair. Each chunk is typed as one key down and up.
List<List<int>> macTextChunks(String text, {int maxUnits = macMaxTextUnits}) {
  if (maxUnits < 2) {
    throw ArgumentError.value(maxUnits, 'maxUnits', 'must be at least 2');
  }
  final units = text.codeUnits;
  final chunks = <List<int>>[];
  var start = 0;
  while (start < units.length) {
    var end = start + maxUnits;
    if (end >= units.length) {
      end = units.length;
    } else if (_isHighSurrogate(units[end - 1])) {
      end--; // Keep the pair together in the next chunk.
    }
    chunks.add(units.sublist(start, end));
    start = end;
  }
  return chunks;
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
