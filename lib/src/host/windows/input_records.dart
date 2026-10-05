// Win32 INPUT records for SendInput, built as bytes in pure Dart so their
// layout and field values are unit tested on any OS (`docs/design.md` §7.2).
//
// Layout (64-bit Windows: x64 and arm64, the only ones Flutter targets):
//
//   INPUT        type: DWORD @0, 4 bytes padding, union @8 (32 bytes); 40
//   MOUSEINPUT   dx: LONG @0, dy: LONG @4, mouseData: DWORD @8,
//                dwFlags: DWORD @12, time: DWORD @16, 4 bytes padding,
//                dwExtraInfo: ULONG_PTR @24; 32
//   KEYBDINPUT   wVk: WORD @0, wScan: WORD @2, dwFlags: DWORD @4,
//                time: DWORD @8, 4 bytes padding, dwExtraInfo: ULONG_PTR @16;
//                24
//
// The native side checks the same layout with static_asserts
// (windows/remote_input_native.cpp) and reports sizeof(INPUT) at run time.

import 'dart:typed_data';

import '../../keys/key_tables.g.dart';

/// `sizeof(INPUT)` on 64-bit Windows.
const int inputRecordSize = 40;

/// The union's offset in an `INPUT`.
const int _unionOffset = 8;

/// Win32 constants from `winuser.h`, for the records this package builds.
abstract final class Win32Input {
  /// `INPUT_MOUSE`.
  static const int typeMouse = 0;

  /// `INPUT_KEYBOARD`.
  static const int typeKeyboard = 1;

  /// `MOUSEEVENTF_MOVE`.
  static const int mouseMove = 0x0001;

  /// `MOUSEEVENTF_LEFTDOWN`.
  static const int mouseLeftDown = 0x0002;

  /// `MOUSEEVENTF_LEFTUP`.
  static const int mouseLeftUp = 0x0004;

  /// `MOUSEEVENTF_RIGHTDOWN`.
  static const int mouseRightDown = 0x0008;

  /// `MOUSEEVENTF_RIGHTUP`.
  static const int mouseRightUp = 0x0010;

  /// `MOUSEEVENTF_MIDDLEDOWN`.
  static const int mouseMiddleDown = 0x0020;

  /// `MOUSEEVENTF_MIDDLEUP`.
  static const int mouseMiddleUp = 0x0040;

  /// `MOUSEEVENTF_XDOWN`.
  static const int mouseXDown = 0x0080;

  /// `MOUSEEVENTF_XUP`.
  static const int mouseXUp = 0x0100;

  /// `MOUSEEVENTF_WHEEL`.
  static const int mouseWheel = 0x0800;

  /// `MOUSEEVENTF_HWHEEL`.
  static const int mouseHWheel = 0x1000;

  /// `MOUSEEVENTF_VIRTUALDESK`.
  static const int mouseVirtualDesk = 0x4000;

  /// `MOUSEEVENTF_ABSOLUTE`.
  static const int mouseAbsolute = 0x8000;

  /// `XBUTTON1`: back.
  static const int xButton1 = 0x0001;

  /// `XBUTTON2`: forward.
  static const int xButton2 = 0x0002;

  /// `WHEEL_DELTA`: one notch of a mouse wheel.
  static const int wheelDelta = 120;

  /// `KEYEVENTF_EXTENDEDKEY`.
  static const int keyExtended = 0x0001;

  /// `KEYEVENTF_KEYUP`.
  static const int keyUp = 0x0002;

  /// `KEYEVENTF_UNICODE`.
  static const int keyUnicode = 0x0004;

  /// `KEYEVENTF_SCANCODE`.
  static const int keyScanCode = 0x0008;

  /// `ERROR_ACCESS_DENIED`: what `SendInput` reports when UIPI blocks it.
  static const int errorAccessDenied = 5;
}

/// One `INPUT` record.
///
/// Like everything in the package, records don't override `toString`, so
/// what they carry can't leak into logs.
sealed class InputRecord {
  const InputRecord({required this.flags, required this.extraInfo});

  /// `dwFlags`.
  final int flags;

  /// `dwExtraInfo`: the package's tag, so the hook thread can tell its own
  /// events apart.
  final int extraInfo;

  /// Writes this record at [offset] in [data] (all bytes there are zero).
  void _write(ByteData data, int offset);
}

/// An `INPUT_MOUSE` record.
final class MouseRecord extends InputRecord {
  /// Creates a [MouseRecord].
  const MouseRecord({
    this.dx = 0,
    this.dy = 0,
    this.mouseData = 0,
    required super.flags,
    required super.extraInfo,
  });

  /// `dx`: normalized 0–65535 with [Win32Input.mouseAbsolute], else
  /// relative.
  final int dx;

  /// `dy`, as [dx].
  final int dy;

  /// `mouseData`: a signed wheel delta, or the X button.
  final int mouseData;

  @override
  void _write(ByteData data, int offset) {
    final u = offset + _unionOffset;
    data
      ..setUint32(offset, Win32Input.typeMouse, Endian.little)
      ..setInt32(u, dx, Endian.little)
      ..setInt32(u + 4, dy, Endian.little)
      ..setUint32(u + 8, mouseData & 0xFFFFFFFF, Endian.little)
      ..setUint32(u + 12, flags, Endian.little)
      // time (u + 16) stays 0: the system stamps the event.
      ..setUint64(u + 24, extraInfo, Endian.little);
  }

  @override
  bool operator ==(Object other) =>
      other is MouseRecord &&
      other.dx == dx &&
      other.dy == dy &&
      other.mouseData == mouseData &&
      other.flags == flags &&
      other.extraInfo == extraInfo;

  @override
  int get hashCode => Object.hash(dx, dy, mouseData, flags, extraInfo);
}

/// An `INPUT_KEYBOARD` record.
final class KeyRecord extends InputRecord {
  /// Creates a [KeyRecord]. `wVk` is always 0: keys go by scan code or by
  /// Unicode.
  const KeyRecord({
    required this.scan,
    required super.flags,
    required super.extraInfo,
  });

  /// `wScan`: a scan code's low byte, or a UTF-16 code unit with
  /// [Win32Input.keyUnicode].
  final int scan;

  @override
  void _write(ByteData data, int offset) {
    final u = offset + _unionOffset;
    data
      ..setUint32(offset, Win32Input.typeKeyboard, Endian.little)
      // wVk (u) stays 0.
      ..setUint16(u + 2, scan, Endian.little)
      ..setUint32(u + 4, flags, Endian.little)
      // time (u + 8) stays 0.
      ..setUint64(u + 16, extraInfo, Endian.little);
  }

  @override
  bool operator ==(Object other) =>
      other is KeyRecord &&
      other.scan == scan &&
      other.flags == flags &&
      other.extraInfo == extraInfo;

  @override
  int get hashCode => Object.hash(scan, flags, extraInfo);
}

/// [records] as an array of `INPUT`s, for one `SendInput` call.
Uint8List encodeInputRecords(List<InputRecord> records) {
  final bytes = Uint8List(records.length * inputRecordSize);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < records.length; i++) {
    records[i]._write(data, i * inputRecordSize);
  }
  return bytes;
}

// --- Coordinates ------------------------------------------------------------

/// The desktop pixel containing coordinate [v]: pixel `i` covers `[i, i+1)`.
///
/// `floor`, not `round`: a surface's last wire value maps just inside its
/// right edge (`left + width - 0.0…`), which rounds onto the next pixel,
/// outside the surface.
int desktopPixel(double v) => v.floor();

/// The `SendInput` absolute coordinate (`MOUSEEVENTF_ABSOLUTE |
/// MOUSEEVENTF_VIRTUALDESK`) that lands on desktop pixel [pixel], for a
/// virtual screen starting at [origin] and [extent] pixels long.
///
/// Windows maps an absolute value `a` to the pixel `origin + floor(a *
/// extent / 65536)`. The smallest `a` for pixel offset `i` is therefore
/// `ceil(i * 65536 / extent)`, which this returns. It lands at `[i, i +
/// extent / 65536)` within the pixel: never short of it, and less than half
/// a pixel past its left edge for any desktop up to 32767 pixels, so it
/// also holds if Windows rounds rather than truncates.
///
/// The commonly copied `i * 65535 / extent` is the known off-by-one: it
/// lands just short of pixel `i`, so truncation gives `i - 1` for every
/// pixel but the first. `docs/design.md` §3.2, open question 3.
int absoluteCoordinate(int pixel, int origin, int extent) {
  if (extent <= 0) return 0;
  final i = (pixel - origin).clamp(0, extent - 1);
  return ((i * 65536 + extent - 1) ~/ extent).clamp(0, 65535);
}

/// The desktop pixel Windows moves to for absolute coordinate [a]: the
/// inverse of [absoluteCoordinate], as `docs/design.md` §3.2 models it.
int pixelForAbsolute(int a, int origin, int extent) =>
    origin + (a * extent) ~/ 65536;

// --- Keys -------------------------------------------------------------------

/// A set-1 scan code, split for `KEYBDINPUT`.
typedef ScanCode = ({int scan, bool extended});

/// The scan code for USB HID [usage], or `null` when it has none.
///
/// The table carries `0xE0` in the high byte for extended keys (`0xE048` is
/// Up): those send the low byte with `KEYEVENTF_EXTENDEDKEY`.
ScanCode? scanCodeForUsage(int usage) {
  final code = hidToWindowsScanCode[usage];
  if (code == null || code == 0) return null;
  return (scan: code & 0xFF, extended: (code >> 8) == 0xE0);
}

/// The record for a key press or release by scan code.
KeyRecord scanCodeRecord(
  ScanCode code, {
  required bool down,
  required int tag,
}) {
  var flags = Win32Input.keyScanCode;
  if (code.extended) flags |= Win32Input.keyExtended;
  if (!down) flags |= Win32Input.keyUp;
  return KeyRecord(scan: code.scan, flags: flags, extraInfo: tag);
}

/// Enter (set-1 0x1C), for line breaks in typed text.
const ScanCode _enter = (scan: 0x1C, extended: false);

/// Tab (set-1 0x0F), for tabs in typed text.
const ScanCode _tab = (scan: 0x0F, extended: false);

/// The records that type [text]: a down and an up per UTF-16 code unit with
/// `KEYEVENTF_UNICODE` (a surrogate pair is two units, each pressed and
/// released).
///
/// Line breaks (`\r\n`, `\r` or `\n`) press Enter and tabs press Tab, by
/// scan code: many apps act on the Enter and Tab keys, not on the carriage
/// return or tab characters `KEYEVENTF_UNICODE` would deliver. The session
/// has already stripped every other control character.
List<KeyRecord> textRecords(String text, {required int tag}) {
  final out = <KeyRecord>[];
  void press(ScanCode code) {
    out
      ..add(scanCodeRecord(code, down: true, tag: tag))
      ..add(scanCodeRecord(code, down: false, tag: tag));
  }

  final units = text.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (u == 0x0D) {
      if (i + 1 < units.length && units[i + 1] == 0x0A) i++;
      press(_enter);
    } else if (u == 0x0A) {
      press(_enter);
    } else if (u == 0x09) {
      press(_tab);
    } else {
      out
        ..add(KeyRecord(scan: u, flags: Win32Input.keyUnicode, extraInfo: tag))
        ..add(
          KeyRecord(
            scan: u,
            flags: Win32Input.keyUnicode | Win32Input.keyUp,
            extraInfo: tag,
          ),
        );
    }
  }
  return out;
}

// --- Wheel ------------------------------------------------------------------

/// Logical pixels one line scrolls, for converting pixel deltas: Chromium
/// and Edge scroll 100 pixels per notch at the default 3 lines per notch.
const double pixelsPerWheelLine = 100 / 3;

/// `SPI_GETWHEELSCROLLLINES`' value for "one screen per notch".
const int wheelPageScroll = 0xFFFFFFFF;

/// The system default for lines (and characters) per notch.
const int defaultLinesPerNotch = 3;

/// Turns wire wheel deltas into `WHEEL_DELTA` units (120 per notch),
/// keeping the fractions pixel deltas leave so slow trackpad scrolling isn't
/// lost (`docs/design.md` §7.2, open question 9).
///
/// - **Lines:** a wire line is one line on the host, so `lines * 120 /
///   linesPerNotch`, with the host's own lines per notch
///   (`SPI_GETWHEELSCROLLLINES`, or `SPI_GETWHEELSCROLLCHARS` across).
/// - **Pixels:** [pixelsPerWheelLine] pixels to a line, then as lines. At
///   the default 3 lines per notch that is 120 units per 100 pixels.
///
/// Units are sent as they accrue, often less than a notch: Windows' own
/// precision touchpads do the same, and apps written for high-resolution
/// wheels scroll smoothly. Apps that only act on whole notches accumulate
/// them themselves, as they do for a touchpad.
///
/// Signs follow Windows: positive `MOUSEEVENTF_WHEEL` scrolls up (reveals
/// what's above), positive `MOUSEEVENTF_HWHEEL` scrolls right. The wire's
/// positive dy reveals what's below, so it's negated; its dx isn't.
final class WheelConverter {
  double _x = 0;
  double _y = 0;

  /// The `(horizontal, vertical)` wheel units for wire deltas [dx], [dy] in
  /// [pixels] or lines, with the host's [linesPerNotch] and
  /// [charsPerNotch].
  (int, int) convert({
    required int dx,
    required int dy,
    required bool pixels,
    required int linesPerNotch,
    required int charsPerNotch,
  }) {
    _x = _accumulate(_x, dx, pixels, charsPerNotch);
    _y = _accumulate(_y, -dy, pixels, linesPerNotch);
    final x = _whole(_x);
    final y = _whole(_y);
    _x -= x;
    _y -= y;
    return (x, y);
  }

  /// Forgets the fractions kept, as at a new gesture.
  void reset() {
    _x = 0;
    _y = 0;
  }

  static double _accumulate(double acc, int delta, bool pixels, int perNotch) {
    if (delta == 0) return acc;
    // A reversal starts afresh rather than cancelling the remainder.
    if (acc != 0 && (acc < 0) != (delta < 0)) acc = 0;
    final lines = pixels ? delta / pixelsPerWheelLine : delta.toDouble();
    return acc + lines * Win32Input.wheelDelta / _perNotch(perNotch);
  }

  /// [v]'s whole units, toward zero, ignoring floating-point error below a
  /// millionth of a unit (ten 1.2s add up to 11.999…, which is 12).
  static int _whole(double v) => (v * 1e6).round() ~/ 1000000;

  static int _perNotch(int v) =>
      v <= 0 || v == wheelPageScroll ? defaultLinesPerNotch : v;
}
