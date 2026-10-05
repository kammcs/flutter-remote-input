import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/testing.dart';
import 'package:remote_input_example/host/host_page.dart';
import 'package:remote_input_example/main.dart';
import 'package:remote_input_example/viewer/viewer_page.dart';
import 'package:remote_input_example/widgets/session_state_view.dart';

void main() {
  testWidgets('home shows the three roles', (tester) async {
    await tester.pumpWidget(const RemoteInputExampleApp());
    expect(find.text('One-machine demo'), findsOneWidget);
    expect(find.text('Control another computer'), findsOneWidget);
    expect(find.text('Host this computer'), findsOneWidget);
    expect(find.textContaining('Protocol version 1'), findsOneWidget);
  });

  testWidgets('the viewer screen asks for an address and a code', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ViewerPage()));
    expect(find.text("Host's address"), findsOneWidget);
    expect(find.text('Code'), findsOneWidget);
    expect(find.textContaining('Development only'), findsOneWidget);

    await tester.tap(find.text('Connect'));
    await tester.pump();
    expect(find.text('Enter an address'), findsOneWidget);
    expect(find.text('Enter all six digits'), findsOneWidget);
  });

  testWidgets('without an injector, the host screen explains and offers '
      'the demo', (tester) async {
    // No native plugin is loaded under `flutter test`.
    expect(RemoteInputHost.isSupported, isFalse);
    await tester.pumpWidget(const MaterialApp(home: HostPage()));
    expect(find.text('Open the one-machine demo'), findsOneWidget);
    expect(find.text("Can't be controlled on this device"), findsOneWidget);
  });

  testWidgets('with a host, the host screen picks a display and can listen', (
    tester,
  ) async {
    final host = RemoteInputHost(platform: FakeHostPlatform());
    await tester.pumpWidget(MaterialApp(home: HostPage(host: host)));
    await tester.pump();
    expect(find.text('Shared display'), findsOneWidget);
    expect(find.textContaining('1920 × 1080 px'), findsOneWidget);
    expect(find.text('Start listening'), findsOneWidget);
    expect(find.textContaining('Development only'), findsOneWidget);
  });

  testWidgets('the host screen shows onboarding when the permission is '
      'missing', (tester) async {
    final platform = FakeHostPlatform(platform: PeerPlatform.macos)
      ..unavailable = HostUnavailableReason.permissionDenied;
    await tester.pumpWidget(
      MaterialApp(
        home: HostPage(host: RemoteInputHost(platform: platform)),
      ),
    );
    await tester.pump();
    expect(find.text('Allow this app to control the computer'), findsOneWidget);
    expect(find.text('Start listening'), findsNothing);

    platform.unavailable = null; // Granted in System Settings.
    await tester.tap(find.text('Check again'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Start listening'), findsOneWidget);
  });

  test('the RTT window reports percentiles of the last samples', () {
    final w = RttWindow(capacity: 4);
    expect(w.percentile(50), isNull);
    for (final ms in [40, 10, 20, 30, 99]) {
      w.add(Duration(milliseconds: ms));
    }
    w.add(null); // Not measured yet: ignored.
    expect(w.count, 4); // 40 fell out.
    expect(w.percentile(50), const Duration(milliseconds: 30));
    expect(w.percentile(95), const Duration(milliseconds: 99));
  });

  testWidgets('home lays out on a phone', (tester) async {
    tester.view
      ..physicalSize = const Size(360, 640)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const RemoteInputExampleApp());
    expect(tester.takeException(), isNull);
    expect(find.text('One-machine demo'), findsOneWidget);
  });
}
