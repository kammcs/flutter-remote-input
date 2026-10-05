import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input_example/demo/demo_page.dart';
import 'package:remote_input_example/demo/virtual_desktop.dart';

/// The presenter's desktop in the demo is 1920 × 1080 (Windows).
const Size _desktop = Size(1920, 1080);

Future<void> _pumpDemo(WidgetTester tester) async {
  tester.view
    ..physicalSize = const Size(1400, 900)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const MaterialApp(home: DemoPage()));
  await tester.pump(); // The handshake runs over the in-memory link.
  await tester.pump(const Duration(milliseconds: 20));
}

/// Unmounts the demo, which stops its session and closes its link.
Future<void> _tearDownDemo(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 2));
}

/// Where a point of the desktop (in its own coordinates) is on screen, in
/// the viewer's controlled view.
Offset _inControlledView(WidgetTester tester, Offset desktopPoint) {
  final view = tester.getRect(find.byKey(const ValueKey('demo-capture')));
  final content = Alignment.center.inscribe(
    applyBoxFit(BoxFit.contain, _desktop, view.size).destination,
    view,
  );
  return content.topLeft +
      Offset(
        desktopPoint.dx / _desktop.width * content.width,
        desktopPoint.dy / _desktop.height * content.height,
      );
}

String _notesText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('notes-text')).first).data!;

void main() {
  testWidgets('a click in the controlled view lands on the presenter\'s '
      'desktop', (tester) async {
    await _pumpDemo(tester);
    expect(find.text('You are in control'), findsOneWidget);
    expect(find.text('Being controlled'), findsOneWidget);
    expect(find.byType(ClickRipple), findsNothing);

    final desktop = VirtualDesktop(
      bounds: Offset.zero & _desktop,
      presenter: PeerPlatform.windows,
    );
    await tester.tapAt(_inControlledView(tester, desktop.buttonRect.center));
    await tester.pump(const Duration(milliseconds: 50));

    // Both views draw the desktop: the "video" and the presenter's.
    expect(find.byType(ClickRipple), findsNWidgets(2));
    expect(find.textContaining('1 clicks'), findsNWidgets(2));
    desktop.dispose();
    await _tearDownDemo(tester);
  });

  testWidgets('typing reaches the presenter\'s text box', (tester) async {
    await _pumpDemo(tester);
    // Focus the controlled view.
    await tester.tapAt(_inControlledView(tester, const Offset(100, 900)));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump(const Duration(milliseconds: 50));

    expect(_notesText(tester), 'hi\n▍');
    await _tearDownDemo(tester);
  });

  testWidgets('Stop stops control on both sides', (tester) async {
    await _pumpDemo(tester);
    await tester.tap(find.byKey(const ValueKey('demo-stop')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('You stopped control'), findsOneWidget);
    expect(find.text('The host stopped control'), findsOneWidget);

    // Input after the stop is not injected.
    final before = _notesText(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    await tester.pump(const Duration(milliseconds: 50));
    expect(_notesText(tester), before);

    await tester.tap(find.byKey(const ValueKey('demo-restart')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('You are in control'), findsOneWidget);
    await _tearDownDemo(tester);
  });

  testWidgets('local input pauses control, which then resumes', (tester) async {
    await _pumpDemo(tester);
    await tester.tap(find.byKey(const ValueKey('demo-local-input')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(
      find.text('Paused while you use your mouse or keyboard'),
      findsOneWidget,
    );
    expect(
      find.text('Paused: the person at the host is using their computer'),
      findsOneWidget,
    );

    // HostOptions.localIdle: 1.5 s without local input.
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Being controlled'), findsOneWidget);
    await _tearDownDemo(tester);
  });

  testWidgets('the demo lays out on a phone, with the key bar', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: DemoPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(tester.takeException(), isNull);
    expect(find.text('Esc'), findsOneWidget); // The key bar.
    await _tearDownDemo(tester);
    debugDefaultTargetPlatformOverride = null;
  });
}
