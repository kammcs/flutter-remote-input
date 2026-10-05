part of 'capture.dart';

/// The state of a sticky modifier ([RemoteInputCaptureController]).
enum StickyModifierState {
  /// Not held.
  off,

  /// Held on the host until the next key, click or text, then released:
  /// a one-shot modifier for phones, whose keyboards have none.
  latched,

  /// Held on the host until it's turned off.
  locked,
}

/// Connects a [RemoteInputCapture] with a [RemoteKeyBar] and the app: the
/// soft keyboard, keyboard focus, and **sticky modifiers**.
///
/// Pass the same controller to both widgets. Sticky modifiers then apply
/// to keys typed on any keyboard, to the key bar's keys and to clicks, and
/// the key bar's keyboard button shows and hides the soft keyboard.
///
/// ```dart
/// final controller = RemoteInputCaptureController();
/// Column(children: [
///   Expanded(child: RemoteInputCapture(viewer: viewer, controller: controller, child: video)),
///   RemoteKeyBar(viewer: viewer, controller: controller),
/// ]);
/// ```
final class RemoteInputCaptureController extends ChangeNotifier {
  /// Creates a controller.
  RemoteInputCaptureController();

  _RemoteInputCaptureState? _capture;
  RemoteInputViewer? _viewer;
  bool _keyboardRequested = false;
  final Map<int, StickyModifierState> _sticky = {};
  bool _disposed = false;

  /// Whether a [RemoteInputCapture] uses this controller now.
  bool get isAttached => _capture != null;

  /// Whether the attached capture has keyboard focus.
  bool get hasFocus => _capture?._focusNode.hasFocus ?? false;

  /// Whether the soft keyboard has been asked for and not dismissed. On
  /// platforms without one (desktops, desktop browsers) it is still
  /// tracked, but showing it only focuses the capture.
  bool get isSoftKeyboardRequested => _keyboardRequested;

  /// Focuses the capture and raises the soft keyboard on phones and
  /// tablets. Text typed on it goes by text in every [KeyboardMode].
  void showSoftKeyboard() {
    _keyboardRequested = true;
    _capture?._onKeyboardRequestChanged(focus: true);
    _notify();
  }

  /// Lowers the soft keyboard. The capture keeps focus, so a hardware
  /// keyboard still works.
  void hideSoftKeyboard() {
    _keyboardRequested = false;
    _capture?._onKeyboardRequestChanged(focus: false);
    _notify();
  }

  /// Shows the soft keyboard if it's hidden, and hides it if it's shown.
  void toggleSoftKeyboard() =>
      _keyboardRequested ? hideSoftKeyboard() : showSoftKeyboard();

  /// Gives the capture keyboard focus.
  void requestFocus() => _capture?._focusNode.requestFocus();

  /// Takes keyboard focus from the capture. It releases everything it
  /// holds on the host.
  void unfocus() => _capture?._focusNode.unfocus();

  /// The state of sticky modifier [usage] (an [HidModifier] usage, as the
  /// viewer sends it).
  StickyModifierState stickyModifier(int usage) =>
      _sticky[usage] ?? StickyModifierState.off;

  /// The [KeyModifiers] bits of the sticky modifiers held now.
  int get stickyModifierBits => modifierBitsOf(_sticky.keys);

  /// Steps sticky modifier [usage] (an [HidModifier] usage) through off,
  /// latched (released after the next key, click or text), locked, and off
  /// again. It is pressed on the host when it leaves off, and released when
  /// it returns.
  void toggleStickyModifier(int usage) {
    if (!HidModifier.isModifier(usage)) {
      throw ArgumentError.value(usage, 'usage', 'is not a modifier key');
    }
    switch (stickyModifier(usage)) {
      case StickyModifierState.off:
        _sticky[usage] = StickyModifierState.latched;
        _viewer?.key(usage, KeyAction.down, modifiers: _bits);
      case StickyModifierState.latched:
        _sticky[usage] = StickyModifierState.locked;
      case StickyModifierState.locked:
        _sticky.remove(usage);
        _viewer?.key(usage, KeyAction.up, modifiers: _bits);
    }
    _notify();
  }

  /// Releases every sticky modifier.
  void releaseStickyModifiers() {
    if (_sticky.isEmpty) return;
    for (final usage in _sticky.keys.toList()) {
      _sticky.remove(usage);
      _viewer?.key(usage, KeyAction.up, modifiers: _bits);
    }
    _notify();
  }

  int get _bits => stickyModifierBits | (_capture?._hostModifierBits ?? 0);

  /// Releases latched modifiers: a key, click or text used them.
  void _consumeOneShot() {
    if (!_sticky.containsValue(StickyModifierState.latched)) return;
    for (final entry in _sticky.entries.toList()) {
      if (entry.value != StickyModifierState.latched) continue;
      _sticky.remove(entry.key);
      _viewer?.key(entry.key, KeyAction.up, modifiers: _bits);
    }
    _notify();
  }

  /// Forgets sticky modifiers without sending anything: the host has
  /// released them already.
  void _forgetSticky() {
    if (_sticky.isEmpty) return;
    _sticky.clear();
    _notify();
  }

  bool _notifyScheduled = false;

  /// Notifies listeners, after the frame if widgets are being built (a
  /// capture's `didUpdateWidget` or `dispose`), when they can't rebuild.
  void _notify() {
    if (_disposed) return;
    final scheduler = SchedulerBinding.instance;
    if (scheduler.schedulerPhase != SchedulerPhase.persistentCallbacks) {
      notifyListeners();
      return;
    }
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduler.addPostFrameCallback((_) {
      _notifyScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _capture = null;
    super.dispose();
  }
}
