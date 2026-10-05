/// The v1 protocol messages (`docs/design.md` §5.2).
///
/// None of these classes override `toString`: key codes, text and positions
/// must never reach logs (`docs/design.md` §6.6).
library;

import 'dart:typed_data';

import 'wire_types.dart';

/// Message type codes.
abstract final class MessageType {
  /// [HostHello].
  static const int hostHello = 0x01;

  /// [Hello].
  static const int hello = 0x02;

  /// [Bye].
  static const int bye = 0x03;

  /// [HostState].
  static const int hostState = 0x04;

  /// [SurfaceMessage].
  static const int surface = 0x05;

  /// [Ping].
  static const int ping = 0x06;

  /// [Pong].
  static const int pong = 0x07;

  /// [PointerMove].
  static const int pointerMove = 0x10;

  /// [PointerButtonMessage].
  static const int pointerButton = 0x11;

  /// [Wheel].
  static const int wheel = 0x12;

  /// [KeyMessage].
  static const int key = 0x20;

  /// [TextMessage].
  static const int text = 0x21;

  /// [ReleaseAll].
  static const int releaseAll = 0x22;

  /// The first ignorable extension type. A receiver drops types from here to
  /// `0xFF` that it doesn't know, without counting a violation.
  static const int firstIgnorable = 0xC0;
}

/// One protocol message, without its header's session tag.
sealed class WireMessage {
  const WireMessage();

  /// The message's type code.
  int get type;
}

/// Host → viewer: offers versions and starts a session.
final class HostHello extends WireMessage {
  /// Creates a [HostHello].
  const HostHello({
    required this.minVersion,
    required this.maxVersion,
    required this.nonce,
    required this.hostPlatform,
    required this.capabilities,
    required this.surfaceEpoch,
    required this.surfaceWidth,
    required this.surfaceHeight,
  });

  @override
  int get type => MessageType.hostHello;

  /// The lowest version the host accepts.
  final int minVersion;

  /// The highest version the host accepts.
  final int maxVersion;

  /// The session nonce, 16 bytes. Its low 16 bits (little-endian) are the
  /// session tag.
  final Uint8List nonce;

  /// The host's OS.
  final PeerPlatform hostPlatform;

  /// Host capability bits (none in v1).
  final int capabilities;

  /// The current surface epoch.
  final int surfaceEpoch;

  /// The shared surface's width in pixels.
  final int surfaceWidth;

  /// The shared surface's height in pixels.
  final int surfaceHeight;
}

/// Viewer → host: picks a version and echoes the nonce.
final class Hello extends WireMessage {
  /// Creates a [Hello].
  const Hello({
    required this.version,
    required this.nonce,
    required this.viewerPlatform,
    required this.capabilities,
  });

  @override
  int get type => MessageType.hello;

  /// The chosen version.
  final int version;

  /// The [HostHello.nonce], echoed.
  final Uint8List nonce;

  /// The viewer's OS (the browser's OS for a web viewer).
  final PeerPlatform viewerPlatform;

  /// Viewer capability bits ([ViewerCapabilities]).
  final int capabilities;
}

/// Why a [Bye] was sent.
enum ByeReason {
  /// The sender closed normally.
  closed(1),

  /// No version in common.
  unsupportedVersion(2),

  /// A reason this version doesn't know.
  other(255);

  const ByeReason(this.code);

  /// The reason's code on the wire.
  final int code;

  /// The reason with [code]; [other] for codes this version doesn't know.
  static ByeReason fromCode(int code) =>
      values.firstWhere((r) => r.code == code, orElse: () => other);
}

/// Either direction: the sender is leaving.
final class Bye extends WireMessage {
  /// Creates a [Bye].
  const Bye(this.reason);

  @override
  int get type => MessageType.bye;

  /// Why.
  final ByeReason reason;
}

/// The host's session state, as `HostState` carries it.
enum HostStateCode {
  /// Input is being injected.
  active(1),

  /// Paused, with a [PauseReason].
  paused(2),

  /// Blocked, with a [BlockReason].
  blocked(3),

  /// Stopped, with a [StopReason].
  stopped(4);

  const HostStateCode(this.code);

  /// The state's code on the wire.
  final int code;

  /// The state with [code], or `null` if there is none.
  static HostStateCode? fromCode(int code) =>
      code >= 1 && code <= values.length ? values[code - 1] : null;
}

/// Host → viewer: the session's state changed.
final class HostState extends WireMessage {
  /// Creates a [HostState].
  const HostState({
    required this.state,
    required this.reason,
    required this.surfaceEpoch,
  });

  @override
  int get type => MessageType.hostState;

  /// The state.
  final HostStateCode state;

  /// The reason's code, in the enum that [state] uses; 0 for active.
  final int reason;

  /// The current surface epoch.
  final int surfaceEpoch;
}

/// Host → viewer: the shared surface changed.
final class SurfaceMessage extends WireMessage {
  /// Creates a [SurfaceMessage].
  const SurfaceMessage({
    required this.surfaceEpoch,
    required this.width,
    required this.height,
  });

  @override
  int get type => MessageType.surface;

  /// The new epoch.
  final int surfaceEpoch;

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;
}

/// Viewer → host: a round-trip probe and heartbeat.
final class Ping extends WireMessage {
  /// Creates a [Ping].
  const Ping({required this.id, required this.viewerMicros});

  @override
  int get type => MessageType.ping;

  /// The probe's id.
  final int id;

  /// The viewer's clock when it sent the probe, in microseconds.
  final int viewerMicros;
}

/// Host → viewer: a [Ping]'s body, echoed.
final class Pong extends WireMessage {
  /// Creates a [Pong].
  const Pong({required this.id, required this.viewerMicros});

  @override
  int get type => MessageType.pong;

  /// The [Ping.id].
  final int id;

  /// The [Ping.viewerMicros].
  final int viewerMicros;
}

/// Viewer → host input. Each carries the session's sequence number.
sealed class InputMessage extends WireMessage {
  const InputMessage(this.seq);

  /// The sequence number, one counter across both channels.
  final int seq;
}

/// Input that names a point on the shared surface.
sealed class PointerMessage extends InputMessage {
  const PointerMessage(
    super.seq, {
    required this.surfaceEpoch,
    required this.x,
    required this.y,
  });

  /// The surface epoch the viewer aimed at.
  final int surfaceEpoch;

  /// The normalized x, 0 to 65535 across the surface.
  final int x;

  /// The normalized y, 0 to 65535 down the surface.
  final int y;
}

/// The pointer moved. Sent on the unreliable channel.
final class PointerMove extends PointerMessage {
  /// Creates a [PointerMove].
  const PointerMove(
    super.seq, {
    required super.surfaceEpoch,
    required super.x,
    required super.y,
    required this.buttons,
    required this.reliableSeq,
  });

  @override
  int get type => MessageType.pointerMove;

  /// The buttons the viewer holds, as a [PointerButton.mask] bitmask.
  final int buttons;

  /// The sequence number of the last reliable input message the viewer
  /// sent before this move, or this move's own [seq] if it sent none. The
  /// host holds the move until that message has arrived, so a move never
  /// overtakes the click before it (`docs/design.md` §5.3).
  final int reliableSeq;
}

/// A button went down or up.
final class PointerButtonMessage extends PointerMessage {
  /// Creates a [PointerButtonMessage].
  const PointerButtonMessage(
    super.seq, {
    required super.surfaceEpoch,
    required super.x,
    required super.y,
    required this.button,
    required this.down,
    required this.clickCount,
  });

  @override
  int get type => MessageType.pointerButton;

  /// The button.
  final PointerButton button;

  /// Whether it went down (rather than up).
  final bool down;

  /// The viewer's click count: 1 for a single click, 2 for a double.
  final int clickCount;
}

/// A scroll.
final class Wheel extends PointerMessage {
  /// Creates a [Wheel].
  const Wheel(
    super.seq, {
    required super.surfaceEpoch,
    required super.x,
    required super.y,
    required this.dx,
    required this.dy,
    required this.unit,
  });

  @override
  int get type => MessageType.wheel;

  /// Horizontal delta; positive scrolls content left (reveals the right).
  final int dx;

  /// Vertical delta; positive scrolls content up (reveals what's below).
  final int dy;

  /// The deltas' unit.
  final WheelUnit unit;
}

/// A physical key, by position.
final class KeyMessage extends InputMessage {
  /// Creates a [KeyMessage].
  const KeyMessage(
    super.seq, {
    required this.usage,
    required this.action,
    required this.modifiers,
  });

  @override
  int get type => MessageType.key;

  /// The USB HID usage, `page << 16 | id`.
  final int usage;

  /// Up, down or repeat.
  final KeyAction action;

  /// The viewer's logical modifier state after the event ([KeyModifiers]).
  final int modifiers;
}

/// Committed text.
final class TextMessage extends InputMessage {
  /// Creates a [TextMessage].
  const TextMessage(super.seq, this.text);

  @override
  int get type => MessageType.text;

  /// The text. Its UTF-8 encoding is at most 1024 bytes.
  final String text;
}

/// Release every key and button this session holds.
final class ReleaseAll extends InputMessage {
  /// Creates a [ReleaseAll].
  const ReleaseAll(super.seq);

  @override
  int get type => MessageType.releaseAll;
}
