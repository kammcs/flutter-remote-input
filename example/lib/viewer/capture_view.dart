// TEMPORARY: replaced by RemoteInputCapture when M4 merges.
//
// The example's only use of capture is through [CaptureView] and
// [KeyBarView] in this file. When `RemoteInputCapture` and `RemoteKeyBar`
// land in package:remote_input (roadmap M4), swap them in here:
//
// 1. Delete the [KeyboardMode] and [TouchMode] enums below, and add
//    `export 'package:remote_input/remote_input.dart' show KeyboardMode,
//    TouchMode;` so the rest of the example keeps importing them from here.
// 2. Make [CaptureView.build] return
//    `RemoteInputCapture(viewer: viewer, contentSize: contentSize, fit: fit,
//    keyboardMode: keyboardMode, touchMode: touchMode, focusNode: focusNode,
//    autofocus: autofocus, child: child)`, and drop `_CaptureViewState`.
// 3. Make [KeyBarView.build] return `RemoteKeyBar(viewer: viewer)` (with
//    the capture's controller, if it takes one), and drop the stand-in.
//
// Until then, a minimal stand-in built on RemoteInputViewer directly: a
// Listener for mouse, trackpad scrolling and one-finger touch (direct mode
// only), and a Focus that sends hardware keys (printable characters as text,
// everything else as physical keys). No trackpad touch mode, no pinch-zoom,
// no IME or soft keyboard: those are M4's.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:remote_input/remote_input.dart';

/// How the viewer's keys are sent (`docs/design.md` §5.4).
///
/// TEMPORARY: the package's own `KeyboardMode` replaces this with M4.
enum KeyboardMode {
  /// Printable characters as text, everything else (and shortcuts) as
  /// physical keys.
  auto,

  /// Every key by position.
  physical,

  /// Printable input as text only.
  text,
}

/// How touch maps to the pointer (`docs/design.md` §8).
///
/// TEMPORARY: the package's own `TouchMode` replaces this with M4.
enum TouchMode {
  /// A drawn cursor that a finger moves relatively, like a laptop's
  /// trackpad. The default on phones.
  trackpad,

  /// A tap clicks where the finger is. The default on tablets.
  direct,
}

/// Captures pointer and keyboard input over [child], the remote view, and
/// sends it through [viewer].
///
/// [child] fills this widget and shows the remote picture fitted by [fit]
/// into it, like a video view; [contentSize] is the picture's size, so the
/// letterbox bars can be left out of the mapping (`docs/design.md` §3.1).
class CaptureView extends StatefulWidget {
  /// Creates a capture view.
  const CaptureView({
    super.key,
    required this.viewer,
    required this.child,
    this.contentSize,
    this.fit = BoxFit.contain,
    this.keyboardMode = KeyboardMode.auto,
    this.touchMode,
    this.focusNode,
    this.autofocus = true,
  });

  /// The viewer to send through.
  final RemoteInputViewer viewer;

  /// The remote view.
  final Widget child;

  /// The remote picture's size, or `null` to use the whole view.
  final Size? contentSize;

  /// How [child] fits the picture into the view.
  final BoxFit fit;

  /// How keys are sent.
  final KeyboardMode keyboardMode;

  /// How touch maps to the pointer; `null` for the platform's default.
  final TouchMode? touchMode;

  /// The focus node for keys; one is made if `null`.
  final FocusNode? focusNode;

  /// Whether to take keyboard focus when first shown.
  final bool autofocus;

  @override
  State<CaptureView> createState() => _CaptureViewState();
}

// TEMPORARY stand-in. See the top of this file.
class _CaptureViewState extends State<CaptureView> {
  FocusNode? _ownFocus;
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  Rect _content = Rect.zero;
  final Map<int, PointerButton> _pressed = {};
  int? _touchPointer;

  DateTime? _lastDownAt;
  Offset? _lastDownAtPoint;
  PointerButton? _lastDownButton;
  int _clickCount = 1;

  final Set<int> _physicalDown = {};
  final Set<int> _textDown = {};

  RemoteInputViewer get _viewer => widget.viewer;

  @override
  void dispose() {
    _ownFocus?.dispose();
    super.dispose();
  }

  Offset _normalize(Offset local) => Offset(
    (local.dx - _content.left) / _content.width,
    (local.dy - _content.top) / _content.height,
  );

  bool _inside(Offset local) => _content.contains(local);

  int _countClick(PointerButton button, Offset local) {
    final now = DateTime.now();
    final last = _lastDownAt;
    final lastPoint = _lastDownAtPoint;
    final repeat =
        last != null &&
        lastPoint != null &&
        _lastDownButton == button &&
        now.difference(last) < const Duration(milliseconds: 500) &&
        (local - lastPoint).distance < 8;
    _clickCount = repeat ? _clickCount + 1 : 1;
    _lastDownAt = now;
    _lastDownAtPoint = local;
    _lastDownButton = button;
    return _clickCount;
  }

  static PointerButton? _buttonOf(int buttons) {
    if (buttons & kPrimaryMouseButton != 0) return PointerButton.left;
    if (buttons & kSecondaryMouseButton != 0) return PointerButton.right;
    if (buttons & kMiddleMouseButton != 0) return PointerButton.middle;
    if (buttons & kBackMouseButton != 0) return PointerButton.back;
    if (buttons & kForwardMouseButton != 0) return PointerButton.forward;
    return null;
  }

  void _onDown(PointerDownEvent e) {
    _focus.requestFocus();
    if (!_inside(e.localPosition)) return;
    final point = _normalize(e.localPosition);
    if (e.kind == PointerDeviceKind.mouse) {
      final button = _buttonOf(e.buttons);
      if (button == null) return;
      _pressed[e.pointer] = button;
      _viewer.pointerButton(
        point,
        button,
        down: true,
        clickCount: _countClick(button, e.localPosition),
      );
      return;
    }
    // Touch and stylus: direct mode, one finger.
    if (_touchPointer != null) return;
    _touchPointer = e.pointer;
    _pressed[e.pointer] = PointerButton.left;
    _viewer
      ..pointerMove(point)
      ..pointerButton(
        point,
        PointerButton.left,
        down: true,
        clickCount: _countClick(PointerButton.left, e.localPosition),
      );
  }

  void _onMove(PointerMoveEvent e) {
    if (!_pressed.containsKey(e.pointer)) return;
    _viewer.pointerMove(_normalize(e.localPosition)); // Clamped by the viewer.
  }

  void _onHover(PointerHoverEvent e) {
    if (_inside(e.localPosition)) {
      _viewer.pointerMove(_normalize(e.localPosition));
    }
  }

  void _onUp(PointerEvent e) {
    final button = _pressed.remove(e.pointer);
    if (_touchPointer == e.pointer) _touchPointer = null;
    if (button == null) return;
    _viewer.pointerButton(
      _normalize(e.localPosition),
      button,
      down: false,
      clickCount: _clickCount,
    );
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent && _inside(e.localPosition)) {
      _viewer.wheel(
        _normalize(e.localPosition),
        dx: e.scrollDelta.dx,
        dy: e.scrollDelta.dy,
      );
    }
  }

  void _onPanZoom(PointerPanZoomUpdateEvent e) {
    // Two fingers on a desktop trackpad: scroll by the fingers' movement.
    if (!_inside(e.localPosition)) return;
    _viewer.wheel(
      _normalize(e.localPosition),
      dx: -e.localPanDelta.dx,
      dy: -e.localPanDelta.dy,
    );
  }

  void _onFocusChange(bool focused) {
    if (focused) return;
    _physicalDown.clear();
    _textDown.clear();
    _viewer.releaseAll();
  }

  static int _modifiers() {
    final k = HardwareKeyboard.instance;
    var m = KeyModifiers.none;
    if (k.isShiftPressed) m |= KeyModifiers.shift;
    if (k.isControlPressed) m |= KeyModifiers.control;
    if (k.isAltPressed) m |= KeyModifiers.alt;
    if (k.isMetaPressed) m |= KeyModifiers.meta;
    return m;
  }

  static bool _printable(String? s) =>
      s != null &&
      s.isNotEmpty &&
      s.runes.every(
        (r) =>
            r >= 0x20 &&
            r != 0x7F &&
            !(r >= 0x80 && r < 0xA0) &&
            !(r >= 0xF700 && r <= 0xF8FF), // macOS function-key characters
      );

  static const Set<int> _lockKeys = {0x00070039, 0x00070047, 0x00070053};

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final usage = e.physicalKey.usbHidUsage;
    final modifiers = _modifiers();
    final mode = widget.keyboardMode;
    final commandHeld =
        modifiers & (KeyModifiers.control | KeyModifiers.meta) != 0;
    switch (e) {
      case KeyDownEvent():
        if (mode != KeyboardMode.physical && _lockKeys.contains(usage)) {
          return KeyEventResult.handled; // Case goes by text.
        }
        if (mode != KeyboardMode.physical &&
            _printable(e.character) &&
            !commandHeld) {
          _textDown.add(usage);
          _viewer.text(e.character!);
        } else {
          _physicalDown.add(usage);
          _viewer.key(usage, KeyAction.down, modifiers: modifiers);
        }
      case KeyRepeatEvent():
        if (_textDown.contains(usage)) {
          if (_printable(e.character)) _viewer.text(e.character!);
        } else if (_physicalDown.contains(usage)) {
          _viewer.key(usage, KeyAction.repeat, modifiers: modifiers);
        }
      case KeyUpEvent():
        _textDown.remove(usage);
        if (_physicalDown.remove(usage)) {
          _viewer.key(usage, KeyAction.up, modifiers: modifiers);
        }
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: widget.autofocus,
      onFocusChange: _onFocusChange,
      onKeyEvent: _onKey,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final box = Offset.zero & constraints.biggest;
          final content = widget.contentSize;
          _content = content == null || content.isEmpty
              ? box
              : Alignment.center.inscribe(
                  applyBoxFit(widget.fit, content, box.size).destination,
                  box,
                );
          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onDown,
            onPointerMove: _onMove,
            onPointerHover: _onHover,
            onPointerUp: _onUp,
            onPointerCancel: _onUp,
            onPointerSignal: _onSignal,
            onPointerPanZoomUpdate: _onPanZoom,
            child: MouseRegion(
              cursor: SystemMouseCursors.precise,
              child: widget.child,
            ),
          );
        },
      ),
    );
  }
}

/// Keys a soft keyboard lacks (Esc, Tab, the arrows, sticky modifiers),
/// for touch devices.
class KeyBarView extends StatefulWidget {
  /// Creates a key bar for [viewer].
  const KeyBarView({super.key, required this.viewer});

  /// The viewer to send through.
  final RemoteInputViewer viewer;

  @override
  State<KeyBarView> createState() => _KeyBarViewState();
}

// TEMPORARY stand-in. See the top of this file.
class _KeyBarViewState extends State<KeyBarView> {
  final Set<int> _sticky = {};

  static const List<(String, int)> _modifierKeys = [
    ('Ctrl', HidModifier.controlLeft),
    ('Alt', HidModifier.altLeft),
    ('⌘/Win', HidModifier.metaLeft),
    ('Shift', HidModifier.shiftLeft),
  ];

  static const List<(String, int)> _keys = [
    ('Esc', 0x00070029),
    ('Tab', 0x0007002B),
    ('←', 0x00070050),
    ('↑', 0x00070052),
    ('↓', 0x00070051),
    ('→', 0x0007004F),
    ('⌫', 0x0007002A),
    ('Del', 0x0007004C),
    ('⏎', 0x00070028),
  ];

  void _press(int usage) {
    widget.viewer.sendShortcut([..._sticky, usage]);
    if (_sticky.isNotEmpty) setState(_sticky.clear);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          for (final (label, usage) in _modifierKeys)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: FilterChip(
                label: Text(label),
                selected: _sticky.contains(usage),
                onSelected: (on) => setState(
                  () => on ? _sticky.add(usage) : _sticky.remove(usage),
                ),
              ),
            ),
          const SizedBox(width: 8),
          for (final (label, usage) in _keys)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: ActionChip(
                label: Text(label),
                onPressed: () => _press(usage),
              ),
            ),
        ],
      ),
    );
  }
}
