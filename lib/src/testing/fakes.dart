import 'dart:async';
import 'dart:ui' show Offset, Rect;

import '../host/platform.dart';
import '../protocol/wire_types.dart';
import '../surface.dart';

/// An event a [RecordingInjector] recorded instead of posting.
///
/// Like everything in the package, these don't override `toString`, so
/// recorded input can't leak into logs.
sealed class InjectedEvent {
  const InjectedEvent();
}

/// A recorded [InputInjector.movePointer].
final class InjectedMove extends InjectedEvent {
  /// Creates an [InjectedMove].
  const InjectedMove(this.point, {this.heldButtons = const {}});

  /// The desktop point.
  final Offset point;

  /// The buttons held during the move.
  final Set<PointerButton> heldButtons;

  @override
  bool operator ==(Object other) =>
      other is InjectedMove &&
      other.point == point &&
      other.heldButtons.length == heldButtons.length &&
      other.heldButtons.containsAll(heldButtons);

  @override
  int get hashCode => Object.hash(point, heldButtons.length);
}

/// A recorded [InputInjector.pointerButton].
final class InjectedButton extends InjectedEvent {
  /// Creates an [InjectedButton].
  const InjectedButton(
    this.point,
    this.button, {
    required this.down,
    this.clickCount = 1,
  });

  /// The desktop point.
  final Offset point;

  /// The button.
  final PointerButton button;

  /// Whether it went down.
  final bool down;

  /// The click count.
  final int clickCount;

  @override
  bool operator ==(Object other) =>
      other is InjectedButton &&
      other.point == point &&
      other.button == button &&
      other.down == down &&
      other.clickCount == clickCount;

  @override
  int get hashCode => Object.hash(point, button, down, clickCount);
}

/// A recorded [InputInjector.wheel].
final class InjectedWheel extends InjectedEvent {
  /// Creates an [InjectedWheel].
  const InjectedWheel(
    this.point, {
    required this.dx,
    required this.dy,
    required this.unit,
  });

  /// The desktop point.
  final Offset point;

  /// Horizontal delta.
  final int dx;

  /// Vertical delta.
  final int dy;

  /// The unit.
  final WheelUnit unit;

  @override
  bool operator ==(Object other) =>
      other is InjectedWheel &&
      other.point == point &&
      other.dx == dx &&
      other.dy == dy &&
      other.unit == unit;

  @override
  int get hashCode => Object.hash(point, dx, dy, unit);
}

/// A recorded [InputInjector.key].
final class InjectedKey extends InjectedEvent {
  /// Creates an [InjectedKey].
  const InjectedKey(this.usage, {required this.down, this.repeat = false});

  /// The USB HID usage.
  final int usage;

  /// Whether it went down.
  final bool down;

  /// Whether it was a repeat.
  final bool repeat;

  @override
  bool operator ==(Object other) =>
      other is InjectedKey &&
      other.usage == usage &&
      other.down == down &&
      other.repeat == repeat;

  @override
  int get hashCode => Object.hash(usage, down, repeat);
}

/// A recorded [InputInjector.text].
final class InjectedText extends InjectedEvent {
  /// Creates an [InjectedText].
  const InjectedText(this.text);

  /// The text.
  final String text;

  @override
  bool operator ==(Object other) => other is InjectedText && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

/// An [InputInjector] that records what would have been injected.
final class RecordingInjector implements InputInjector {
  /// Creates a [RecordingInjector]. [onInject] decides each call's result
  /// (default: [InjectResult.injected]); a refused event is still recorded.
  RecordingInjector({this.onInject});

  /// Decides each call's result.
  InjectResult Function(InjectedEvent event)? onInject;

  /// Everything injected, in order.
  final List<InjectedEvent> events = [];

  /// Forgets [events].
  void clear() => events.clear();

  InjectResult _record(InjectedEvent e) {
    events.add(e);
    return onInject?.call(e) ?? InjectResult.injected;
  }

  @override
  InjectResult movePointer(
    Offset point, {
    required Set<PointerButton> heldButtons,
  }) => _record(InjectedMove(point, heldButtons: Set.of(heldButtons)));

  @override
  InjectResult pointerButton(
    Offset point,
    PointerButton button, {
    required bool down,
    required int clickCount,
  }) => _record(
    InjectedButton(point, button, down: down, clickCount: clickCount),
  );

  @override
  InjectResult wheel(
    Offset point, {
    required int dx,
    required int dy,
    required WheelUnit unit,
  }) => _record(InjectedWheel(point, dx: dx, dy: dy, unit: unit));

  @override
  InjectResult key(int usage, {required bool down, bool repeat = false}) =>
      _record(InjectedKey(usage, down: down, repeat: repeat));

  @override
  InjectResult text(String text) => _record(InjectedText(text));
}

/// A [LocalActivityMonitor] driven by the test.
final class FakeLocalActivity implements LocalActivityMonitor {
  final StreamController<void> _activity = StreamController.broadcast(
    sync: true,
  );

  @override
  Stream<void> get activity => _activity.stream;

  /// Whether local input is detected: something listens, and [healthy].
  @override
  bool get isMonitoring => _activity.hasListener && healthy;

  /// Set false to simulate detection failing (Windows hooks removed).
  bool healthy = true;

  /// Reports local input, as if the person at the host touched their mouse
  /// or keyboard.
  void simulateInput() => _activity.add(null);
}

/// A [SecureContextProbe] driven by the test.
final class FakeSecureContext implements SecureContextProbe {
  /// What [check] reports for pointer input.
  BlockReason? pointer;

  /// What [check] reports for keyboard input.
  BlockReason? keyboard;

  @override
  BlockReason? check(InputKind kind, {Offset? point}) =>
      kind == InputKind.pointer ? pointer : keyboard;
}

/// A [SurfaceResolver] with displays and windows the test sets up.
final class FakeSurfaceResolver implements SurfaceResolver {
  /// Creates a resolver with [displayList] (one 1920×1080 primary display
  /// by default).
  FakeSurfaceResolver({List<DisplayInfo>? displays})
    : displayList =
          displays ??
          [
            const DisplayInfo(
              id: 1,
              bounds: Rect.fromLTWH(0, 0, 1920, 1080),
              scaleFactor: 1,
              isPrimary: true,
            ),
          ];

  /// The displays.
  List<DisplayInfo> displayList;

  /// Windows by handle; a missing or `null` entry is a closed window.
  final Map<int, SurfaceGeometry?> windows = {};

  /// Points on a window surface for which another window is on top.
  bool Function(Offset point)? occluded;

  /// Whether a window surface is in front for keys.
  bool keyboardFocus = true;

  /// Points over the host app's own windows.
  bool Function(Offset point)? ownWindowAt;

  /// Whether the host app is in front.
  bool ownAppInFront = false;

  @override
  bool isOwnWindowAt(Offset point) => ownWindowAt?.call(point) ?? false;

  @override
  bool isOwnAppInFront() => ownAppInFront;

  @override
  Future<List<DisplayInfo>> displays() async => List.of(displayList);

  @override
  SurfaceGeometry? resolve(SharedSurface surface) => switch (surface) {
    DisplaySurface(:final displayId) => _display(displayId),
    WindowSurface(:final handle) => windows[handle],
    RectSurface s =>
      s.isClosed
          ? null
          : SurfaceGeometry(bounds: s.bounds, pixelSize: s.pixelSize),
  };

  SurfaceGeometry? _display(int id) {
    for (final d in displayList) {
      if (d.id == id) {
        return SurfaceGeometry(bounds: d.bounds, pixelSize: d.pixelSize);
      }
    }
    return null;
  }

  @override
  bool isOnSurface(SharedSurface surface, Offset point) =>
      !(occluded?.call(point) ?? false);

  @override
  bool hasKeyboardFocus(SharedSurface surface) => keyboardFocus;
}

/// A [HostPlatform] made of fakes, for testing a host without injecting.
final class FakeHostPlatform implements HostPlatform {
  /// Creates a fake platform. Each part defaults to a new fake.
  FakeHostPlatform({
    this.platform = PeerPlatform.windows,
    RecordingInjector? injector,
    FakeSurfaceResolver? surfaces,
    FakeLocalActivity? localActivity,
    FakeSecureContext? secureContext,
  }) : injector = injector ?? RecordingInjector(),
       surfaces = surfaces ?? FakeSurfaceResolver(),
       localActivity = localActivity ?? FakeLocalActivity(),
       secureContext = secureContext ?? FakeSecureContext();

  @override
  PeerPlatform platform;

  @override
  final RecordingInjector injector;

  @override
  final FakeSurfaceResolver surfaces;

  @override
  final FakeLocalActivity localActivity;

  @override
  final FakeSecureContext secureContext;

  /// What [checkAvailable] reports.
  HostUnavailableReason? unavailable;

  @override
  HostUnavailableReason? checkAvailable() => unavailable;
}
