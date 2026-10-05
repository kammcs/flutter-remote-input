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
  final List<RemoteDataSubscription> _subscriptions = [];
  final List<StreamSubscription<Object?>> _listeners = [];
  // Single-subscription, so messages that arrive before the session (or
  // viewer) listens are kept for it.
  final StreamController<Uint8List> _reliableIn = StreamController();
  final StreamController<Uint8List> _movesIn = StreamController();
  final StreamController<bool> _open = StreamController.broadcast();
  bool _attached = false;
  bool _wasOpen = false;

  /// Subscribes to [peer]'s channels: the granted viewer's, on the host,
  /// or the presenter's, on the viewer. Messages from anyone else are
  /// dropped. Call once, after [peer] has published.
  Future<void> attach(RemoteParticipant peer) async {
    if (_attached) throw StateError('Already attached');
    _attached = true;
    final names = role == InputLinkRole.host
        ? [(reliableChannelName, _reliableIn), (movesChannelName, _movesIn)]
        : [(hostChannelName, _reliableIn)];
    for (final (name, sink) in names) {
      final sub = await _room.data.subscribe(
        peer,
        name,
        profile: name == movesChannelName
            ? DataChannelProfile.unreliable
            : DataChannelProfile.reliable,
      );
      _subscriptions.add(sub);
      _listeners
        ..add(
          sub.messages.listen((m) {
            // Sender identity from the channel's session, never the payload.
            final bytes = m.binary;
            if (m.participantId != peer.participantId || bytes == null) return;
            sink.add(bytes);
          }, onDone: () => close()),
        )
        ..add(sub.channel.stateChanges.listen((_) => _onStateChanged()));
    }
    _listeners.add(_outbound.stateChanges.listen((_) => _onStateChanged()));
    _onStateChanged();
  }

  bool get _isOpen =>
      _attached &&
      _outbound.isOpen &&
      _subscriptions.isNotEmpty &&
      _subscriptions.every((s) => s.isOpen);

  void _onStateChanged() {
    final open = _isOpen;
    if (open == _wasOpen || _open.isClosed) return;
    _wasOpen = open;
    _open.add(open);
  }

  @override
  late final InputChannel reliable = _Channel(this, _reliableIn, _outbound);

  @override
  late final InputChannel unreliable = _Channel(this, _movesIn, _moves);

  /// Closes the link and this side's channels. A session on it stops with
  /// `StopReason.linkClosed`.
  Future<void> close() async {
    if (_open.isClosed) return;
    if (_wasOpen) _open.add(false);
    for (final l in _listeners) {
      unawaited(l.cancel());
    }
    // Not awaited: a stream nobody listened to never finishes closing.
    unawaited(_reliableIn.close());
    unawaited(_movesIn.close());
    await Future.wait([
      _open.close(),
      for (final s in _subscriptions) s.close(),
      _outbound.close(),
      if (_moves != null) _moves.close(),
    ]);
  }
}

final class _Channel implements InputChannel {
  _Channel(this._link, this._incoming, this._out);

  final CloudflareInputLink _link;
  final StreamController<Uint8List> _incoming;
  final LocalDataChannel? _out; // Null for the host's moves: it sends none.

  @override
  Stream<Uint8List> get messages => _incoming.stream;

  @override
  bool get isOpen => _link._isOpen;

  @override
  Stream<bool> get openChanges => _link._open.stream;

  @override
  void send(Uint8List message) {
    final out = _out;
    if (out == null || !isOpen) return;
    // Never blocks; a failed send is a lost message, like on the wire.
    unawaited(out.send(message).catchError((Object _) {}));
  }

  @override
  int? get bufferedAmount => _out?.bufferedAmount;
}
