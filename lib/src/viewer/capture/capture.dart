/// The viewer-side capture widget, its controller and the key bar
/// (`docs/design.md` §8).
///
/// ## Keys and text: never twice, never dropped (open question 11)
///
/// Every platform Flutter runs on gives a key event to the framework first,
/// and gives it to the platform's text input (which turns keys, dead keys
/// and IME input into committed text) only if the framework didn't handle
/// it: macOS and Windows redispatch unhandled events to the text input
/// plugin; iOS and Android pass unhandled hardware keys on to the text
/// input view or input connection; on the web, a handled event has
/// `preventDefault()` called on it (from the `flutter/keyevent` reply, in a
/// microtask before the browser's default action), so the hidden text
/// field never sees it.
///
/// So the capture decides per keystroke ([routeKeyDown]) and answers the
/// framework accordingly:
///
/// - **physical:** sent as a `Key` message, and the event is
///   [KeyEventResult.handled], so the text input never sees it.
/// - **text:** the event is [KeyEventResult.skipRemainingHandlers]: no
///   ancestor shortcut takes it, the framework reports it unhandled, and
///   the platform's text input commits it to the [CaptureTextInput] client,
///   which sends it as `Text`. Nothing is sent for the key event itself.
///   With no text input shown (a hardware keyboard on a phone whose soft
///   keyboard is down), the event's own `character` is sent instead and the
///   event is handled.
/// - **platform:** IME keys, keys pressed while text is being composed,
///   and lock keys outside `physical` mode go to the platform and nothing is
///   sent.
///
/// Edits that arrive only through the text input are mapped to keys:
/// deletions (a soft keyboard's Backspace on iOS) to Backspace, line breaks
/// and input actions to Enter. Android's soft keyboards send Backspace and
/// often Enter as key events, which take the physical path. The web engine
/// performs the input action on a hardware Enter as well as delivering the
/// key event, so an action that arrives while a hardware Enter is held is
/// ignored.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../host/options.dart' show ModifierMapping;
import '../../keys.dart';
import '../../protocol/wire_types.dart';
import '../../session_state.dart';
import '../viewer.dart';
import 'context_menu.dart';
import 'geometry.dart';
import 'key_routing.dart';
import 'text_bridge.dart';

part 'controller.dart';
part 'key_bar.dart';

/// How touch input controls the remote pointer (`docs/design.md` §8).
enum TouchMode {
  /// The viewer draws its own cursor, and a finger moves it relatively, like
  /// a laptop trackpad: tap clicks at the cursor, double tap double-clicks,
  /// two-finger tap right-clicks, tap then drag drags, and a two-finger
  /// drag scrolls. The default on phones.
  trackpad,

  /// The finger is the pointer: tap clicks where it is, long press
  /// right-clicks, a one-finger drag is a left-button drag, a two-finger
  /// drag scrolls. The default on tablets and desktops.
  direct,
}

/// Captures pointer, touch and keyboard input over a remote view and sends
/// it through [viewer] (`docs/design.md` §8).
///
/// Wrap the widget that shows the remote video in it:
///
/// ```dart
/// RemoteInputCapture(
///   viewer: viewer,
///   contentSize: const Size(1920, 1080), // the video's frame size
///   child: videoView,                    // laid out unchanged
/// )
/// ```
///
/// Points are mapped into the **content rect**, the part of the widget the
/// picture fills ([contentSize] and [fit], or [contentRect]), and sent
/// normalized. Without a button held, pointer moves outside it aren't sent;
/// with one held, they're clamped to its edge.
///
/// Nothing is sent, and no gesture or scroll is taken from ancestors, while
/// the viewer's session isn't active. Keys are captured only while the
/// widget has focus (it takes focus when tapped or clicked); when it loses
/// focus, the app stops being in the foreground (another window or app takes
/// the keyboard, as Alt+Tab does), or the session stops being active,
/// everything held on the host is released. Mouse buttons still held then
/// aren't pressed again until they're let go.
///
/// On the web, the browser's context menu is turned off while a capture's
/// session is active, so a right click goes to the host
/// ([BrowserContextMenu]); it's turned back on when no capture needs it off,
/// unless the app had turned it off itself.
class RemoteInputCapture extends StatefulWidget {
  /// Creates a capture over [child].
  const RemoteInputCapture({
    super.key,
    required this.viewer,
    required this.child,
    this.contentSize,
    this.fit = BoxFit.contain,
    this.contentRect,
    this.keyboardMode = KeyboardMode.auto,
    this.touchMode,
    this.enableKeyboard = true,
    this.autofocus = true,
    this.focusNode,
    this.releaseShortcut,
    this.allowZoom = true,
    this.cursorBuilder,
    this.controller,
    this.trackpadSpeed = 1.25,
    this.overlayBuilder,
  }) : assert(trackpadSpeed > 0);

  /// The viewer that sends the input.
  final RemoteInputViewer viewer;

  /// The remote view, usually a video. Laid out with this widget's
  /// constraints, unchanged.
  final Widget child;

  /// The size of the picture [child] shows, usually the video's frame size.
  /// Defaults to the host's announced surface size
  /// ([RemoteInputViewer.surface]); once frames arrive, their size is the
  /// one to pass.
  final Size? contentSize;

  /// How [child] fits [contentSize] into this widget, to find the
  /// letterbox. The picture is assumed centred, as video views centre it.
  final BoxFit fit;

  /// The picture's rect in this widget's coordinates, for layouts that
  /// [contentSize] and [fit] don't describe. Overrides both.
  final Rect? contentRect;

  /// How keys are sent ([KeyboardMode]).
  final KeyboardMode keyboardMode;

  /// How touch controls the pointer. `null` picks [TouchMode.trackpad] on
  /// phones (a shortest screen side under 600 logical pixels) and
  /// [TouchMode.direct] otherwise. A stylus always works directly.
  final TouchMode? touchMode;

  /// Whether to capture keys. If false, the widget never takes focus.
  final bool enableKeyboard;

  /// Whether to take focus when first built.
  final bool autofocus;

  /// The focus node for keys; one is created if `null`.
  final FocusNode? focusNode;

  /// A shortcut that gives up keyboard focus, so the person can reach the
  /// rest of the app with the keyboard. Its modifier keys reach the host
  /// before it fires, and are released with everything else when focus
  /// goes.
  final ShortcutActivator? releaseShortcut;

  /// Whether pinching zooms and pans the local view (on touch screens). The
  /// zoom is never sent; points are mapped through it.
  final bool allowZoom;

  /// Builds the cursor drawn in [TouchMode.trackpad]. Its top-left corner
  /// is the hotspot. The default is an arrow, outlined so it shows over any
  /// picture.
  final WidgetBuilder? cursorBuilder;

  /// Connects this capture with a [RemoteKeyBar] and the app.
  final RemoteInputCaptureController? controller;

  /// How far the cursor moves in [TouchMode.trackpad], relative to the
  /// finger, across the picture as shown. Fast swipes move it up to twice
  /// as far again.
  final double trackpadSpeed;

  /// Builds an overlay over the picture for the viewer's session state, for
  /// example a dimmed layer while it isn't active. `null` (the default), or
  /// a builder that returns `null`, shows nothing.
  final Widget? Function(BuildContext context, SessionState state)?
  overlayBuilder;

  /// The content rect for a widget of [viewport] size showing a picture of
  /// [content] size with [fit], centred: what [RemoteInputCapture] maps
  /// points into.
  static Rect computeContentRect(Size viewport, Size? content, BoxFit fit) =>
      contentRectFor(viewport, content, fit);

  @override
  State<RemoteInputCapture> createState() => _RemoteInputCaptureState();
}

enum _TouchPhase { idle, pending, cursor, drag, two, scroll, pinch, done }

final class _Finger {
  _Finger(this.start, this.time, this.stamp) : last = start;

  final Offset start;
  final DateTime time;
  Offset last;
  Duration stamp;
}

/// Takes every pointer that lands on the capture while it's active, so
/// ancestors (scroll views, taps) don't also act on them.
final class _ClaimRecognizer extends OneSequenceGestureRecognizer {
  _ClaimRecognizer({required this.isEnabled});

  final bool Function() isEnabled;

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      isEnabled() && super.isPointerAllowed(event);

  @override
  bool isPointerPanZoomAllowed(PointerPanZoomStartEvent event) =>
      isEnabled() && super.isPointerPanZoomAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    resolve(GestureDisposition.accepted);
  }

  @override
  void addAllowedPointerPanZoom(PointerPanZoomStartEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    resolve(GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent ||
        event is PointerCancelEvent ||
        event is PointerPanZoomEndEvent) {
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'remote input capture';
}

class _RemoteInputCaptureState extends State<RemoteInputCapture>
    with WidgetsBindingObserver
    implements CaptureTextSink {
  // Timing and distances. The double-click interval is Windows' default
  // and close to macOS's; the slops are a few pixels for a mouse and
  // finger-sized for touch.
  static const Duration _doubleClickInterval = Duration(milliseconds: 500);
  static const double _mouseClickSlop = 6;
  static const double _directTapSlop = 2 * kTouchSlop;
  static const double _pinchSlop = 24;
  static const double _maxZoom = 8;
  static const Duration _wheelInterval = Duration(milliseconds: 33);
  static const int _mouseButtons =
      kPrimaryMouseButton |
      kSecondaryMouseButton |
      kMiddleMouseButton |
      kBackMouseButton |
      kForwardMouseButton;

  FocusNode? _ownFocusNode;
  RemoteInputCaptureController? _ownController;
  late final CaptureTextInput _text = CaptureTextInput(this);
  StreamSubscription<SessionState>? _stateSubscription;
  StreamSubscription<RemoteSurface?>? _surfaceSubscription;
  RemoteInputCaptureController? _attachedController;

  SessionState _state = const SessionWaiting();
  bool _active = false;
  String _composing = '';
  double _lastBottomInset = 0;
  bool _holdsContextMenu = false;

  // Keys: what this capture holds on the host.
  final Set<int> _hostModifiers = {};
  final Set<int> _physicalDown = {};

  // Mouse. Ignored buttons are held locally but not on the host (pressed
  // on the letterbox, or held through a release), until they're let go.
  int _remoteButtons = 0;
  int _ignoredButtons = 0;
  int? _mouseDevice;
  Offset _lastMousePoint = Offset.zero;
  final Map<PointerButton, int> _clickCounts = {};
  PointerButton? _lastClickButton;
  DateTime? _lastClickTime;
  Offset _lastClickPosition = Offset.zero;
  Offset? _panZoomPoint;

  // Wheel coalescing.
  Offset _wheelPending = Offset.zero;
  Offset _wheelPoint = Offset.zero;
  Timer? _wheelTimer;
  DateTime? _lastWheelSent;

  // Touch.
  final Map<int, _Finger> _fingers = {};
  _TouchPhase _phase = _TouchPhase.idle;
  // The finger that started the gesture: only it drives a one-finger drag.
  int? _driver;
  bool _touchDirect = false;
  bool _secondTap = false;
  int _tapCount = 0;
  DateTime? _lastTapTime;
  Offset _lastTapPosition = Offset.zero;
  Timer? _longPressTimer;
  Offset _twoStartCentroid = Offset.zero;
  Offset _twoLastCentroid = Offset.zero;
  double _twoStartSpan = 0;
  DateTime _twoStartTime = DateTime.fromMillisecondsSinceEpoch(0);
  Offset _twoWheelPoint = Offset.zero;
  ViewZoom _pinchStartZoom = ViewZoom.identity;

  // The local zoom and the trackpad cursor (normalized).
  final ValueNotifier<ViewZoom> _zoom = ValueNotifier(ViewZoom.identity);
  final ValueNotifier<Offset> _cursor = ValueNotifier(const Offset(0.5, 0.5));
  final ValueNotifier<bool> _cursorShown = ValueNotifier(true);
  late final Listenable _cursorLayer = Listenable.merge([
    _zoom,
    _cursor,
    _cursorShown,
  ]);

  FocusNode get _focusNode =>
      widget.focusNode ??
      (_ownFocusNode ??= FocusNode(debugLabel: 'RemoteInputCapture'));

  RemoteInputCaptureController get _controller =>
      widget.controller ?? (_ownController ??= RemoteInputCaptureController());

  bool get _softKeyboardPlatform =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  TouchMode get _touchMode {
    final mode = widget.touchMode;
    if (mode != null) return mode;
    final size = MediaQuery.maybeSizeOf(context);
    return size != null && size.shortestSide < 600
        ? TouchMode.trackpad
        : TouchMode.direct;
  }

  int get _hostModifierBits => modifierBitsOf(_hostModifiers);

  int get _bits => _hostModifierBits | _controller.stickyModifierBits;

  RemoteInputViewer get _viewer => widget.viewer;

  // --- Lifecycle ----------------------------------------------------------

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointer);
    _attachController();
    _subscribe();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _checkSoftKeyboard();
  }

  @override
  void didChangeMetrics() => _checkSoftKeyboard();

  /// Notices a soft keyboard the person dismissed (Android's back button,
  /// iOS's hide key), which leaves the request standing. Reads the view's
  /// own insets: a [Scaffold] removes them from the [MediaQuery] its body
  /// sees.
  void _checkSoftKeyboard() {
    if (!mounted) return;
    final bottom = View.maybeOf(context)?.viewInsets.bottom ?? 0;
    if (_softKeyboardPlatform &&
        _controller._keyboardRequested &&
        _lastBottomInset > 0 &&
        bottom == 0) {
      _controller._keyboardRequested = false;
      _updateTextInput();
      _controller._notify();
    }
    _lastBottomInset = bottom;
  }

  /// When another window or app takes the keyboard (Alt+Tab, Cmd+Tab, a
  /// tablet's app switcher), the key-ups don't come here: release
  /// everything. On desktops and the web, Flutter's focus manager also
  /// takes focus away while the app is inactive, which releases it too; on
  /// iPhone and iPad it doesn't. On Android, `inactive` alone is ignored:
  /// some soft keyboards flicker the app through it while typing (which is
  /// why Flutter's focus manager ignores it there too), and a release then
  /// would drop latched sticky modifiers. Hidden or paused releases.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        break;
      case AppLifecycleState.inactive:
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) break;
        _releaseEverything(send: true);
      case AppLifecycleState.hidden ||
          AppLifecycleState.paused ||
          AppLifecycleState.detached:
        _releaseEverything(send: true);
    }
  }

  @override
  void didUpdateWidget(RemoteInputCapture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.viewer, widget.viewer)) {
      _releaseEverything(send: true, viewer: oldWidget.viewer);
      _unsubscribe();
      _subscribe();
      _updateTextInput();
    }
    if (oldWidget.controller != widget.controller) _attachController();
    if (oldWidget.focusNode != widget.focusNode && widget.focusNode != null) {
      // The Focus widget lets go of it in this build: dispose it after.
      final old = _ownFocusNode;
      _ownFocusNode = null;
      if (old != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
    }
    if (oldWidget.keyboardMode != widget.keyboardMode ||
        oldWidget.enableKeyboard != widget.enableKeyboard) {
      if (!widget.enableKeyboard && _focusNode.hasFocus) _focusNode.unfocus();
      _updateTextInput();
    }
    if (!widget.allowZoom && !_zoom.value.isIdentity) {
      _zoom.value = ViewZoom.identity;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
    _releaseEverything(send: true);
    _text.detach();
    _unsubscribe();
    _syncContextMenu(hold: false);
    _wheelTimer?.cancel();
    _longPressTimer?.cancel();
    if (_attachedController?._capture == this) {
      _attachedController!._capture = null;
    }
    _ownController?.dispose();
    _ownFocusNode?.dispose();
    _zoom.dispose();
    _cursor.dispose();
    _cursorShown.dispose();
    super.dispose();
  }

  void _attachController() {
    final old = _attachedController;
    if (old != null && old._capture == this) old._capture = null;
    final controller = _controller;
    controller._capture = this;
    controller._viewer = widget.viewer;
    _attachedController = controller;
  }

  void _subscribe() {
    _controller._viewer = widget.viewer;
    _state = widget.viewer.state;
    _active = _state.isActive;
    _stateSubscription = widget.viewer.stateChanges.listen(_onState);
    _surfaceSubscription = widget.viewer.surfaceChanges.listen((_) {
      if (mounted) setState(() {});
    });
    _syncContextMenu(hold: _active);
  }

  /// Keeps the browser's context menu off while this capture is active.
  void _syncContextMenu({required bool hold}) {
    if (hold == _holdsContextMenu) return;
    _holdsContextMenu = hold;
    hold ? CaptureContextMenu.acquire() : CaptureContextMenu.release();
  }

  void _unsubscribe() {
    _stateSubscription?.cancel();
    _surfaceSubscription?.cancel();
    _stateSubscription = null;
    _surfaceSubscription = null;
  }

  void _onState(SessionState state) {
    if (!mounted) return;
    final wasActive = _active;
    _active = state.isActive;
    // The host releases everything when it stops being active.
    if (wasActive && !_active) _releaseEverything(send: false);
    if (wasActive != _active) _updateTextInput();
    _syncContextMenu(hold: _active);
    setState(() => _state = state);
  }

  /// Forgets everything held on the host; with [send], tells the host to
  /// release it too.
  void _releaseEverything({required bool send, RemoteInputViewer? viewer}) {
    final hadInput =
        _hostModifiers.isNotEmpty ||
        _physicalDown.isNotEmpty ||
        _remoteButtons != 0 ||
        _phase == _TouchPhase.drag ||
        _controller.stickyModifierBits != 0;
    _hostModifiers.clear();
    _physicalDown.clear();
    // Buttons still held here aren't pressed again until they're let go
    // (keys held through a release aren't either: their repeats and
    // releases find nothing held).
    _ignoredButtons |= _remoteButtons;
    _remoteButtons = 0;
    _panZoomPoint = null;
    _wheelTimer?.cancel();
    _wheelTimer = null;
    _wheelPending = Offset.zero;
    _longPressTimer?.cancel();
    _longPressTimer = null;
    if (_phase != _TouchPhase.idle) {
      _phase = _fingers.isEmpty ? _TouchPhase.idle : _TouchPhase.done;
    }
    _controller._forgetSticky();
    if (send && hadInput) (viewer ?? _viewer).releaseAll();
  }

  // --- Focus and text input ----------------------------------------------

  void _onFocusChange(bool focused) {
    if (!focused) _releaseEverything(send: true);
    _updateTextInput();
    _controller._notify();
  }

  void _onKeyboardRequestChanged({required bool focus}) {
    if (focus && widget.enableKeyboard && !_focusNode.hasFocus) {
      _focusNode.requestFocus(); // _onFocusChange updates the text input.
      return;
    }
    _updateTextInput();
  }

  /// Opens or closes the text input connection to match the focus, the
  /// session state, the keyboard mode and the soft keyboard request.
  void _updateTextInput() {
    if (!mounted) return;
    final wanted =
        widget.enableKeyboard &&
        _active &&
        _focusNode.hasFocus &&
        (_softKeyboardPlatform
            ? _controller._keyboardRequested
            : widget.keyboardMode != KeyboardMode.physical);
    if (!wanted) {
      if (_text.isAttached) _text.detach();
      return;
    }
    if (_text.isAttached) return;
    _text
      ..attach(_textConfiguration())
      ..show();
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateTextGeometry());
  }

  TextInputConfiguration _textConfiguration() => TextInputConfiguration(
    viewId: View.maybeOf(context)?.viewId,
    inputType: TextInputType.multiline,
    inputAction: TextInputAction.newline,
    autocorrect: false,
    enableSuggestions: false,
    enableIMEPersonalizedLearning: false,
    enableInlinePrediction: false,
    enableInteractiveSelection: false,
    smartDashesType: SmartDashesType.disabled,
    smartQuotesType: SmartQuotesType.disabled,
    enableDeltaModel: true,
    keyboardAppearance: Theme.of(context).brightness,
  );

  /// Tells the platform where the composing text shows, so IME candidate
  /// windows open next to it.
  void _updateTextGeometry() {
    if (!mounted || !_text.isAttached) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final size = box.size;
    final caret = Rect.fromLTWH(size.width / 2, size.height - 44, 2, 24);
    _text.setGeometry(size, box.getTransformTo(null), caret);
  }

  @override
  void commitText(String text) {
    const command = KeyModifiers.control | KeyModifiers.alt | KeyModifiers.meta;
    if (_controller.stickyModifierBits & command != 0) {
      _typeAsKeys(text);
    } else {
      _viewer.text(text);
    }
    _afterInput();
  }

  @override
  void pressKey(int usage) {
    _viewer
      ..key(usage, KeyAction.down, modifiers: _bits)
      ..key(usage, KeyAction.up, modifiers: _bits);
    _afterInput();
  }

  @override
  void composingChanged(String composing) {
    if (!mounted || composing == _composing) return;
    setState(() => _composing = composing);
  }

  @override
  void textInputClosed() {
    if (!mounted) return;
    if (_controller._keyboardRequested) {
      _controller._keyboardRequested = false;
      _controller._notify();
    }
    setState(() => _composing = '');
  }

  /// Types [text] as US-layout keys, for a sticky Ctrl, Alt or Meta: so
  /// sticky Ctrl then "c" on a soft keyboard is Ctrl+C.
  void _typeAsKeys(String text) {
    for (final character in text.characters) {
      final key = usKeyForCharacter(character);
      if (key == null) {
        _viewer.text(character);
        continue;
      }
      final (usage, shift) = key;
      final addShift = shift && _bits & KeyModifiers.shift == 0;
      if (addShift) {
        _viewer.key(
          HidModifier.shiftLeft,
          KeyAction.down,
          modifiers: _bits | KeyModifiers.shift,
        );
      }
      final bits = _bits | (addShift ? KeyModifiers.shift : 0);
      _viewer
        ..key(usage, KeyAction.down, modifiers: bits)
        ..key(usage, KeyAction.up, modifiers: bits);
      if (addShift) {
        _viewer.key(HidModifier.shiftLeft, KeyAction.up, modifiers: _bits);
      }
    }
  }

  /// After a key, a click or text: latched sticky modifiers are used up.
  void _afterInput() => _controller._consumeOneShot();

  /// Before a pointer press goes to the host: text being composed is
  /// committed where the host's caret is now (as a click ends a
  /// composition locally), and the buffer starts afresh, since the click
  /// may move the caret.
  void _beforePress() {
    _flushWheel();
    _text
      ..finishComposing()
      ..resetBuffer();
  }

  // --- Keys ---------------------------------------------------------------

  int _viewerModifierBits() {
    final k = HardwareKeyboard.instance;
    return (k.isShiftPressed ? KeyModifiers.shift : 0) |
        (k.isControlPressed ? KeyModifiers.control : 0) |
        (k.isAltPressed ? KeyModifiers.alt : 0) |
        (k.isMetaPressed ? KeyModifiers.meta : 0);
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final release = widget.releaseShortcut;
    if (release != null &&
        event is KeyDownEvent &&
        release.accepts(event, HardwareKeyboard.instance)) {
      node.unfocus();
      return KeyEventResult.handled;
    }
    if (!widget.enableKeyboard || !_active) return KeyEventResult.ignored;
    final physicalMode = widget.keyboardMode == KeyboardMode.physical;
    final usage = event.physicalKey.usbHidUsage;

    if (event is KeyUpEvent) {
      if (_hostModifiers.remove(usage) || _physicalDown.remove(usage)) {
        _viewer.key(usage, KeyAction.up, modifiers: _bits);
        return KeyEventResult.handled;
      }
      return physicalMode
          ? KeyEventResult.handled
          : KeyEventResult.skipRemainingHandlers;
    }
    if (event is KeyRepeatEvent &&
        (_physicalDown.contains(usage) || _hostModifiers.contains(usage))) {
      _viewer.key(usage, KeyAction.repeat, modifiers: _bits);
      return KeyEventResult.handled;
    }

    final route = routeKeyDown(
      mode: widget.keyboardMode,
      usage: usage,
      character: event.character,
      modifiers: _viewerModifierBits() | _controller.stickyModifierBits,
      composing: _text.isComposing,
      processKey: event.logicalKey == LogicalKeyboardKey.process,
      altGr: ctrlAltIsAltGr(defaultTargetPlatform),
    );
    switch (route) {
      case KeyRoute.physical:
        // A repeat whose press didn't go physically (it was composing)
        // doesn't start a press now.
        if (event is KeyRepeatEvent) return KeyEventResult.handled;
        if (HidModifier.isModifier(usage)) {
          _hostModifiers.add(usage);
          _viewer.key(usage, KeyAction.down, modifiers: _bits);
          return KeyEventResult.handled;
        }
        _pressHeldModifiers();
        _physicalDown.add(usage);
        _flushWheel();
        _viewer.key(usage, KeyAction.down, modifiers: _bits);
        _text.resetBuffer();
        _afterInput();
        return KeyEventResult.handled;
      case KeyRoute.text:
        _liftCommandModifiers();
        if (_text.isShown) return KeyEventResult.skipRemainingHandlers;
        // No text input to deliver it: send the key's own character.
        final character = event.character;
        if (isPrintableCharacter(character)) commitText(character!);
        return KeyEventResult.handled;
      case KeyRoute.platform:
        return KeyEventResult.skipRemainingHandlers;
    }
  }

  /// Presses on the host the modifiers the viewer holds but the host
  /// doesn't (lifted for an AltGr or Option character, or held before
  /// focus), so a shortcut arrives whole.
  void _pressHeldModifiers() {
    for (final key in HardwareKeyboard.instance.physicalKeysPressed) {
      final usage = key.usbHidUsage;
      if (!HidModifier.isModifier(usage) || _hostModifiers.contains(usage)) {
        continue;
      }
      _hostModifiers.add(usage);
      _viewer.key(usage, KeyAction.down, modifiers: _bits);
    }
  }

  /// Releases Ctrl, Alt and Meta on the host before a character typed with
  /// them goes by text (AltGr, Option), so the host doesn't see a shortcut.
  /// Shift stays: it's part of typing.
  void _liftCommandModifiers() {
    const command = KeyModifiers.control | KeyModifiers.alt | KeyModifiers.meta;
    if (_hostModifierBits & command == 0) return;
    for (final usage in _hostModifiers.toList()) {
      if (HidModifier.bitOf(usage) & command == 0) continue;
      _hostModifiers.remove(usage);
      _viewer.key(usage, KeyAction.up, modifiers: _bits);
    }
  }

  // --- Geometry -------------------------------------------------------------

  Size get _size {
    final box = context.findRenderObject();
    return box is RenderBox && box.hasSize ? box.size : Size.zero;
  }

  Rect _contentRectFor(Size size) =>
      widget.contentRect ??
      contentRectFor(
        size,
        widget.contentSize ?? _viewer.surface?.pixelSize,
        widget.fit,
      );

  /// Maps a widget point to normalized picture coordinates, through the
  /// zoom. Not clamped.
  Offset _normalize(Offset local) =>
      normalizeIn(_contentRectFor(_size), _zoom.value.toChild(local));

  // --- Pointer dispatch ---------------------------------------------------

  void _onPointerDown(PointerDownEvent event) {
    if (widget.enableKeyboard && !_focusNode.hasFocus) {
      _focusNode.requestFocus();
    }
    if (!_active) return _forgetReleasedButtons(event);
    switch (event.kind) {
      case PointerDeviceKind.touch:
        _touchDown(event, direct: _touchMode == TouchMode.direct);
      case PointerDeviceKind.stylus || PointerDeviceKind.invertedStylus:
        _touchDown(event, direct: true);
      case PointerDeviceKind.mouse ||
          PointerDeviceKind.trackpad ||
          PointerDeviceKind.unknown:
        _mouseEvent(event);
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_active) return _forgetReleasedButtons(event);
    if (_fingers.containsKey(event.pointer)) {
      _touchMove(event);
    } else if (!_isTouchKind(event.kind)) {
      _mouseEvent(event);
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_fingers.containsKey(event.pointer)) {
      _touchUp(event);
    } else if (!_isTouchKind(event.kind)) {
      _active ? _mouseEvent(event) : _forgetReleasedButtons(event);
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (_fingers.containsKey(event.pointer)) {
      _cancelFinger(event.pointer);
    } else if (!_isTouchKind(event.kind)) {
      _active ? _mouseEvent(event) : _forgetReleasedButtons(event);
    }
  }

  void _onPointerHover(PointerHoverEvent event) {
    if (!_active) return _forgetReleasedButtons(event);
    if (_isTouchKind(event.kind)) {
      _stylusHover(event);
    } else {
      _mouseEvent(event);
    }
  }

  /// A device that leaves (a pen out of range, a mouse unplugged) lets go of
  /// whatever it held. The [Listener] doesn't see removals, so this is a
  /// global route; it ignores every other event.
  void _onGlobalPointer(PointerEvent event) {
    if (event is! PointerRemovedEvent) return;
    if (_fingers.containsKey(event.pointer)) _cancelFinger(event.pointer);
    if (_remoteButtons != 0 && event.device == _mouseDevice) {
      _releaseMouseButtons(_remoteButtons, _lastMousePoint);
    }
    if (!_isTouchKind(event.kind)) _ignoredButtons = 0;
  }

  /// While the capture is passive, buttons let go stop being ignored, so
  /// the next press after a release is sent.
  void _forgetReleasedButtons(PointerEvent event) {
    if (!_isTouchKind(event.kind)) _ignoredButtons &= _pressedButtons(event);
  }

  static int _pressedButtons(PointerEvent event) =>
      event is PointerUpEvent || event is PointerCancelEvent
      ? 0
      : event.buttons & _mouseButtons;

  /// A hovering pen moves the pointer and nothing else: its barrel button
  /// (which Flutter reports as the secondary button) doesn't press a mouse
  /// button, and a pen hovering while a gesture is under way isn't sent.
  void _stylusHover(PointerHoverEvent event) {
    if (_phase != _TouchPhase.idle || _remoteButtons != 0) return;
    final n = _normalize(event.localPosition);
    if (!isInsideUnit(n)) return;
    _viewer.pointerMove(n);
    _cursor.value = n;
  }

  static bool _isTouchKind(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.touch ||
      kind == PointerDeviceKind.stylus ||
      kind == PointerDeviceKind.invertedStylus;

  // --- Mouse ---------------------------------------------------------------

  static PointerButton? _buttonFor(int bit) => switch (bit) {
    kPrimaryMouseButton => PointerButton.left,
    kSecondaryMouseButton => PointerButton.right,
    kMiddleMouseButton => PointerButton.middle,
    kBackMouseButton => PointerButton.back,
    kForwardMouseButton => PointerButton.forward,
    _ => null,
  };

  void _mouseEvent(PointerEvent event) {
    final n = _normalize(event.localPosition);
    final inside = isInsideUnit(n);
    final clamped = clampToUnit(n);
    final pressed = _pressedButtons(event);
    _ignoredButtons &= pressed;
    final released = _remoteButtons & ~pressed;
    final added = pressed & ~_remoteButtons & ~_ignoredButtons;

    if (released != 0) _releaseMouseButtons(released, clamped);
    if (added != 0) {
      if (_remoteButtons == 0 && !inside) {
        // Pressed on the letterbox: not for the host.
        _ignoredButtons |= added;
      } else {
        _beforePress();
        _mouseDevice = event.device;
        for (var bit = 1; bit <= added; bit <<= 1) {
          final button = _buttonFor(added & bit);
          if (button == null) continue;
          final count = _countClick(button, event.localPosition);
          _clickCounts[button] = count;
          _viewer.pointerButton(clamped, button, down: true, clickCount: count);
          _remoteButtons |= bit;
        }
      }
    }
    if (released == 0 &&
        added == 0 &&
        (event is PointerMoveEvent || event is PointerHoverEvent)) {
      if (_remoteButtons != 0) {
        _viewer.pointerMove(clamped);
      } else if (inside && _ignoredButtons == 0) {
        // A press that began on the letterbox is the app's, moves and all.
        _viewer.pointerMove(n);
      }
    }
    if (inside || _remoteButtons != 0) {
      _cursor.value = clamped;
      _lastMousePoint = clamped;
    }
    _cursorShown.value = false;
  }

  /// Releases the [buttons] held on the host, at [point].
  void _releaseMouseButtons(int buttons, Offset point) {
    _flushWheel();
    for (var bit = 1; bit <= buttons; bit <<= 1) {
      final button = _buttonFor(buttons & bit);
      if (button == null) continue;
      _viewer.pointerButton(
        point,
        button,
        down: false,
        clickCount: _clickCounts[button] ?? 1,
      );
    }
    _remoteButtons &= ~buttons;
    if (_remoteButtons == 0) _afterInput();
  }

  int _countClick(PointerButton button, Offset position) {
    final now = clock.now();
    final last = _lastClickTime;
    final count =
        button == _lastClickButton &&
            last != null &&
            now.difference(last) <= _doubleClickInterval &&
            (position - _lastClickPosition).distance <= _mouseClickSlop
        ? (_clickCounts[button] ?? 1) + 1
        : 1;
    _lastClickButton = button;
    _lastClickTime = now;
    _lastClickPosition = position;
    return count;
  }

  // --- Wheel ---------------------------------------------------------------

  void _onPointerSignal(PointerSignalEvent event) {
    if (!_active || event is! PointerScrollEvent) return;
    final n = _normalize(event.localPosition);
    if (!isInsideUnit(n)) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      _queueWheel(n, (e as PointerScrollEvent).scrollDelta);
    });
  }

  void _onPanZoomStart(PointerPanZoomStartEvent event) {
    if (!_active) return;
    final n = _normalize(event.localPosition);
    _panZoomPoint = isInsideUnit(n) ? n : null;
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    final point = _panZoomPoint;
    // Fingers moving up move the content up, revealing what's below: a
    // positive wheel delta. The scale is ignored.
    if (point != null && _active) _queueWheel(point, -event.panDelta);
  }

  void _onPanZoomEnd(PointerPanZoomEndEvent event) {
    if (_panZoomPoint == null) return;
    _panZoomPoint = null;
    _flushWheel();
  }

  /// Adds a wheel delta, in pixels, sent at most every [_wheelInterval] so
  /// trackpads and touch scrolls stay inside the host's event rate.
  void _queueWheel(Offset point, Offset delta) {
    _wheelPoint = point;
    _wheelPending += delta;
    if (_wheelTimer != null) return;
    final now = clock.now();
    final last = _lastWheelSent;
    if (last == null || now.difference(last) >= _wheelInterval) {
      _flushWheel();
    } else {
      _wheelTimer = Timer(_wheelInterval - now.difference(last), () {
        _wheelTimer = null;
        _flushWheel();
      });
    }
  }

  void _flushWheel() {
    _wheelTimer?.cancel();
    _wheelTimer = null;
    final d = _wheelPending;
    final dx = d.dx.truncate();
    final dy = d.dy.truncate();
    if (dx == 0 && dy == 0) return;
    // Keep the fractions for the next send.
    _wheelPending = Offset(d.dx - dx, d.dy - dy);
    _viewer.wheel(_wheelPoint, dx: dx.toDouble(), dy: dy.toDouble());
    _lastWheelSent = clock.now();
  }

  // --- Touch ---------------------------------------------------------------

  void _touchDown(PointerDownEvent event, {required bool direct}) {
    final now = clock.now();
    _fingers[event.pointer] = _Finger(
      event.localPosition,
      now,
      event.timeStamp,
    );
    if (_fingers.length == 1) {
      _driver = event.pointer;
      _touchDirect = direct;
      _phase = _TouchPhase.pending;
      final lastTap = _lastTapTime;
      _secondTap =
          lastTap != null &&
          now.difference(lastTap) <= kDoubleTapTimeout &&
          (event.localPosition - _lastTapPosition).distance <=
              (direct ? _directTapSlop : kDoubleTapSlop);
      if (direct) {
        _longPressTimer?.cancel();
        _longPressTimer = Timer(kLongPressTimeout, _onLongPress);
      } else {
        _cursorShown.value = true;
      }
      return;
    }
    if (_fingers.length == 2 &&
        (_phase == _TouchPhase.pending || _phase == _TouchPhase.cursor)) {
      _longPressTimer?.cancel();
      _longPressTimer = null;
      final (centroid, span) = _twoFingers();
      _phase = _TouchPhase.two;
      _twoStartCentroid = centroid;
      _twoLastCentroid = centroid;
      _twoStartSpan = span;
      _twoStartTime = now;
      _secondTap = false;
    }
  }

  void _onLongPress() {
    _longPressTimer = null;
    if (!mounted || _phase != _TouchPhase.pending || _fingers.length != 1) {
      return;
    }
    _phase = _TouchPhase.done;
    final n = _normalize(_fingers.values.first.start);
    if (!_active || !isInsideUnit(n)) return;
    _beforePress();
    _viewer.click(n, button: PointerButton.right);
    _lastTapTime = null;
    _afterInput();
  }

  void _touchMove(PointerMoveEvent event) {
    final finger = _fingers[event.pointer];
    if (finger == null) return;
    final previous = finger.last;
    final previousStamp = finger.stamp;
    finger
      ..last = event.localPosition
      ..stamp = event.timeStamp;
    switch (_phase) {
      case _TouchPhase.pending:
        if ((finger.last - finger.start).distance <= kTouchSlop) return;
        _longPressTimer?.cancel();
        _longPressTimer = null;
        _flushWheel();
        if (_touchDirect) {
          final start = _normalize(finger.start);
          if (!isInsideUnit(start)) {
            _phase = _TouchPhase.done;
            return;
          }
          _beforePress();
          _viewer.pointerButton(start, PointerButton.left, down: true);
          _phase = _TouchPhase.drag;
          _viewer.pointerMove(clampToUnit(_normalize(finger.last)));
        } else {
          if (_secondTap) {
            _beforePress();
            _viewer.pointerButton(
              _cursor.value,
              PointerButton.left,
              down: true,
            );
            _phase = _TouchPhase.drag;
          } else {
            _phase = _TouchPhase.cursor;
          }
          _moveCursor(finger.last - finger.start, Duration.zero);
        }
      case _TouchPhase.cursor:
        _moveCursor(finger.last - previous, finger.stamp - previousStamp);
      case _TouchPhase.drag:
        // Another finger that lands during a drag doesn't take it over.
        if (event.pointer != _driver) return;
        if (_touchDirect) {
          _viewer.pointerMove(clampToUnit(_normalize(finger.last)));
        } else {
          _moveCursor(finger.last - previous, finger.stamp - previousStamp);
        }
      case _TouchPhase.two:
        _classifyTwoFingers();
      case _TouchPhase.scroll:
        _scrollTwoFingers();
      case _TouchPhase.pinch:
        _pinchTwoFingers();
      case _TouchPhase.idle || _TouchPhase.done:
        break;
    }
  }

  void _touchUp(PointerUpEvent event) {
    final finger = _fingers.remove(event.pointer);
    if (finger == null) return;
    final now = clock.now();
    switch (_phase) {
      case _TouchPhase.pending:
        _longPressTimer?.cancel();
        _longPressTimer = null;
        _phase = _TouchPhase.idle;
        if (_active && now.difference(finger.time) <= kLongPressTimeout) {
          _tap(finger, now);
        }
      case _TouchPhase.cursor:
        _phase = _TouchPhase.idle;
        _lastTapTime = null;
      case _TouchPhase.drag:
        // A stray finger lifting doesn't end the drag; the driving finger
        // lifting does, and the rest of the gesture is ignored.
        if (event.pointer != _driver) break;
        _phase = _fingers.isEmpty ? _TouchPhase.idle : _TouchPhase.done;
        _endDrag(finger.last);
      case _TouchPhase.two:
        _phase = _TouchPhase.done;
        if (_active && now.difference(_twoStartTime) <= kLongPressTimeout) {
          // A two-finger tap: a right click.
          final point = _touchDirect
              ? clampToUnit(_normalize(_twoStartCentroid))
              : _cursor.value;
          _beforePress();
          _viewer.click(point, button: PointerButton.right);
          _lastTapTime = null;
          _afterInput();
        }
      case _TouchPhase.scroll || _TouchPhase.pinch:
        _phase = _TouchPhase.done;
        _flushWheel();
      case _TouchPhase.idle || _TouchPhase.done:
        break;
    }
    if (_fingers.isEmpty) {
      if (_phase == _TouchPhase.done) _phase = _TouchPhase.idle;
      _wheelPending = Offset.zero;
    }
  }

  /// A finger cancelled, or a pen removed while down.
  void _cancelFinger(int pointer) {
    final finger = _fingers.remove(pointer);
    if (finger == null) return;
    if (_phase == _TouchPhase.drag && pointer != _driver) return;
    _longPressTimer?.cancel();
    _longPressTimer = null;
    if (_phase == _TouchPhase.drag) _endDrag(finger.last);
    _phase = _fingers.isEmpty ? _TouchPhase.idle : _TouchPhase.done;
  }

  void _tap(_Finger finger, DateTime now) {
    final Offset point;
    if (_touchDirect) {
      final n = _normalize(finger.start);
      if (!isInsideUnit(n)) return;
      point = n;
    } else {
      point = _cursor.value;
    }
    final count = _secondTap ? _tapCount + 1 : 1;
    _beforePress();
    _viewer.click(point, clickCount: count);
    _tapCount = count;
    _lastTapTime = now;
    _lastTapPosition = finger.last;
    _afterInput();
  }

  void _endDrag(Offset last) {
    final point = _touchDirect ? clampToUnit(_normalize(last)) : _cursor.value;
    _viewer.pointerButton(point, PointerButton.left, down: false);
    _lastTapTime = null;
    _afterInput();
  }

  /// Moves the trackpad cursor by a finger's [delta], scaled to the
  /// picture's size on screen, faster for fast swipes ([elapsed] since the
  /// finger's last event; zero when unknown).
  void _moveCursor(Offset delta, Duration elapsed) {
    final size = _size;
    final rect = _contentRectFor(size);
    final zoom = _zoom.value;
    final width = rect.width * zoom.scale;
    final height = rect.height * zoom.scale;
    if (width <= 0 || height <= 0) return;
    var gain = widget.trackpadSpeed;
    final ms = elapsed.inMicroseconds / 1000;
    if (ms > 0) {
      final speed = delta.distance / ms; // logical pixels per millisecond
      gain *= 1 + ((speed - 0.4) / 1.6).clamp(0.0, 1.0);
    }
    final c = _cursor.value;
    _cursor.value = Offset(
      (c.dx + delta.dx * gain / width).clamp(0.0, 1.0),
      (c.dy + delta.dy * gain / height).clamp(0.0, 1.0),
    );
    _followCursor(size, rect);
    _viewer.pointerMove(_cursor.value);
  }

  /// When zoomed in, pans the view to keep the cursor on screen.
  void _followCursor(Size size, Rect rect) {
    final zoom = _zoom.value;
    if (zoom.scale == 1) return;
    final c = _cursor.value;
    final p = zoom.toWidget(
      Offset(rect.left + c.dx * rect.width, rect.top + c.dy * rect.height),
    );
    const margin = 32.0;
    double shift(double v, double extent) => v < margin
        ? margin - v
        : v > extent - margin
        ? extent - margin - v
        : 0;
    final dx = shift(p.dx, size.width);
    final dy = shift(p.dy, size.height);
    if (dx == 0 && dy == 0) return;
    _zoom.value = ViewZoom(
      scale: zoom.scale,
      offset: zoom.offset + Offset(dx, dy),
    ).clampedTo(size);
  }

  (Offset centroid, double span) _twoFingers() {
    final it = _fingers.values.iterator..moveNext();
    final a = it.current.last;
    it.moveNext();
    final b = it.current.last;
    return ((a + b) / 2, (a - b).distance);
  }

  void _classifyTwoFingers() {
    final (centroid, span) = _twoFingers();
    final moved = (centroid - _twoStartCentroid).distance;
    final spread = (span - _twoStartSpan).abs();
    if (widget.allowZoom && spread > _pinchSlop && spread >= moved) {
      _phase = _TouchPhase.pinch;
      _pinchStartZoom = _zoom.value;
      _pinchTwoFingers();
    } else if (moved > kTouchSlop) {
      _phase = _TouchPhase.scroll;
      _twoWheelPoint = _touchDirect
          ? clampToUnit(_normalize(_twoStartCentroid))
          : _cursor.value;
      _scrollTwoFingers();
    }
  }

  void _scrollTwoFingers() {
    final (centroid, _) = _twoFingers();
    final delta = centroid - _twoLastCentroid;
    _twoLastCentroid = centroid;
    // Content follows the fingers: moving them up reveals what's below.
    _queueWheel(_twoWheelPoint, -delta);
  }

  void _pinchTwoFingers() {
    final (centroid, span) = _twoFingers();
    if (_twoStartSpan <= 0) return;
    final start = _pinchStartZoom;
    final scale = (start.scale * span / _twoStartSpan).clamp(1.0, _maxZoom);
    // Keep the point under the fingers' starting centroid under their
    // centroid now.
    final focal = start.toChild(_twoStartCentroid);
    _zoom.value = ViewZoom(
      scale: scale,
      offset: centroid - focal * scale,
    ).clampedTo(_size);
  }

  // --- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final overlay = widget.overlayBuilder?.call(context, _state);
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus && widget.enableKeyboard,
      canRequestFocus: widget.enableKeyboard,
      onKeyEvent: _onKeyEvent,
      onFocusChange: _onFocusChange,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerCancel,
        onPointerHover: _onPointerHover,
        onPointerSignal: _onPointerSignal,
        onPointerPanZoomStart: _onPanZoomStart,
        onPointerPanZoomUpdate: _onPanZoomUpdate,
        onPointerPanZoomEnd: _onPanZoomEnd,
        child: RawGestureDetector(
          gestures: {
            _ClaimRecognizer:
                GestureRecognizerFactoryWithHandlers<_ClaimRecognizer>(
                  () => _ClaimRecognizer(isEnabled: () => _active),
                  (_) {},
                ),
          },
          child: ClipRect(
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                ValueListenableBuilder<ViewZoom>(
                  valueListenable: _zoom,
                  builder: (context, zoom, child) => zoom.isIdentity
                      ? child!
                      : Transform(
                          transform:
                              Matrix4.diagonal3Values(zoom.scale, zoom.scale, 1)
                                ..setTranslationRaw(
                                  zoom.offset.dx,
                                  zoom.offset.dy,
                                  0,
                                ),
                          child: child,
                        ),
                  child: widget.child,
                ),
                if (_active && _touchMode == TouchMode.trackpad)
                  Positioned.fill(
                    child: IgnorePointer(child: _cursorLayerWidget()),
                  ),
                if (_composing.isNotEmpty)
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 16,
                    child: IgnorePointer(
                      child: Center(child: _ComposingBubble(text: _composing)),
                    ),
                  ),
                if (overlay != null) Positioned.fill(child: overlay),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _cursorLayerWidget() => LayoutBuilder(
    builder: (context, constraints) => ListenableBuilder(
      listenable: _cursorLayer,
      builder: (context, _) {
        if (!_cursorShown.value) return const SizedBox.shrink();
        final size = constraints.biggest;
        final rect = _contentRectFor(size);
        final c = _cursor.value;
        final p = _zoom.value.toWidget(
          Offset(rect.left + c.dx * rect.width, rect.top + c.dy * rect.height),
        );
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: p.dx,
              top: p.dy,
              child:
                  widget.cursorBuilder?.call(context) ??
                  const CustomPaint(
                    size: Size(14, 21),
                    painter: _ArrowCursorPainter(),
                  ),
            ),
          ],
        );
      },
    ),
  );
}

/// The default trackpad cursor: a white arrow with a dark outline, its tip
/// at the top-left corner.
final class _ArrowCursorPainter extends CustomPainter {
  const _ArrowCursorPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 14;
    final sy = size.height / 21;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(0, 17 * sy)
      ..lineTo(4 * sx, 13 * sy)
      ..lineTo(7 * sx, 20 * sy)
      ..lineTo(10 * sx, 19 * sy)
      ..lineTo(7 * sx, 12 * sy)
      ..lineTo(12.5 * sx, 12 * sy)
      ..close();
    canvas
      ..drawPath(path, Paint()..color = const Color(0xFFFFFFFF))
      ..drawPath(
        path,
        Paint()
          ..color = const Color(0xFF000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..strokeJoin = StrokeJoin.round,
      );
  }

  @override
  bool shouldRepaint(_ArrowCursorPainter oldDelegate) => false;
}

/// Text being composed, shown only on the viewer until it's committed.
class _ComposingBubble extends StatelessWidget {
  const _ComposingBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xE6202124),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 16,
          decoration: TextDecoration.underline,
          decorationColor: Color(0xFFFFFFFF),
        ),
      ),
    ),
  );
}
