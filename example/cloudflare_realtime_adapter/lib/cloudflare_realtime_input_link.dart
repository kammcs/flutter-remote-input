/// A remote_input [InputLink] over `cloudflare_realtime` DataChannels, in
/// the layout of remote_input's `docs/design.md` §9:
///
/// | Channel                 | Published by | Profile    |
/// |-------------------------|--------------|------------|
/// | `remote-input/reliable` | viewer       | reliable   |
/// | `remote-input/moves`    | viewer       | unreliable |
/// | `remote-input/host`     | presenter    | reliable   |
///
/// Each side [CloudflareInputLink.publish]es its channels first, then
/// [CloudflareInputLink.attach]es to the one peer it pairs with (the SFU
/// can only subscribe to a channel that is already published). Only that
/// peer's messages pass, identified by the channel's session (the room's
/// [RoomDataMessage.participantId]), never by the payload.
///
/// **Order matters:** the presenter publishes; the viewer publishes,
/// attaches and creates its `RemoteInputViewer`, then asks for control; the
/// presenter, on consent, attaches and calls `RemoteInputHost.enable`. The
/// host sends its handshake once, when the link opens, and the SFU forwards
/// it only to channels already subscribed, so the viewer must be listening
/// first. See README.md.
///
/// **A reconnect ends control.** When either side reconnects, the link
/// reports closed (for good) and the session or viewer on it stops with
/// `linkClosed`. To go on, ask for consent again, [CloudflareInputLink.attach]
/// again and start a new session or viewer on the same link: its published
/// channels survive reconnects.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:remote_input/remote_input.dart';

/// The viewer's channel for buttons, wheel, keys, text and control.
const String reliableChannelName = 'remote-input/reliable';

/// The viewer's channel for pointer moves.
const String movesChannelName = 'remote-input/moves';

/// The presenter's channel to the viewer.
const String hostChannelName = 'remote-input/host';

/// Which end of the link this app is.
enum InputLinkRole {
  /// The presenter, whose computer is controlled (`RemoteInputHost`).
  host,

  /// The person controlling (`RemoteInputViewer`).
  viewer,
}

/// An [InputLink] between this participant and one other in a [Room].
final class CloudflareInputLink implements InputLink {
  CloudflareInputLink._(this._room, this.role, this._outbound, this._moves);

  /// Publishes this side's channels: the two input channels for a viewer,
  /// the host channel for the presenter. Then [attach] to the peer.
  static Future<CloudflareInputLink> publish(
    Room room, {
    required InputLinkRole role,
  }) async {
    if (role == InputLinkRole.host) {
      final out = await room.data.publish(hostChannelName);
      return CloudflareInputLink._(room, role, out, null);
    }
    final out = await room.data.publish(reliableChannelName);
    final moves = await room.data.publish(
      movesChannelName,
      profile: DataChannelProfile.unreliable,
    );
    return CloudflareInputLink._(room, role, out, moves);
  }

  final Room _room;

  /// This side's role.
  final InputLinkRole role;

  final LocalDataChannel _outbound;
  final LocalDataChannel? _moves; // The viewer's; null on the host.
  late _Attachment _current = _Attachment(this); // Closed until attached.
  bool _closed = false;

  /// Subscribes to [peer]'s channels: the granted viewer's, on the host,
  /// or the presenter's, on the viewer. Messages from anyone else are
  /// dropped. Call it after [peer] has published, then create the session
  /// or viewer. It ends the previous attachment first: call it again after
  /// the link reported closed, or to pair with another peer.
  Future<void> attach(RemoteParticipant peer) async {
    if (_closed) throw StateError('The link is closed');
    await detach();
    final a = _current;
    final names = role == InputLinkRole.host
        ? [(reliableChannelName, a.reliableIn), (movesChannelName, a.movesIn)]
        : [(hostChannelName, a.reliableIn)];
    for (final (name, sink) in names) {
      final sub = await _room.data.subscribe(
        peer,
        name,
        profile: name == movesChannelName
            ? DataChannelProfile.unreliable
            : DataChannelProfile.reliable,
      );
      if (a.ended) {
        await sub.close(); // Detached or closed meanwhile.
        return;
      }
      a.subscriptions.add(sub);
      a.listeners
        ..add(
          sub.messages.listen((m) {
            // Sender identity from the channel's session, never the payload.
            final bytes = m.binary;
            if (m.participantId != peer.participantId || bytes == null) return;
            if (!sink.isClosed) sink.add(bytes);
          }, onDone: () => unawaited(a.end())),
        )
        // When the peer reconnects, the subscription closes this channel
        // for a new one: that ends the attachment.
        ..add(sub.channel.stateChanges.listen((_) => a.update()));
    }
    a.listeners.add(_outbound.stateChanges.listen((_) => a.update()));
    a.attached = true;
    a.update();
  }

  /// Ends the current attachment: a session or viewer on the link stops
  /// with `linkClosed`, and the subscriptions to the peer close. The
  /// published channels stay, for the next [attach].
  Future<void> detach() async {
    final old = _current;
    _current = _Attachment(this);
    await old.end();
  }

  @override
  InputChannel get reliable => _current.reliable;

  @override
  InputChannel get unreliable => _current.unreliable;

  /// Detaches, and closes this side's published channels. Final: publish a
  /// new link to pair again.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await detach();
    await Future.wait([_outbound.close(), if (_moves != null) _moves.close()]);
  }
}

/// One pairing with one peer: its subscriptions, and the channels a
/// session or viewer reads. Open once every channel is; closed for good
/// when any of them drops.
final class _Attachment {
  _Attachment(this._link);

  final CloudflareInputLink _link;
  final List<RemoteDataSubscription> subscriptions = [];
  final List<StreamSubscription<Object?>> listeners = [];
  // Single-subscription, so messages that arrive before the session (or
  // viewer) listens are kept for it.
  final StreamController<Uint8List> reliableIn = StreamController();
  final StreamController<Uint8List> movesIn = StreamController();
  final StreamController<bool> open = StreamController.broadcast();
  bool attached = false;
  bool ended = false;
  bool _wasOpen = false;

  late final _Channel reliable = _Channel(this, reliableIn, _link._outbound);
  late final _Channel unreliable = _Channel(this, movesIn, _link._moves);

  bool get isOpen => _wasOpen && !ended;

  void update() {
    if (ended || !attached) return;
    final open = _link._outbound.isOpen && subscriptions.every((s) => s.isOpen);
    if (open && !_wasOpen) {
      _wasOpen = true;
      this.open.add(true);
    } else if (!open && _wasOpen) {
      unawaited(end()); // A drop is final for this attachment.
    }
  }

  Future<void> end() async {
    if (ended) return;
    ended = true;
    if (_wasOpen) open.add(false);
    for (final l in listeners) {
      unawaited(l.cancel());
    }
    // Not awaited: a stream nobody listened to never finishes closing.
    unawaited(reliableIn.close());
    unawaited(movesIn.close());
    await Future.wait([open.close(), for (final s in subscriptions) s.close()]);
  }
}

final class _Channel implements InputChannel {
  _Channel(this._attachment, this._incoming, this._out);

  final _Attachment _attachment;
  final StreamController<Uint8List> _incoming;
  final LocalDataChannel? _out; // Null for the host's moves: it sends none.

  @override
  Stream<Uint8List> get messages => _incoming.stream;

  @override
  bool get isOpen => _attachment.isOpen;

  @override
  Stream<bool> get openChanges => _attachment.open.stream;

  @override
  void send(Uint8List message) {
    final out = _out;
    if (out == null || !isOpen) return;
    // Never blocks; a failed send is a lost message, like on the wire.
    // Future.sync also catches a synchronous throw: the channel can close a
    // microtask before isOpen above follows it.
    unawaited(Future.sync(() => out.send(message)).catchError((Object _) {}));
  }

  @override
  int? get bufferedAmount => _out?.bufferedAmount;
}
