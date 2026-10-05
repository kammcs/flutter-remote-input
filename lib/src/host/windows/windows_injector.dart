import 'dart:ui' show Offset;

import '../../protocol/wire_types.dart';
import '../platform.dart';
import 'input_records.dart';
import 'win32_api.dart';

/// How the Windows injector puts the pointer on a pixel
/// (`docs/design.md` §3.2, open question 3).
enum PointerPlacement {
  /// `SendInput` with `MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK`,
  /// the point converted with [absoluteCoordinate]. The default: one event
  /// per move or click, so nothing can come between the move and the
  /// button.
  absolute,

  /// `SetCursorPos` to the pixel, then a tagged zero-distance relative move
  /// (or the button event) through `SendInput`, so apps and hooks still see
  /// an input event. Exact by construction; the fallback if a device shows
  /// [absolute] off by a pixel.
  setCursorPos,
}

/// The Windows [InputInjector]: `SendInput`, with every event tagged in
/// `dwExtraInfo` (`docs/design.md` §7.2).
///
/// - **Pointer:** the point's pixel ([desktopPixel]), placed as
///   [placement] says; buttons and wheel events carry the move in the same
///   record. `back` and `forward` are `XBUTTON1` and `XBUTTON2`.
/// - **Double clicks** (open question 6): `clickCount` isn't replayed.
///   Windows decides double clicks itself from the time and distance
///   between two presses (`GetDoubleClickTime`, `SM_CXDOUBLECLK`), on the
///   host's own clock and settings, as it does for local input. The
///   session keeps presses in order and applies them as they arrive, so a
///   double click survives network jitter up to the gap between the
///   double-click time (500 ms by default) and the viewer's own interval.
///   Rewriting `MOUSEINPUT.time` to force the count isn't done: apps see
///   those timestamps.
/// - **Wheel:** [WheelConverter], open question 9.
/// - **Keys:** by scan code ([scanCodeForUsage]); usages without one are
///   [InjectResult.unmappedKey]. **Text:** [textRecords], in one call.
/// - **Failures:** `SendInput` inserting fewer records than asked, with
///   `ERROR_ACCESS_DENIED`, is UIPI ([InjectResult.elevatedTarget]); other
///   shortfalls are [InjectResult.failed].
final class WindowsInjector implements InputInjector {
  /// Creates an injector on [api].
  WindowsInjector(this._api, {this.placement = PointerPlacement.absolute});

  final Win32Api _api;

  /// How the pointer is placed.
  final PointerPlacement placement;

  final WheelConverter _wheel = WheelConverter();

  int get _tag => _api.injectionTag;

  @override
  InjectResult movePointer(
    Offset point, {
    required Set<PointerButton> heldButtons,
  }) => _pointer(point, 0);

  @override
  InjectResult pointerButton(
    Offset point,
    PointerButton button, {
    required bool down,
    required int clickCount,
  }) {
    final (flags, data) = buttonFlags(button, down: down);
    return _pointer(point, flags, mouseData: data);
  }

  @override
  InjectResult wheel(
    Offset point, {
    required int dx,
    required int dy,
    required WheelUnit unit,
  }) {
    final (h, v) = _wheel.convert(
      dx: dx,
      dy: dy,
      pixels: unit == WheelUnit.pixel,
      linesPerNotch: _api.wheelScrollLines(),
      charsPerNotch: _api.wheelScrollChars(),
    );
    // Nothing to post yet: the fraction is kept for the next event.
    if (h == 0 && v == 0) return InjectResult.injected;
    final records = <InputRecord>[];
    if (placement == PointerPlacement.setCursorPos && !_placeCursor(point)) {
      return InjectResult.failed;
    }
    final move = _placementFlags;
    final (ax, ay) = _absolute(point);
    if (v != 0) {
      records.add(
        MouseRecord(
          dx: ax,
          dy: ay,
          mouseData: v,
          flags: move | Win32Input.mouseWheel,
          extraInfo: _tag,
        ),
      );
    }
    if (h != 0) {
      records.add(
        MouseRecord(
          dx: ax,
          dy: ay,
          mouseData: h,
          flags: move | Win32Input.mouseHWheel,
          extraInfo: _tag,
        ),
      );
    }
    return _send(records);
  }

  @override
  InjectResult key(int usage, {required bool down, bool repeat = false}) {
    final code = scanCodeForUsage(usage);
    if (code == null) return InjectResult.unmappedKey;
    // A repeat is another key down, as the keyboard's own auto-repeat is.
    return _send([scanCodeRecord(code, down: down, tag: _tag)]);
  }

  @override
  InjectResult text(String text) {
    final records = textRecords(text, tag: _tag);
    if (records.isEmpty) return InjectResult.injected;
    return _send(records);
  }

  // --- Pointer --------------------------------------------------------------

  /// The flags that place the pointer with the event: absolute over the
  /// virtual desktop, or nothing (the cursor was set first).
  int get _placementFlags => placement == PointerPlacement.absolute
      ? Win32Input.mouseAbsolute |
            Win32Input.mouseVirtualDesk |
            Win32Input.mouseMove
      : 0;

  /// Posts one mouse record at [point], with button [flags] (0 for a move).
  InjectResult _pointer(Offset point, int flags, {int mouseData = 0}) {
    if (placement == PointerPlacement.setCursorPos) {
      if (!_placeCursor(point)) return InjectResult.failed;
      return _send([
        MouseRecord(
          mouseData: mouseData,
          // A zero relative move, so the move is an input event too.
          flags: flags == 0 ? Win32Input.mouseMove : flags,
          extraInfo: _tag,
        ),
      ]);
    }
    final (ax, ay) = _absolute(point);
    return _send([
      MouseRecord(
        dx: ax,
        dy: ay,
        mouseData: mouseData,
        flags: _placementFlags | flags,
        extraInfo: _tag,
      ),
    ]);
  }

  (int, int) _absolute(Offset point) {
    if (placement != PointerPlacement.absolute) return (0, 0);
    final vs = _api.virtualScreen();
    return (
      absoluteCoordinate(desktopPixel(point.dx), vs.left, vs.right - vs.left),
      absoluteCoordinate(desktopPixel(point.dy), vs.top, vs.bottom - vs.top),
    );
  }

  bool _placeCursor(Offset point) =>
      _api.setCursorPos(desktopPixel(point.dx), desktopPixel(point.dy));

  // --- Sending --------------------------------------------------------------

  InjectResult _send(List<InputRecord> records) {
    final bytes = encodeInputRecords(records);
    final r = _api.sendInput(bytes);
    // Typed text and key codes don't outlive the call in this buffer
    // (`docs/design.md` §6.6); the FFI side clears its native copy too.
    bytes.fillRange(0, bytes.length, 0);
    if (r.sent == records.length) return InjectResult.injected;
    return r.error == Win32Input.errorAccessDenied
        ? InjectResult.elevatedTarget
        : InjectResult.failed;
  }
}

/// The `dwFlags` and `mouseData` that press or release [button].
(int, int) buttonFlags(PointerButton button, {required bool down}) =>
    switch (button) {
      PointerButton.left => (
        down ? Win32Input.mouseLeftDown : Win32Input.mouseLeftUp,
        0,
      ),
      PointerButton.right => (
        down ? Win32Input.mouseRightDown : Win32Input.mouseRightUp,
        0,
      ),
      PointerButton.middle => (
        down ? Win32Input.mouseMiddleDown : Win32Input.mouseMiddleUp,
        0,
      ),
      PointerButton.back => (
        down ? Win32Input.mouseXDown : Win32Input.mouseXUp,
        Win32Input.xButton1,
      ),
      PointerButton.forward => (
        down ? Win32Input.mouseXDown : Win32Input.mouseXUp,
        Win32Input.xButton2,
      ),
    };
