import 'dart:ui';

import 'package:remote_input/remote_input.dart';
import 'package:remote_input/src/host/macos/macos_native.dart';

/// One call the injector made to the native side.
sealed class NativeCall {}

final class MouseCall extends NativeCall {
  MouseCall(this.type, this.point, this.button, this.clickState, this.flags);
  final int type;
  final Offset point;
  final int button;
  final int clickState;
  final int flags;
}

final class ScrollCall extends NativeCall {
  ScrollCall(this.point, this.unit, this.wheel1, this.wheel2, this.flags);
  final Offset point;
  final int unit;
  final int wheel1;
  final int wheel2;
  final int flags;
}

final class KeyCall extends NativeCall {
  KeyCall(this.keyCode, this.down, this.autorepeat, this.flags);
  final int keyCode;
  final bool down;
  final bool autorepeat;
  final int flags;
}

final class TextCall extends NativeCall {
  TextCall(this.units);
  final List<int> units;
  String get text => String.fromCharCodes(units);
}

/// A scriptable [MacosNative] that records what's posted.
final class FakeMacosNative implements MacosNative {
  final List<NativeCall> calls = [];
  bool access = true;
  int accessChecks = 0;
  int postStatus = MacosStatus.ok;
  Offset? cursor = Offset.zero;
  List<DisplayInfo> displayList = const [
    DisplayInfo(
      id: 1,
      bounds: Rect.fromLTWH(0, 0, 1728, 1117),
      scaleFactor: 2,
      isPrimary: true,
    ),
  ];
  int generation = 0;
  int displayReads = 0;
  Map<int, MacosWindowInfo> windows = {};
  int windowReads = 0;

  /// The on-screen windows, front to back; `null` when unreadable.
  List<MacosWindowRecord>? screen = const [];
  int screenReads = 0;
  int frontmost = -1;
  bool secure = false;
  int session = MacosSessionState.active;
  int sessionReads = 0;
  MacosActivityCounts hid = const MacosActivityCounts();
  MacosActivityCounts own = const MacosActivityCounts();
  int snapshots = 0;

  List<MouseCall> get mouse => calls.whereType<MouseCall>().toList();
  List<KeyCall> get keys => calls.whereType<KeyCall>().toList();

  @override
  bool postAccess({required bool fresh}) {
    accessChecks++;
    return access;
  }

  @override
  int postMouse(
    int type,
    Offset point, {
    required int button,
    required int clickState,
    required int flags,
  }) {
    if (postStatus == MacosStatus.ok) {
      calls.add(MouseCall(type, point, button, clickState, flags));
      cursor = point;
    }
    return postStatus;
  }

  @override
  int postScroll(
    Offset point, {
    required int unit,
    required int wheel1,
    required int wheel2,
    required int flags,
  }) {
    if (postStatus == MacosStatus.ok) {
      calls.add(ScrollCall(point, unit, wheel1, wheel2, flags));
    }
    return postStatus;
  }

  @override
  int postKey(
    int keyCode, {
    required bool down,
    required bool autorepeat,
    required int flags,
  }) {
    if (postStatus == MacosStatus.ok) {
      calls.add(KeyCall(keyCode, down, autorepeat, flags));
    }
    return postStatus;
  }

  @override
  int postText(List<int> units) {
    if (postStatus == MacosStatus.ok) calls.add(TextCall(List.of(units)));
    return postStatus;
  }

  @override
  Offset? cursorLocation() => cursor;

  @override
  List<DisplayInfo> displays() {
    displayReads++;
    return displayList;
  }

  @override
  int displayGeneration() => generation;

  @override
  MacosWindowInfo? windowInfo(int windowId) {
    windowReads++;
    return windows[windowId];
  }

  @override
  List<MacosWindowRecord>? onScreenWindows() {
    screenReads++;
    return screen;
  }

  @override
  int ownPid = 7;

  List<int> panelPids = const [];
  int panelReads = 0;

  @override
  List<int> keyboardPanelPids() {
    panelReads++;
    return panelPids;
  }

  @override
  int frontmostPid() => frontmost;

  @override
  bool secureInput() => secure;

  @override
  int sessionState() {
    sessionReads++;
    return session;
  }

  @override
  MacosActivitySnapshot activitySnapshot() {
    snapshots++;
    return MacosActivitySnapshot(
      hid: hid,
      own: own,
      pointer: cursor ?? Offset.zero,
    );
  }
}
