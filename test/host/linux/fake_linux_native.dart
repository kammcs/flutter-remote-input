import 'dart:ui' show Rect;

import 'package:remote_input/src/host/linux/linux_native.dart';

/// A recorded native call.
typedef Call = (String, List<Object?>);

/// A [LinuxNative] that records its calls and answers from fields.
final class FakeLinuxNative implements LinuxNative {
  FakeLinuxNative({this.backend = LinuxBackend.x11});

  @override
  LinuxBackend backend;

  @override
  bool hasWayland = true;

  @override
  int euid = 1000;

  @override
  int pid = 4242;

  LinuxSessionState session = LinuxSessionState.active;
  int openStatus = 0;
  int status = 0;
  int textStatus = 0;
  final List<Call> calls = [];

  List<LinuxDisplayRecord> monitors = [
    const LinuxDisplayRecord(
      id: 77,
      bounds: Rect.fromLTWH(0, 0, 1920, 1080),
      isPrimary: true,
    ),
  ];
  int monitorReads = 0;
  final Map<int, LinuxWindow> windows = {};
  bool? onWindow = true;
  bool? hasFocus = true;
  bool? ownWindowAt = false;
  bool? ownAppInFront = false;

  bool connected = true;
  bool paused = false;
  int generation = 1;
  List<LinuxDisplayRecord> regions = [
    const LinuxDisplayRecord(id: 1, bounds: Rect.fromLTWH(0, 0, 1600, 900)),
  ];
  bool? wlOwnFront = false;
  bool? wlPointerOver = false;

  bool healthy = true;
  int heartbeatAge = 10;
  int count = 0;
  int devicesLost = 0;
  final Map<LinuxActivityReason, int> reasons = {};
  int starts = 0;
  int stops = 0;

  Iterable<Call> named(String name) => calls.where((c) => c.$1 == name);

  /// The calls as text, `name arg arg`, for comparing.
  List<String> get log => [
    for (final c in calls) [c.$1, ...c.$2].join(' '),
  ];

  /// [named]'s arguments as text.
  List<String> args(String name) => [
    for (final c in named(name)) c.$2.join(' '),
  ];

  @override
  LinuxSessionState sessionState() => session;

  @override
  int x11Open() => openStatus;

  @override
  int x11Move(int x, int y) {
    calls.add(('move', [x, y]));
    return status;
  }

  @override
  int x11Button(int button, {required bool down}) {
    calls.add(('button', [button, down]));
    return status;
  }

  @override
  int x11Key(int code, {required bool down}) {
    calls.add(('key', [code, down]));
    return status;
  }

  @override
  int x11Text(int codepoint) {
    calls.add(('text', [codepoint]));
    return textStatus;
  }

  @override
  void x11TextRestore() => calls.add(('restore', []));

  @override
  List<LinuxDisplayRecord> x11Monitors() {
    monitorReads++;
    return monitors;
  }

  @override
  LinuxWindow? x11Window(int xid) => windows[xid];

  @override
  bool? x11OnWindow(int xid, int x, int y) {
    calls.add(('onWindow', [xid, x, y]));
    return onWindow;
  }

  @override
  bool? x11HasFocus(int xid) => hasFocus;

  @override
  bool? x11OwnWindowAt(int x, int y) => ownWindowAt;

  @override
  bool? x11OwnAppInFront() => ownAppInFront;

  @override
  bool wlConnected() => connected;

  @override
  bool wlPaused() => paused;

  @override
  int wlGeneration() => generation;

  @override
  List<LinuxDisplayRecord> wlRegions() => regions;

  @override
  int wlMove(int region, double x, double y) {
    calls.add(('wlMove', [region, x, y]));
    return status;
  }

  @override
  int wlButton(int button, {required bool down}) {
    calls.add(('wlButton', [button, down]));
    return status;
  }

  @override
  int wlScroll(double dx, double dy, {required bool discrete}) {
    calls.add(('wlScroll', [dx, dy, discrete]));
    return status;
  }

  @override
  int wlKey(int code, {required bool down}) {
    calls.add(('wlKey', [code, down]));
    return status;
  }

  @override
  int wlText(int codepoint) {
    calls.add(('wlText', [codepoint]));
    return textStatus;
  }

  @override
  bool? wlOwnAppInFront() => wlOwnFront;

  @override
  bool? wlPointerOverOwnWindow() => wlPointerOver;

  @override
  bool activityStart() {
    starts++;
    return healthy;
  }

  @override
  void activityStop() => stops++;

  @override
  int activityCount() => count;

  @override
  bool activityHealthy() => healthy;

  @override
  int activityHeartbeatAgeMs() => heartbeatAge;

  @override
  int activityReason(LinuxActivityReason reason) => reasons[reason] ?? 0;

  @override
  int activityLongestGapMs() => 100;

  @override
  int activityDevicesLost() => devicesLost;
}
