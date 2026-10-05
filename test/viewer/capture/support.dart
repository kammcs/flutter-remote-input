import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/src/viewer/capture/text_bridge.dart';
import 'package:remote_input/testing.dart';

/// The fake host's display.
const display = Rect.fromLTWH(0, 0, 1920, 1080);

/// The capture's size in tests: the whole test view.
const viewSize = Size(800, 600);

/// The content rect of a 1920×1080 picture contained in [viewSize].
const contained = Rect.fromLTWH(0, 75, 800, 450);

const int usageA = 0x00070004;
const int usageC = 0x00070006;
const int usageQ = 0x00070014;
const int usageEnter = 0x00070028;
const int usageEscape = 0x00070029;
const int usageBackspace = 0x0007002A;
const int usageTab = 0x0007002B;
const int usageCapsLock = 0x00070039;
const int usageArrowLeft = 0x00070050;

/// Where normalized [p] lands on the display, as the viewer and host
/// compute it together.
Offset landing(Offset p) {
  int unit(double v) => (v * 65536).floor().clamp(0, 65535);
  return Offset(
    display.left + (unit(p.dx) + 0.5) * display.width / 65536,
    display.top + (unit(p.dy) + 0.5) * display.height / 65536,
  );
}

/// The normalized point of widget point [local] in [rect].
Offset norm(Offset local, [Rect rect = contained]) => Offset(
  (local.dx - rect.left) / rect.width,
  (local.dy - rect.top) / rect.height,
);

/// Where widget point [local] lands on the display.
Offset at(Offset local, [Rect rect = contained]) => landing(norm(local, rect));

/// Matches an [InjectedMove] or [InjectedButton] that landed within
/// [tolerance] display pixels of [expected].
Matcher closeToPoint(Offset expected, {double tolerance = 0.6}) => predicate(
  (Offset p) => (p - expected).distance <= tolerance,
  'within $tolerance of $expected',
);

/// A real host session over an in-memory link, a viewer, and the capture
/// widget under test.
final class Harness {
  Harness({
    PeerPlatform viewerPlatform = PeerPlatform.windows,
    PeerPlatform hostPlatform = PeerPlatform.windows,
  }) {
    platform = FakeHostPlatform(platform: hostPlatform);
    links = MemoryInputLink.pair();
    session = RemoteInputHost(platform: platform)
        .enable(link: links.host, surface: const SharedSurface.display(1));
    viewer = RemoteInputViewer(
      link: links.viewer,
      options: ViewerOptions(platform: viewerPlatform),
    );
  }

  late final FakeHostPlatform platform;
  late final ({MemoryInputLink host, MemoryInputLink viewer}) links;
  late final ControlSession session;
  late final RemoteInputViewer viewer;

  /// Everything injected on the host.
  List<InjectedEvent> get events => platform.injector.events;

  /// Buttons injected.
  List<InjectedButton> get buttons =>
      events.whereType<InjectedButton>().toList();

  /// Keys injected.
  List<InjectedKey> get keys => events.whereType<InjectedKey>().toList();

  /// Pumps [child] (built with the viewer) filling the test view, and lets
  /// the handshake finish.
  Future<void> start(
    WidgetTester tester,
    Widget Function(RemoteInputViewer viewer) child, {
    Widget Function(Widget capture)? wrap,
  }) async {
    final capture = child(viewer);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: wrap == null ? SizedBox.expand(child: capture) : wrap(capture),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(viewer.state, const SessionActive());
    platform.injector.clear();
  }

  /// Lets queued input reach the host.
  Future<void> settle(WidgetTester tester, [int ms = 50]) =>
      tester.pump(Duration(milliseconds: ms));

  /// Tears everything down, so no timer outlives the test.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await viewer.close();
    session.stop();
    await tester.pump(const Duration(seconds: 1));
  }

  // --- Simulating the platform's text input ---------------------------------

  String _text = CaptureTextInput.placeholder;
  int _lastSet = -1;

  /// The editing state's text now: the last one the client set, unless the
  /// test has typed since.
  String currentText(WidgetTester tester) {
    final log = tester.testTextInput.log;
    final i = log.lastIndexWhere(
      (c) => c.method == 'TextInput.setEditingState',
    );
    if (i > _lastSet) {
      _lastSet = i;
      _text = (log[i].arguments as Map)['text'] as String;
    }
    return _text;
  }

  Future<void> _update(
    WidgetTester tester,
    String text, {
    TextRange composing = TextRange.empty,
  }) async {
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
        composing: composing,
      ),
    );
    await tester.pump();
  }

  /// The platform commits [s], as a keyboard or IME would.
  Future<void> type(WidgetTester tester, String s) async {
    _text = currentText(tester) + s;
    await _update(tester, _text);
  }

  /// The platform deletes the last [n] characters (a soft keyboard's
  /// Backspace).
  Future<void> delete(WidgetTester tester, [int n = 1]) async {
    final t = currentText(tester);
    _text = t.substring(0, t.length - n);
    await _update(tester, _text);
  }

  /// The platform shows [s] as composing text after what's committed.
  Future<void> compose(WidgetTester tester, String s) async {
    final base = currentText(tester);
    await _update(
      tester,
      base + s,
      composing: TextRange(start: base.length, end: base.length + s.length),
    );
  }

  /// The platform commits the composition as [s].
  Future<void> commitComposition(WidgetTester tester, String s) =>
      type(tester, s);

  /// Sends the editing deltas [deltas] as the engine does with the delta
  /// model on.
  Future<void> sendDeltas(
    WidgetTester tester,
    List<Map<String, Object?>> deltas,
  ) async {
    final setClient = tester.testTextInput.log.lastWhere(
      (c) => c.method == 'TextInput.setClient',
    );
    final clientId = (setClient.arguments as List)[0] as int;
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.textInput.name,
      SystemChannels.textInput.codec.encodeMethodCall(
        MethodCall('TextInputClient.updateEditingStateWithDeltas', [
          clientId,
          {'deltas': deltas},
        ]),
      ),
      (_) {},
    );
    await tester.pump();
  }
}

/// A delta inserting [text] at the end of [oldText].
Map<String, Object?> insertionDelta(
  String oldText,
  String text, {
  bool composing = false,
}) {
  final end = oldText.length + text.length;
  return {
    'oldText': oldText,
    'deltaText': text,
    'deltaStart': oldText.length,
    'deltaEnd': oldText.length,
    'selectionBase': end,
    'selectionExtent': end,
    'selectionAffinity': 'TextAffinity.downstream',
    'selectionIsDirectional': false,
    'composingBase': composing ? oldText.length : -1,
    'composingExtent': composing ? end : -1,
  };
}

/// A plain picture to stand in for the remote video.
const Widget picture = ColoredBox(color: Color(0xFF000000));
