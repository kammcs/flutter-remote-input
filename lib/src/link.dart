import 'dart:typed_data';

/// A two-channel, message-oriented link between one host and one viewer,
/// set up and authenticated by the app (`docs/design.md` §4).
///
/// **Bind each link to exactly one authenticated peer.** The package never
/// reads identity from a message, so an app that receives everyone's
/// messages on a shared channel must pass on only the granted peer's,
/// filtered by the transport's verified sender.
///
/// The package ships no network code. Implement this over WebRTC
/// DataChannels, a WebSocket, or anything message-oriented. For tests and
/// one-process demos, `MemoryInputLink.pair` in `testing.dart` gives a
/// connected pair.
abstract interface class InputLink {
  /// Ordered and retransmitted: buttons, wheel, keys, text and control.
  ///
  /// The session ends when this channel closes.
  InputChannel get reliable;

  /// Unordered, without retransmits: pointer moves only.
  ///
  /// A transport with a single channel may return [reliable] here. Moves
  /// still work, and stale-move dropping keeps them correct.
  InputChannel get unreliable;
}

/// One direction-agnostic message channel of an [InputLink].
abstract interface class InputChannel {
  /// The messages the peer sent, one transport message each. Done when the
  /// channel closes for good.
  Stream<Uint8List> get messages;

  /// Whether messages can be sent now.
  bool get isOpen;

  /// [isOpen]'s changes. It may or may not replay the current value.
  Stream<bool> get openChanges;

  /// Sends [message]. Never blocks; may drop it on an unreliable channel,
  /// and drops it if the channel isn't open.
  void send(Uint8List message);

  /// Bytes queued to send, or `null` when the transport doesn't know.
  int? get bufferedAmount;
}
