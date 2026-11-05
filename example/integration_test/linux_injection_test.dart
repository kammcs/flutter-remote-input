// The Linux injection test (docs/design.md §7.5, §12).
//
// IT MOVES THE REAL POINTER AND TYPES REAL KEYS. Everything goes into this
// app's own window, but run it only when the machine's owner says it's free,
// and keep your hands off the mouse and keyboard while it runs: local input
// pauses the session, and the test fails, by design.
//
// X11, a window share of this app's window (under a Wayland session, through
// XWayland, which reaches XWayland windows only). From example/:
//
//   GDK_BACKEND=x11 REMOTE_INPUT_LINUX_BACKEND=x11 \
//     flutter test integration_test/linux_injection_test.dart -d linux
//
// Wayland, the window fullscreen and the monitor's region shared. The system
// asks in its "Remote Desktop" dialog: turn on "Allow Remote Interaction" and
// press Share when the test prints RIN_PORTAL_DIALOG:
//
//   flutter test integration_test/linux_injection_test.dart -d linux
//
// With RIN_LOCAL_INPUT=1, the test also waits after RIN_LOCAL_INPUT_READY for
// someone (or a script) to press Shift on a keyboard the host has, which must
// pause the session, and then to unplug that keyboard, which must stop it
// (localDeviceLost).
//
// Besides injection, it checks that the package's own input never counts as
// local input: the session never pauses while the test injects.

import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/testing.dart';

const _window = MethodChannel('remote_input_example/window');

const _keyA = 0x00070004;
const _enter = 0x00070028;
const _backspace = 0x0007002A;

bool get _x11 => Platform.environment['REMOTE_INPUT_LINUX_BACKEND'] == 'x11';
bool get _localInput => Platform.environment['RIN_LOCAL_INPUT'] == '1';
bool get _screenCast => Platform.environment['RIN_SCREENCAST'] == '1';

/// What the test window received.
final class _Probe {
  final List<PointerEvent> pointer = [];
  final TextEditingController text = TextEditingController();
  final FocusNode focus = FocusNode();
  int doubleTaps = 0;
  int submitted = 0;

  T last<T extends PointerEvent>() => pointer.whereType<T>().last;
}

Widget _app(_Probe p) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: Scaffold(
    body: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: p.pointer.add,
      onPointerUp: p.pointer.add,
      onPointerMove: p.pointer.add,
      onPointerHover: p.pointer.add,
      onPointerSignal: p.pointer.add,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: () => p.doubleTaps++,
        child: Align(
          alignment: const Alignment(0, 0.8),
          child: SizedBox(
            width: 320,
            child: TextField(
              controller: p.text,
              focusNode: p.focus,
              onSubmitted: (_) => p.submitted++,
            ),
          ),
        ),
      ),
    ),
  ),
);

Future<void> _settle(WidgetTester tester, [int ms = 80]) async {
  await Future<void>.delayed(Duration(milliseconds: ms));
  await tester.pump();
}

Future<Map<String, Object?>> _describe() async =>
    (await _window.invokeMapMethod<String, Object?>('describe'))!;

/// Runs the checks every platform shares, through [viewer], on a surface
/// whose content maps to this window's view at [at].
Future<void> _inject(
  WidgetTester tester,
  _Probe probe,
  RemoteInputViewer viewer,
  Offset Function(Offset) at, {
  required String typed,
  List<String> apart = const [],
  double tolerance = 1.0,
}) async {
  // Corners and centre: within one pixel (X11 posts whole pixels, so up to
  // one in each axis there).
  for (final n in const [
    Offset(0.01, 0.01),
    Offset(0.99, 0.01),
    Offset(0.01, 0.99),
    Offset(0.99, 0.99),
    Offset(0.5, 0.5),
  ]) {
    viewer.pointerMove(n);
    await _settle(tester);
    final hover = probe.last<PointerHoverEvent>();
    expect(
      (hover.position - at(n)).distance,
      lessThanOrEqualTo(tolerance),
      reason: 'move to $n',
    );
  }

  probe.pointer.clear();
  viewer.click(const Offset(0.5, 0.5));
  await _settle(tester);
  final down = probe.last<PointerDownEvent>();
  expect(down.buttons, kPrimaryButton);
  expect((down.position - at(const Offset(0.5, 0.5))).distance, lessThan(1.5));
  expect(probe.pointer.whereType<PointerUpEvent>(), isNotEmpty);

  viewer.click(const Offset(0.3, 0.6), button: PointerButton.right);
  await _settle(tester);
  expect(probe.last<PointerDownEvent>().buttons, kSecondaryButton);
  await _settle(tester, 500); // Past the double-tap timeout.

  viewer.click(const Offset(0.25, 0.25));
  await _settle(tester, 40);
  viewer.click(const Offset(0.25, 0.25), clickCount: 2);
  await _settle(tester, 500);
  expect(probe.doubleTaps, 1);

  probe.pointer.clear();
  const from = Offset(0.2, 0.4);
  const to = Offset(0.6, 0.7);
  viewer.pointerButton(from, PointerButton.left, down: true);
  for (var i = 1; i <= 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 16));
    viewer.pointerMove(Offset.lerp(from, to, i / 10)!);
  }
  await _settle(tester, 40);
  viewer.pointerButton(to, PointerButton.left, down: false);
  await _settle(tester);
  final moves = probe.pointer.whereType<PointerMoveEvent>().toList();
  expect(moves, isNotEmpty);
  expect(moves.every((m) => m.buttons & kPrimaryButton != 0), isTrue);
  expect((moves.last.position - at(to)).distance, lessThanOrEqualTo(tolerance));

  // Scrolling: positive dy reveals what's below, in pixels and lines.
  probe.pointer.clear();
  viewer.wheel(const Offset(0.5, 0.3), dy: 100);
  await _settle(tester, 150);
  viewer.wheel(const Offset(0.5, 0.3), dy: -3, unit: WheelUnit.line);
  await _settle(tester, 150);
  final scrolls = probe.pointer.whereType<PointerScrollEvent>().toList();
  expect(scrolls.length, greaterThanOrEqualTo(2), reason: 'scroll events');
  expect(scrolls.first.scrollDelta.dy, greaterThan(0));
  expect(scrolls.last.scrollDelta.dy, lessThan(0));

  // Keys, into the text field (a click there first, as a viewer would).
  viewer.click(const Offset(0.5, 0.9));
  probe.focus.requestFocus();
  await _settle(tester, 300);
  viewer
    ..key(_keyA, KeyAction.down)
    ..key(_keyA, KeyAction.up)
    ..key(HidModifier.shiftLeft, KeyAction.down, modifiers: KeyModifiers.shift)
    ..key(_keyA, KeyAction.down, modifiers: KeyModifiers.shift)
    ..key(_keyA, KeyAction.up, modifiers: KeyModifiers.shift)
    ..key(HidModifier.shiftLeft, KeyAction.up);
  await _settle(tester, 300);
  expect(probe.text.text, 'aA');
  viewer
    ..key(_backspace, KeyAction.down)
    ..key(_backspace, KeyAction.up);
  await _settle(tester, 200);
  expect(probe.text.text, 'a');
  // Ctrl+A selects all, Backspace clears it.
  viewer
    ..key(
      HidModifier.controlLeft,
      KeyAction.down,
      modifiers: KeyModifiers.control,
    )
    ..key(_keyA, KeyAction.down, modifiers: KeyModifiers.control)
    ..key(_keyA, KeyAction.up, modifiers: KeyModifiers.control)
    ..key(HidModifier.controlLeft, KeyAction.up)
    ..key(_backspace, KeyAction.down)
    ..key(_backspace, KeyAction.up);
  await _settle(tester, 300);
  expect(probe.text.text, isEmpty);

  viewer.text(typed);
  await _settle(tester, 1500);
  expect(probe.text.text, typed);

  // Characters typed one at a time, as a person types.
  for (final c in apart) {
    viewer.text(c);
    await _settle(tester, 200);
  }
  expect(probe.text.text, typed + apart.join());

  viewer
    ..key(_enter, KeyAction.down)
    ..key(_enter, KeyAction.up);
  await _settle(tester, 200);
  expect(probe.submitted, 1);
}

/// The host's own window is protected (HostOptions.protectHostWindows, on
/// by default): a click on it is dropped and keys are blocked while it has
/// focus. On Wayland the click is dropped once GTK knows the pointer is
/// over it, so the pointer moves there first and waits.
Future<void> _protectedChecks(
  WidgetTester tester,
  _Probe probe,
  RemoteInputHost host,
  SharedSurface surface,
  HostOptions options,
) async {
  final pair = MemoryInputLink.pair();
  final session = host.enable(
    link: pair.host,
    surface: surface,
    options: options,
  );
  final viewer = RemoteInputViewer(link: pair.viewer);
  try {
    await viewer.stateChanges
        .firstWhere((s) => s is SessionActive)
        .timeout(const Duration(seconds: 5));
    viewer.pointerMove(const Offset(0.5, 0.5));
    await _settle(tester, 200);
    probe.pointer.clear();
    viewer.click(const Offset(0.5, 0.5));
    await _settle(tester, 200);
    expect(probe.pointer.whereType<PointerDownEvent>(), isEmpty);
    expect(session.stats.dropped[DropReason.hostWindow], greaterThan(0));
    final before = probe.text.text;
    viewer
      ..key(_keyA, KeyAction.down)
      ..key(_keyA, KeyAction.up);
    await _settle(tester, 200);
    expect(probe.text.text, before);
    expect(session.state, const SessionBlocked(BlockReason.hostAppInFront));
    debugPrint('RIN protected: ${session.stats.dropped}');
  } finally {
    session.stop();
    await viewer.close();
  }
}

/// With RIN_LOCAL_INPUT=1: the presenter's Shift pauses the session, and
/// unplugging that keyboard stops it.
Future<void> _localInputChecks(
  WidgetTester tester,
  ControlSession session,
) async {
  if (!_localInput) return;
  debugPrint('RIN_LOCAL_INPUT_READY');
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (session.state is! SessionPaused && DateTime.now().isBefore(deadline)) {
    await _settle(tester, 20);
  }
  expect(session.state, const SessionPaused(PauseReason.localInput));
  debugPrint('RIN_LOCAL_INPUT_PAUSED');
  while (session.state is! SessionStopped &&
      DateTime.now().isBefore(deadline)) {
    await _settle(tester, 20);
  }
  expect(session.state, const SessionStopped(StopReason.localDeviceLost));
  debugPrint('RIN_LOCAL_INPUT_DEVICE_LOST');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('X11: injects into its own window, a window share', (
    tester,
  ) async {
    binding.shouldPropagateDevicePointerEvents = true;
    final probe = _Probe();
    ControlSession? session;
    RemoteInputViewer? viewer;
    final states = <SessionState>[];
    try {
      await tester.pumpWidget(_app(probe));
      await _settle(tester, 500);
      await _window.invokeMethod<void>('present');
      await _settle(tester, 500);
      final info = await _describe();
      expect(info['active'], isTrue, reason: 'the test window has no focus');
      final xid = info['xid']! as int;
      final insets = EdgeInsets.fromLTRB(
        (info['insetLeft']! as int).toDouble(),
        (info['insetTop']! as int).toDouble(),
        (info['insetRight']! as int).toDouble(),
        (info['insetBottom']! as int).toDouble(),
      );
      final view = tester.view;
      final size = view.physicalSize / view.devicePixelRatio;
      Offset at(Offset n) => Offset(n.dx * size.width, n.dy * size.height);

      final host = RemoteInputHost();
      expect(host.checkAvailable(), isNull);
      await _protectedChecks(
        tester,
        probe,
        host,
        SharedSurface.window(xid, contentInsets: insets),
        const HostOptions(),
      );
      final pair = MemoryInputLink.pair();
      session = host.enable(
        link: pair.host,
        surface: SharedSurface.window(xid, contentInsets: insets),
        // The test injects into its own window, which the host otherwise
        // protects (HostOptions.protectHostWindows).
        options: const HostOptions(protectHostWindows: false),
      );
      session.stateChanges.listen(states.add);
      viewer = RemoteInputViewer(link: pair.viewer);
      await viewer.stateChanges
          .firstWhere((s) => s is SessionActive)
          .timeout(const Duration(seconds: 5));

      await _inject(
        tester,
        probe,
        viewer,
        at,
        // In one burst. Characters the layout lacks go through spare
        // keycodes; in a burst, Flutter's Linux embedder can order those
        // before the layout's keys still in its queue, so they're also
        // typed one at a time below.
        typed: 'hello world, The Quick Brown Fox 0123456789 !@#',
        apart: const ['é', 'ö', ' ', '—', '👋', 'ñ'],
        tolerance: 1.5,
      );
      expect(
        states.whereType<SessionPaused>(),
        isEmpty,
        reason: "The package's own XTest input counted as local input.",
      );
      debugPrint('RIN local input: ${session.stats.localInput}');
      await _localInputChecks(tester, session);
      session.stop();
      await _settle(tester, 100);
      expect(HardwareKeyboard.instance.physicalKeysPressed, isEmpty);
    } finally {
      // Counts only (design §6.6).
      final stats = session?.stats;
      debugPrint(
        'RIN stats: injected ${stats?.injected}, dropped ${stats?.dropped}, '
        'states ${states.map((s) => s.runtimeType).toList()}, '
        'last ${session?.state}',
      );
      session?.stop();
      await viewer?.close();
      binding.shouldPropagateDevicePointerEvents = false;
    }
  }, skip: !Platform.isLinux || !_x11);

  testWidgets('Wayland: injects through the portal into its own window', (
    tester,
  ) async {
    binding.shouldPropagateDevicePointerEvents = true;
    final probe = _Probe();
    ControlSession? session;
    RemoteInputViewer? viewer;
    final states = <SessionState>[];
    try {
      await tester.pumpWidget(_app(probe));
      await _settle(tester, 500);
      await _window.invokeMethod<void>('fullscreen');
      await _settle(tester, 1500);
      expect((await _describe())['active'], isTrue);

      final host = RemoteInputHost();
      expect(host.checkAvailable(), HostUnavailableReason.waylandNotAllowed);
      const options = HostOptions(
        allowWayland: true,
        protectHostWindows: false,
      );
      expect(
        host.checkAvailable(options: options),
        HostUnavailableReason.permissionDenied,
      );
      expect(
        await RemoteInputPermissions.status(),
        RemoteInputPermissionStatus.denied,
      );
      debugPrint('RIN_PORTAL_DIALOG');
      final started = await RemoteInputPortal.start();
      expect(started.status, PortalStartStatus.ok, reason: started.message);
      await _settle(tester, 1000);
      expect((await _describe())['active'], isTrue);
      expect(host.checkAvailable(options: options), isNull);
      expect(
        await RemoteInputPermissions.status(),
        RemoteInputPermissionStatus.granted,
      );

      final displays = await host.displays();
      debugPrint('RIN regions: ${displays.map((d) => '${d.id} ${d.bounds}')}');
      final display = displays.first;
      final view = tester.view;
      final size = view.physicalSize / view.devicePixelRatio;
      // Fullscreen at the monitor's origin: the region is the view.
      expect(display.bounds.size, size);
      Offset at(Offset n) => Offset(n.dx * size.width, n.dy * size.height);

      await _protectedChecks(
        tester,
        probe,
        host,
        SharedSurface.display(display.id),
        const HostOptions(allowWayland: true),
      );
      final pair = MemoryInputLink.pair();
      session = host.enable(
        link: pair.host,
        surface: SharedSurface.display(display.id),
        options: options,
      );
      session.stateChanges.listen(states.add);
      viewer = RemoteInputViewer(link: pair.viewer);
      await viewer.stateChanges
          .firstWhere((s) => s is SessionActive)
          .timeout(const Duration(seconds: 5));

      await _inject(
        tester,
        probe,
        viewer,
        at,
        typed: 'hello world, The Quick Brown Fox 0123456789 !@#',
      );
      expect(
        states.whereType<SessionPaused>(),
        isEmpty,
        reason: "The package's own libei input counted as local input.",
      );
      // What the layout can't type is dropped and counted.
      final unmappedBefore = session.stats.dropped[DropReason.unmapped] ?? 0;
      viewer.text('👋');
      await _settle(tester, 300);
      expect(session.stats.dropped[DropReason.unmapped], unmappedBefore + 1);
      debugPrint('RIN local input: ${session.stats.localInput}');

      await _localInputChecks(tester, session);

      // The revoke: a new control session on the same portal session, then
      // the portal session ends. With RIN_SHELL_STOP=1 the person (or a
      // script) presses Stop in GNOME's sharing indicator after
      // RIN_SHELL_STOP; otherwise the app closes it.
      session.stop();
      final shellStop = Platform.environment['RIN_SHELL_STOP'] == '1';
      final closed = RemoteInputPortal.closed.first;
      final pair2 = MemoryInputLink.pair();
      final second = host.enable(
        link: pair2.host,
        surface: SharedSurface.display(display.id),
        options: options,
      );
      final viewer2 = RemoteInputViewer(link: pair2.viewer);
      await viewer2.stateChanges
          .firstWhere((s) => s is SessionActive)
          .timeout(const Duration(seconds: 5));
      if (shellStop) {
        // Out of fullscreen, so the top bar and its indicator show.
        await _window.invokeMethod<void>('unfullscreen');
        await _settle(tester, 1000);
        debugPrint('RIN_SHELL_STOP');
      } else {
        await RemoteInputPortal.close();
      }
      final reason = await closed.timeout(const Duration(seconds: 60));
      await _settle(tester, 100);
      // GNOME's Stop ends EIS as well as the portal session; whichever is
      // heard first is the reason.
      expect(
        reason,
        shellStop
            ? isIn([PortalCloseReason.closed, PortalCloseReason.disconnected])
            : PortalCloseReason.closedByApp,
      );
      expect(second.state, const SessionStopped(StopReason.permissionDenied));
      debugPrint('RIN_REVOKED ${reason.name}');
      await viewer2.close();
      expect(
        await RemoteInputPermissions.status(),
        RemoteInputPermissionStatus.denied,
      );
      await _settle(tester, 100);
      expect(HardwareKeyboard.instance.physicalKeysPressed, isEmpty);
    } finally {
      final stats = session?.stats;
      debugPrint(
        'RIN stats: injected ${stats?.injected}, dropped ${stats?.dropped}, '
        'states ${states.map((s) => s.runtimeType).toList()}, '
        'last ${session?.state}',
      );
      session?.stop();
      await viewer?.close();
      await RemoteInputPortal.close();
      binding.shouldPropagateDevicePointerEvents = false;
    }
  }, skip: !Platform.isLinux || _x11);

  // With RIN_SCREENCAST=1: one dialog for the share and the control. Share
  // the screen with "Allow Remote Interaction" on when the test prints
  // RIN_PORTAL_DIALOG_SCREENCAST.
  testWidgets('Wayland: one dialog for a screen cast and control', (
    tester,
  ) async {
    binding.shouldPropagateDevicePointerEvents = true;
    final probe = _Probe();
    ControlSession? session;
    RemoteInputViewer? viewer;
    try {
      await tester.pumpWidget(_app(probe));
      await _settle(tester, 500);
      await _window.invokeMethod<void>('fullscreen');
      await _settle(tester, 1500);
      expect((await _describe())['active'], isTrue);
      debugPrint('RIN_PORTAL_DIALOG_SCREENCAST');
      final started = await RemoteInputPortal.start(screenCast: true);
      expect(started.status, PortalStartStatus.ok, reason: started.message);
      expect(started.pipewireFd, greaterThanOrEqualTo(0));
      final stream = started.streams.single;
      debugPrint(
        'RIN stream: $stream, size ${stream.size}, '
        'position ${stream.position}, scale ${stream.scale}',
      );
      expect(stream.sourceType, PortalSourceType.monitor);
      expect(stream.displayId, isNot(0));
      expect(RemoteInputPortal.streams, started.streams);
      await _settle(tester, 1000);
      expect((await _describe())['active'], isTrue);

      final view = tester.view;
      final size = view.physicalSize / view.devicePixelRatio;
      Offset at(Offset n) => Offset(n.dx * size.width, n.dy * size.height);
      final pair = MemoryInputLink.pair();
      session = RemoteInputHost().enable(
        link: pair.host,
        surface: stream.surface,
        options: const HostOptions(
          allowWayland: true,
          protectHostWindows: false,
        ),
      );
      viewer = RemoteInputViewer(link: pair.viewer);
      await viewer.stateChanges
          .firstWhere((s) => s is SessionActive)
          .timeout(const Duration(seconds: 5));
      viewer.pointerMove(const Offset(0.3, 0.4));
      await _settle(tester);
      expect(
        (probe.last<PointerHoverEvent>().position - at(const Offset(0.3, 0.4)))
            .distance,
        lessThanOrEqualTo(1.0),
      );
      probe.pointer.clear();
      viewer.click(const Offset(0.6, 0.5));
      await _settle(tester);
      expect(
        (probe.last<PointerDownEvent>().position - at(const Offset(0.6, 0.5)))
            .distance,
        lessThanOrEqualTo(1.0),
      );
      await RemoteInputPortal.close();
      await _settle(tester, 300);
      expect(session.state, const SessionStopped(StopReason.permissionDenied));
      expect(RemoteInputPortal.streams, isEmpty);
    } finally {
      session?.stop();
      await viewer?.close();
      await RemoteInputPortal.close();
      binding.shouldPropagateDevicePointerEvents = false;
    }
  }, skip: !Platform.isLinux || _x11 || !_screenCast);
}
