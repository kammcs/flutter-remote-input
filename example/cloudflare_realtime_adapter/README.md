# remote_input over cloudflare_realtime: a reference adapter

An `InputLink` for [`remote_input`](../../README.md) over the DataChannels of [`cloudflare_realtime`](https://github.com/kammcs/flutter-cloudflare-realtime), in the layout of [design.md §9](../../docs/design.md#9-how-the-first-consumer-uses-it). About 200 lines, in [`lib/cloudflare_realtime_input_link.dart`](lib/cloudflare_realtime_input_link.dart).

It is a **reference to copy into an app**, not a published package. It is kept apart from the example app, so the example doesn't pull in WebRTC, and `remote_input` itself never depends on a transport.

| Channel | Published by | Profile | Subscribed by |
|---|---|---|---|
| `remote-input/reliable` | viewer | reliable | the presenter, only from the granted viewer |
| `remote-input/moves` | viewer | unreliable | the presenter, only from the granted viewer |
| `remote-input/host` | presenter | reliable | the granted viewer |

## Use

Order matters. The host sends its handshake once, when its link opens, and the SFU forwards a message only to channels that are already subscribed. So the viewer must be listening before the presenter attaches:

```dart
// Presenter, early (for example when it starts sharing its screen):
final hostLink = await CloudflareInputLink.publish(room, role: InputLinkRole.host);

// Viewer, before it asks for control:
final viewerLink = await CloudflareInputLink.publish(room, role: InputLinkRole.viewer);
await viewerLink.attach(presenter);              // subscribes to remote-input/host
final viewer = RemoteInputViewer(link: viewerLink);
// ...then the app sends its request for control.

// Presenter, once the person has allowed it and the app has recorded the grant:
await hostLink.attach(grantedViewer);            // subscribes to the viewer's two channels
final session = RemoteInputHost().enable(
  link: hostLink,
  surface: SharedSurface.display(displayId),     // or .rect fed from ScreenShareSource geometry
  options: HostOptions(expiresAt: grantExpiry),
);

// After a reconnect (the link reported closed), once consent is given again:
await hostLink.attach(grantedViewer);            // a fresh attachment on the same link
final next = RemoteInputHost().enable(link: hostLink, surface: ...);

// Either side, when done with this peer:
await hostLink.detach();                         // the session stops with linkClosed
// ...or for good, which also unpublishes this side's channels:
await hostLink.close();
```

- **Sender identity** comes from `RoomDataMessage.participantId`, which `cloudflare_realtime` derives from the channel's session and the room's signaling, never from the payload. Messages from anyone but the attached peer are dropped. Bind `grantedViewer` to the participant your server granted.
- **A reconnect ends control; the link is reused.** If either side reconnects (the room's own reconnect, or the peer's, which makes `cloudflare_realtime` move the subscription to a new channel), the link reports closed and the session or viewer on it stops with `linkClosed`. That `false` is final for the attachment: the link stays closed rather than reopening under a stopped session. remote_input never carries control across a reconnect, so ask for consent again, then call `attach` again and start a new session (or viewer); it reads the new attachment's channels. Published channels survive reconnects, so there's no need to publish again. `close()` is final.
- **Create the session or viewer after `attach`.** Each attachment has its own channels; one created before `attach` belongs to the previous attachment and stops when `attach` begins.
- **Web viewers:** a browser endpoint of an unreliable channel still retransmits (a `dart_webrtc` limitation that `cloudflare_realtime` documents). Stale-move dropping keeps the pointer correct; moves may arrive later under loss.

## Security notes

- The SFU forwards a published channel to **every participant that subscribes to it**. Another participant in the same call who knows the viewer's session can subscribe to `remote-input/reliable` and read what the viewer types, passwords included. DTLS protects the traffic from the network, not from other members of the call. Until remote_input or the app adds end-to-end protection, grant control only in calls whose members you trust. This is listed for the security review (roadmap M7).
- The presenter's `remote-input/host` channel carries only the session's state, surface size and pings: no input.

## Checking it

```sh
cd example/cloudflare_realtime_adapter
flutter pub get        # resolves cloudflare_realtime from git: needs network
flutter analyze
```

It is excluded from the root's and the example's `flutter analyze`, so those don't need WebRTC or network. Pin `cloudflare_realtime` to a commit (`ref:`) in an app.
