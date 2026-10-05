// The viewer screen's layout on short screens, and "Type text…" over an
// in-memory link. Nothing is injected: the host runs on fakes.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/testing.dart';
import 'package:remote_input_example/viewer/capture_view.dart';
import 'package:remote_input_example/viewer/viewer_page.dart';
import 'package:remote_input_example/widgets/send_keys_menu.dart';

const int _enter = 0x00070028;

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A host on fakes and a viewer, over an in-memory link.
({FakeHostPlatform platform, ControlSession session, RemoteInputViewer viewer})
_connect({ViewerOptions options = const ViewerOptions()}) {
  final platform = FakeHostPlatform();
  final link = MemoryInputLink.pair();
  final session = RemoteInputHost(platform: platform)
      .enable(link: link.host, surface: SharedSurface.display(1));
  final viewer = RemoteInputViewer(link: link.viewer, options: options);
  return (platform: platform, session: session, viewer: viewer);
}

/// What the host typed, in order: text, and ⏎ for each Enter press.
String _typed(FakeHostPlatform platform) => [
  for (final e in platform.injector.events)
    switch (e) {
      InjectedText(:final text) => text,
      InjectedKey(usage: _enter, down: true) => '⏎',
      _ => '',
    },
].join();

void main() {
  tearDown(RemoteInputHost.stopAll);

  group('Type text', () {
    test('line breaks become Enter presses', () async {
      final c = _connect();
      await _until(() => c.viewer.state.isActive);
      expect(await typeOnHost(c.viewer, 'ab\ncd\r\n\nef\rg'), TypedText.all);
      await _until(() => _typed(c.platform) == 'ab⏎cd⏎⏎ef⏎g');
      // Every Enter is released.
      final enters = c.platform.injector.events.whereType<InjectedKey>().where(
        (k) => k.usage == _enter,
      );
      expect(enters.where((k) => k.down), hasLength(4));
      expect(enters.where((k) => !k.down), hasLength(4));
      await c.viewer.close();
    });

    test('text past the limit is cut, and the caller told', () async {
      final c = _connect(options: const ViewerOptions(maxTextBytes: 8));
      await _until(() => c.viewer.state.isActive);
      var told = false;
      expect(
        await typeOnHost(c.viewer, 'abc\ndéfghij', onCut: () => told = true),
        TypedText.cut,
      );
      expect(told, isTrue);
      // 3 bytes, a line break, then "déf" (é is two bytes): 8 in all.
      await _until(() => _typed(c.platform) == 'abc⏎déf');
      await c.viewer.close();
    });

    test('nothing is typed without control', () async {
      final c = _connect();
      c.session.pause();
      await _until(() => c.viewer.state is SessionPaused);
      expect(await typeOnHost(c.viewer, 'a\nb'), TypedText.notSent);
      await c.viewer.close();
    });
  });

  group('the viewer screen', () {
    Future<void> pumpPage(WidgetTester tester, RemoteInputViewer viewer) async {
      await tester.pumpWidget(MaterialApp(home: ViewerPage(viewer: viewer)));
      await tester.pump(); // The handshake, over the in-memory link.
      await tester.pump(const Duration(milliseconds: 20));
    }

    Future<void> tearDownPage(WidgetTester tester, ControlSession s) async {
      await tester.pumpWidget(const SizedBox()); // Closes the viewer.
      s.stop();
      await tester.pump(const Duration(seconds: 2));
      debugDefaultTargetPlatformOverride = null;
    }

    testWidgets('fits a landscape phone with the soft keyboard up', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      tester.view
        ..physicalSize = const Size(844, 390)
        ..devicePixelRatio = 1
        ..viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.reset);
      final c = _connect();
      await pumpPage(tester, c.viewer);

      expect(tester.takeException(), isNull); // No RenderFlex overflow.
      expect(c.viewer.state.isActive, isTrue);
      expect(find.byType(AppBar), findsNothing);
      expect(find.textContaining('moves coalesced'), findsNothing);
      expect(find.byTooltip('Disconnect'), findsOneWidget);
      expect(find.text('Esc'), findsOneWidget); // The key bar.
      final picture = tester.getSize(find.byType(CaptureView));
      expect(picture.height, greaterThanOrEqualTo(0.4 * (390 - 300)));

      // The options are in the strip's menu.
      await tester.tap(find.byTooltip('View options'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.ancestor(
          of: find.text('Key bar'),
          matching: find.byWidgetPredicate((w) => w is CheckedPopupMenuItem),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Esc'), findsNothing);
      expect(tester.takeException(), isNull);

      // Keyboard down: still short, still no overflow.
      tester.view.resetViewInsets();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(AppBar), findsNothing);
      await tearDownPage(tester, c.session);
    });

    testWidgets('folds above the picture on a portrait phone with the '
        'keyboard up', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view
        ..physicalSize = const Size(390, 844)
        ..devicePixelRatio = 1
        ..viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.reset);
      final c = _connect();
      await pumpPage(tester, c.viewer);
      expect(tester.takeException(), isNull);
      expect(find.byType(AppBar), findsNothing);
      expect(find.text('Esc'), findsOneWidget);
      final picture = tester.getSize(find.byType(CaptureView));
      expect(picture.height, greaterThanOrEqualTo(0.4 * (844 - 300)));
      final capture = tester.state(find.byType(RemoteInputCapture));

      // Keyboard down: the full layout, with the stats.
      tester.view.resetViewInsets();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.textContaining('moves coalesced'), findsOneWidget);
      // The same capture, moved: its focus (and the soft keyboard) stay.
      expect(tester.state(find.byType(RemoteInputCapture)), same(capture));
      await tearDownPage(tester, c.session);
    });

    testWidgets('keeps the full layout on a desktop window', (tester) async {
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = _connect();
      await pumpPage(tester, c.viewer);
      expect(tester.takeException(), isNull);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('You are in control'), findsOneWidget);
      await tearDownPage(tester, c.session);
    });
  });
}
