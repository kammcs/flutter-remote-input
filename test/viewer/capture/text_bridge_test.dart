import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/src/viewer/capture/text_bridge.dart';

const _p = CaptureTextInput.placeholder;
const _backspace = 0x0007002A;
const _enter = 0x00070028;

final class _Sink implements CaptureTextSink {
  final List<Object> out = [];
  String composing = '';

  @override
  void commitText(String text) => out.add(text);

  @override
  void pressKey(int usage) => out.add(usage);

  @override
  void composingChanged(String composing) => this.composing = composing;

  @override
  void textInputClosed() => out.add('closed');
}

TextEditingValue _v(String text, [TextRange composing = TextRange.empty]) =>
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
      composing: composing,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Sink sink;
  late CaptureTextInput input;

  setUp(() {
    sink = _Sink();
    input = CaptureTextInput(sink);
  });

  test('sends each committed character once', () {
    input
      ..updateEditingValue(_v('${_p}h'))
      ..updateEditingValue(_v('${_p}hi'))
      ..updateEditingValue(_v('${_p}hi 👋🏽'));
    expect(sink.out, ['h', 'i', ' 👋🏽']);
  });

  test('a deletion is a Backspace per grapheme, even into the placeholder', () {
    input
      ..updateEditingValue(_v('${_p}ab👋🏽'))
      ..updateEditingValue(_v('${_p}ab'))
      ..updateEditingValue(_v(_p.substring(1)));
    expect(sink.out, [
      'ab👋🏽',
      _backspace,
      _backspace,
      _backspace,
      _backspace,
    ]);
    // Deleting into the placeholder resets it, so the next one works too.
    expect(input.currentTextEditingValue, CaptureTextInput.initialValue);
    input.updateEditingValue(_v(_p.substring(1)));
    expect(sink.out, hasLength(6));
    expect(sink.out.last, _backspace);
  });

  test('a rewrite of recent text is mirrored', () {
    input
      ..updateEditingValue(_v('${_p}hello '))
      // iOS's double-space full stop.
      ..updateEditingValue(_v('${_p}hello. '));
    expect(sink.out, ['hello ', _backspace, '. ']);
  });

  test('composing text is held back until committed', () {
    input.updateEditingValue(
      _v('${_p}k', TextRange(start: _p.length, end: _p.length + 1)),
    );
    expect(sink.composing, 'k');
    input.updateEditingValue(
      _v('$_pか', TextRange(start: _p.length, end: _p.length + 1)),
    );
    input.updateEditingValue(
      _v('$_p家', TextRange(start: _p.length, end: _p.length + 1)),
    );
    expect(sink.out, isEmpty);
    expect(input.isComposing, isTrue);
    input.updateEditingValue(_v('$_p家'));
    expect(sink.out, ['家']);
    expect(sink.composing, '');
    expect(input.isComposing, isFalse);
  });

  test('a cancelled composition sends nothing', () {
    input
      ..updateEditingValue(
        _v('${_p}xy', TextRange(start: _p.length, end: _p.length + 2)),
      )
      ..updateEditingValue(_v(_p));
    expect(sink.out, isEmpty);
  });

  test('recomposing sent text deletes and retypes only what changed', () {
    input.updateEditingValue(_v('${_p}hello'));
    // An Android keyboard reopens the word for composing...
    input.updateEditingValue(
      _v('${_p}hello', TextRange(start: _p.length, end: _p.length + 5)),
    );
    expect(sink.out, ['hello']);
    // ...and deleting from it is sent at once.
    input.updateEditingValue(
      _v('${_p}hell', TextRange(start: _p.length, end: _p.length + 4)),
    );
    expect(sink.out, ['hello', _backspace]);
    // A suggestion replaces the word: the host has "hell", and gets "help ".
    input.updateEditingValue(_v('${_p}help '));
    expect(sink.out, ['hello', _backspace, _backspace, 'p ']);
  });

  test('line breaks are Enter', () {
    input.updateEditingValue(_v('${_p}a\nb\r\n'));
    expect(sink.out, ['a', _enter, 'b', _enter]);
  });

  test('deltas apply on top of their own old text', () {
    input.updateEditingValueWithDeltas([
      TextEditingDeltaInsertion(
        oldText: _p,
        textInserted: 'é',
        insertionOffset: _p.length,
        selection: const TextSelection.collapsed(offset: _p.length + 1),
        composing: TextRange.empty,
      ),
    ]);
    expect(sink.out, ['é']);
  });

  test('a long buffer is reset', () {
    final long = 'x' * (CaptureTextInput.maxBuffered + 1);
    input.updateEditingValue(_v('$_p$long'));
    expect(input.currentTextEditingValue, CaptureTextInput.initialValue);
    input.updateEditingValue(_v('${_p}y'));
    expect(sink.out, [long, 'y']);
  });

  test('performAction is Enter unless a hardware Enter is down', () async {
    input.performAction(TextInputAction.newline);
    expect(sink.out, [_enter]);
  });
}
