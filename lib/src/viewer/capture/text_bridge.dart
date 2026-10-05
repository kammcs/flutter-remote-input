/// The capture widget's text input client: turns what the platform's text
/// system commits (hardware keys it was left, dead keys, IMEs, soft
/// keyboards) into text and the odd Backspace or Enter for the host.
library;

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show StringCharacters;

/// What a [CaptureTextInput] reports.
abstract interface class CaptureTextSink {
  /// Committed [text] to type on the host. Never empty, never contains a
  /// line break (those arrive as [pressKey] with Enter).
  void commitText(String text);

  /// A key the text system produced as an edit: Backspace for a deletion,
  /// Enter for a line break or an action. [usage] is a USB HID usage.
  void pressKey(int usage);

  /// The text being composed changed (empty when nothing is). Shown only
  /// on the viewer.
  void composingChanged(String composing);

  /// The platform closed the connection.
  void textInputClosed();
}

/// A text input client that never keeps what's typed: it diffs each
/// editing state against what it has already passed on, and sends only the
/// change.
///
/// **The buffer.** The platform's editing state starts as [placeholder]
/// with the caret at its end, so a soft keyboard's Backspace always has
/// something to delete (an empty field gets no deletion at all on iOS and
/// Android), and keyboards see a plain context. Text the user types is
/// kept after it, so a keyboard that rewrites recent text (an autocorrect,
/// iOS's double-space full stop) is mirrored on the host as Backspaces
/// and new text. The buffer is reset to the placeholder when it runs low
/// or grows long, and by [resetBuffer] (the capture calls it after a
/// physical key or a click, when the host's caret may have moved), but
/// never while text is being composed.
///
/// **Composing.** Text inside the composing range (an IME's candidate, a
/// pending dead key, an Android keyboard's current word) isn't sent: only
/// once it leaves the range is it committed. Deletions are sent at once.
/// [finishComposing] commits it early, before a click.
final class CaptureTextInput
    with TextInputClient
    implements DeltaTextInputClient {
  /// Creates a client reporting to [sink].
  CaptureTextInput(this.sink);

  /// Where edits go.
  final CaptureTextSink sink;

  /// The text the editing state holds before anything is typed.
  static const String placeholder = '        ';

  /// The longest the typed text may grow before the buffer is reset.
  static const int maxBuffered = 64;

  /// The empty editing state: [placeholder] with the caret at its end.
  static const TextEditingValue initialValue = TextEditingValue(
    text: placeholder,
    selection: TextSelection.collapsed(offset: placeholder.length),
  );

  TextInputConnection? _connection;
  bool _shown = false;
  TextEditingValue _value = initialValue;
  String _sent = placeholder;
  String _composing = '';

  /// Whether a connection to the platform's text input is open.
  bool get isAttached => _connection?.attached ?? false;

  /// Whether the connection has been shown: the platform delivers text to
  /// it (and on phones, the soft keyboard is up).
  bool get isShown => isAttached && _shown;

  /// Whether text is being composed.
  bool get isComposing {
    final c = _value.composing;
    return c.isValid && !c.isCollapsed;
  }

  /// The text being composed, not yet committed.
  String get composingText => _composing;

  /// Opens a connection with [configuration], if none is open.
  void attach(TextInputConfiguration configuration) {
    if (isAttached) return;
    _value = initialValue;
    _sent = placeholder;
    _setComposing('');
    _shown = false;
    final connection = TextInput.attach(this, configuration);
    _connection = connection;
    connection.setEditingState(_value);
  }

  /// Shows the connection: the platform starts delivering text to it.
  void show() {
    final connection = _connection;
    if (connection == null || !connection.attached) return;
    connection.show();
    _shown = true;
  }

  /// Tells the platform where the editable area is, for IME candidate
  /// windows.
  void setGeometry(Size size, Matrix4 transform, Rect caret) {
    final connection = _connection;
    if (connection == null || !connection.attached) return;
    connection
      ..setEditableSizeAndTransform(size, transform)
      ..setComposingRect(caret)
      ..setCaretRect(caret);
  }

  /// Closes the connection. Text being composed is dropped.
  void detach() {
    final connection = _connection;
    _connection = null;
    _shown = false;
    if (connection != null && connection.attached) connection.close();
    _value = initialValue;
    _sent = placeholder;
    _setComposing('');
  }

  /// Resets the buffer to the placeholder, unless text is being composed.
  void resetBuffer() {
    if (isComposing) return;
    if (_value == initialValue && _sent == placeholder) return;
    _value = initialValue;
    _sent = placeholder;
    final connection = _connection;
    if (connection != null && connection.attached) {
      connection.setEditingState(_value);
    }
  }

  /// Ends the composition: the text being composed is committed (sent) as
  /// it stands, and the buffer is reset to the placeholder, which tells the
  /// platform the composition is over. Called before a click goes to the
  /// host, so an Android keyboard's current word is typed where the caret
  /// was, as a click away from a local field commits it, not where the
  /// click moves the caret. Does nothing while nothing is composed.
  void finishComposing() {
    if (!isComposing) return;
    final text = _value.text;
    final end = math.min(_value.composing.end, text.length);
    // What was passed on is a prefix of the text; the rest of the
    // composing range hasn't been.
    final pending = end > _sent.length ? text.substring(_sent.length, end) : '';
    _value = initialValue;
    _sent = placeholder;
    _setComposing('');
    final connection = _connection;
    if (connection != null && connection.attached) {
      connection.setEditingState(_value);
    }
    if (pending.isNotEmpty) _commit(pending);
  }

  // --- TextInputClient --------------------------------------------------

  @override
  TextEditingValue? get currentTextEditingValue => _value;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) => _accept(value);

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> textEditingDeltas) {
    if (textEditingDeltas.isEmpty) return;
    final base = textEditingDeltas.first.oldText;
    var value = _value;
    for (final delta in textEditingDeltas) {
      value = delta.apply(value);
    }
    _accept(value, base: base);
  }

  @override
  void performAction(TextInputAction action) {
    // On the web, Enter on a hardware keyboard both reaches the capture as
    // a key event (sent physically) and makes the engine perform the input
    // action. Only an action without a hardware Enter held is a soft
    // keyboard's.
    final pressed = HardwareKeyboard.instance.physicalKeysPressed;
    if (pressed.contains(PhysicalKeyboardKey.enter) ||
        pressed.contains(PhysicalKeyboardKey.numpadEnter)) {
      return;
    }
    sink.pressKey(_enter);
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _connection = null;
    _shown = false;
    _value = initialValue;
    _sent = placeholder;
    _setComposing('');
    sink.textInputClosed();
  }

  // --- Diffing ----------------------------------------------------------

  static const int _backspace = 0x0007002A;
  static const int _enter = 0x00070028;

  void _accept(TextEditingValue next, {String? base}) {
    if (base != null && base != _value.text) {
      // The platform edited a state other than the one we hold: we reset
      // the buffer while its edit was in flight. Treat what it had as
      // passed on, so only its own change is sent.
      _sent = base;
    }
    _value = next;
    final text = next.text;
    final composing = next.composing;
    final hasComposing =
        composing.isValid &&
        !composing.isCollapsed &&
        composing.end <= text.length;
    final committedEnd = hasComposing ? composing.start : text.length;

    // The common prefix of what was passed on and the new text, in whole
    // grapheme clusters, so a Backspace removes what one would.
    final sentChars = _sent.characters.iterator;
    final textChars = text.characters.iterator;
    var sameUnits = 0;
    var sameChars = 0;
    while (sentChars.moveNext()) {
      if (!textChars.moveNext() || sentChars.current != textChars.current) {
        break;
      }
      sameUnits += sentChars.current.length;
      sameChars++;
    }
    final backspaces = _sent.characters.length - sameChars;
    final keep = math.max(sameUnits, committedEnd);
    final inserted = committedEnd > sameUnits
        ? text.substring(sameUnits, committedEnd)
        : '';
    _sent = text.substring(0, keep);

    for (var i = 0; i < backspaces; i++) {
      sink.pressKey(_backspace);
    }
    if (inserted.isNotEmpty) _commit(inserted);

    _setComposing(
      hasComposing
          ? text.substring(math.max(composing.start, sameUnits), composing.end)
          : '',
    );

    if (!hasComposing &&
        (!text.startsWith(placeholder) ||
            text.length > placeholder.length + maxBuffered)) {
      resetBuffer();
    }
  }

  void _commit(String text) {
    final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    var start = 0;
    while (true) {
      final i = lines.indexOf('\n', start);
      final segment = lines.substring(start, i < 0 ? lines.length : i);
      if (segment.isNotEmpty) sink.commitText(segment);
      if (i < 0) break;
      sink.pressKey(_enter);
      start = i + 1;
    }
  }

  void _setComposing(String composing) {
    if (composing == _composing) return;
    _composing = composing;
    sink.composingChanged(composing);
  }
}
