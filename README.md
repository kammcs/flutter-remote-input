# remote_input

Remote keyboard and mouse control for Flutter apps. A **viewer** watching someone's shared screen (through any video package) can move the pointer, click, scroll and type, and the **presenter's** app replays that input on their own desktop.

**Any device can be the viewer:** a phone, a tablet, a browser or a desktop. **Windows and macOS desktops can be controlled.**

> **Pre-release, feature complete in code, not yet checked on devices.** Everything in the design is built and unit-tested: the protocol, the safety core, injection on Windows and macOS, the capture widget and the example. Nothing has injected on a real Windows or macOS machine yet, and the viewer's keyboard handling hasn't been tried on real browsers and phones; [docs/checkpoint.md](docs/checkpoint.md) lists those checks. The package isn't on pub.dev (`publish_to: none`), and the API may still change.

> **CI is off for now.** The workflow is kept in `.github/workflows/`, but GitHub Actions is disabled on this repository. `dart format`, `flutter analyze`, `flutter test` and gitleaks run locally before each push.

## What it does

- **A versioned wire protocol** that works over any transport you give it: two message channels, one reliable and one unreliable. WebRTC DataChannels fit; so does a WebSocket. Coordinates are normalized to the shared screen or window, so desktop coordinates never travel.
- **Injection on the presenter's machine:** `SendInput` on Windows (per-monitor DPI, several monitors, a shared window or monitor) and `CGEventPost` on macOS (with Accessibility permission checks and onboarding helpers).
- **Capture on the viewer's side:** `RemoteInputCapture` wraps your remote video view and turns mouse, trackpad, touch and keyboard input (dead keys, IMEs and soft keyboards included) into protocol messages. On phones a **trackpad mode** with its own cursor makes small targets reachable, pinch zooms the local view, and `RemoteKeyBar` adds the keys a soft keyboard lacks.
- **Safety primitives** for your consent experience.

## Platforms

| | Windows | macOS | Linux | Web | iOS | Android |
|---|---|---|---|---|---|---|
| Presenter (is controlled) | Yes, 10 1703+ | Yes, 12+ | Not planned | No | No | Not planned |
| Viewer (controls) | Yes | Yes | Yes | Yes | Yes | Yes |

Browsers and iOS can't inject input into the operating system. Linux under Wayland and Android have no general way to do it that fits a generic package. [The design](docs/design.md#22-platforms) explains each one.

## Using it

```dart
import 'package:remote_input/remote_input.dart';

// Presenter (Windows or macOS), after your app's own consent flow:
if (RemoteInputHost.isSupported) {
  final session = RemoteInputHost().enable(
    link: link,                                  // your InputLink to the granted viewer
    surface: const SharedSurface.display(1),     // or .window(handle), or .rect(bounds)
    options: HostOptions(expiresAt: grantExpiry),
  );
  session.stateChanges.listen(updateBanner);     // active, paused, blocked, stopped
  // ... session.stop() from your Stop button; RemoteInputHost.stopAll() from a hotkey
}

// Viewer (any platform):
final viewer = RemoteInputViewer(link: link);
final capture = RemoteInputCaptureController();
RemoteInputCapture(viewer: viewer, controller: capture, child: SizedBox.expand(child: videoView));
RemoteKeyBar(viewer: viewer, controller: capture); // on touch devices
```

**The transport is yours.** `InputLink` is an interface: implement it over your call's DataChannels or anything message-oriented, bound to one authenticated peer. [`example/cloudflare_realtime_adapter/`](example/cloudflare_realtime_adapter/) is a reference adapter for [`cloudflare_realtime`](https://github.com/kammcs/flutter-cloudflare-realtime). For tests, `package:remote_input/testing.dart` has `MemoryInputLink.pair()` and fakes for the host's OS services.

**The example** ([example/README.md](example/README.md)) shows everything: a **one-machine demo** that runs on every platform (web and phones too) and draws the injected input on a virtual desktop, and **two-machine control** over a development WebSocket link with a pairing code and a consent dialog.

### macOS: the Accessibility permission

A Mac app that hosts remote control needs the **Accessibility** permission to post input events (System Settings → Privacy & Security → Accessibility). Until it's granted, `RemoteInputHost.enable` throws `HostUnavailableException(permissionDenied)`.

```dart
final status = await RemoteInputPermissions.status(); // granted, denied, notRequired (Windows), unsupported
if (status == RemoteInputPermissionStatus.denied) {
  await RemoteInputPermissions.request();      // shows the system prompt, the first time only
  // offer a button for RemoteInputPermissions.openSettings(), and follow
  // RemoteInputPermissions.statusChanges until it says granted
}
```

- macOS shows its prompt only once per app. After that, people turn the switch on in System Settings, so give them a button for `openSettings()`.
- `request()` returns before the person decides; `statusChanges` (checked every second while you listen) reports the grant.
- The grant belongs to your app's **code signature**. Sign with a stable identity (Developer ID for distribution, your team for development), or a rebuilt app may need granting again.
- Under `flutter run` or `flutter test`, macOS may credit the **terminal** instead of the app: grant the terminal while developing.
- Managed Macs can pre-approve the permission with an MDM privacy-preferences (PPPC) profile.
- **The App Sandbox:** nothing in the host needs a sandbox exception, and Apple has said `CGEventPost` works sandboxed once the permission is granted. The device test that confirms it is pending ([checkpoint.md C3](docs/checkpoint.md)).
- Password fields (Secure Event Input), the login window and the lock screen can't be controlled; the session reports `blocked` until they're gone.

### Windows

The host process must be **per-monitor DPI aware (V2)**, as Flutter's default Windows runner is; otherwise `checkAvailable()` reports `dpiUnaware`. Apps run as administrator, UAC prompts, the lock screen and Ctrl+Alt+Del can't be controlled (`RemoteInputHost.limitations` lists these for your UI).

## Safety stance

The package injects input into someone's computer, so:

- **Off by default.** Nothing is injected until your app explicitly enables a session, for one viewer, one link and one shared screen or window.
- **Instant stop.** `stop()` is synchronous; afterwards the package only releases keys and buttons it was holding. `stopAll()` is there for a global revoke hotkey.
- **Local input wins.** When the presenter touches their own mouse or keyboard, injection pauses at once.
- **Rate limits and bounds checks** on every message. Input can't address anything outside the shared surface.
- **No elevated or secure contexts.** It won't drive administrator apps or UAC prompts on Windows, or type into password fields on macOS. It reports when it's blocked.
- **No logging of what anyone types.**

**Consent, banners, grants, revoke hotkeys and audit logs are your app's job.** The package gives you the states and controls to build them on. [The design's §9](docs/design.md#9-how-the-first-consumer-uses-it) shows how its first consumer uses it, including **who can read the input over an SFU**: restrict subscriptions to the input channels on your server.

## Documentation

- [docs/design.md](docs/design.md): scope, coordinates, the transport, the wire protocol, safety, platform injection, viewer capture, the API, the security model and open questions.
- [docs/roadmap.md](docs/roadmap.md): milestones and success criteria.
- [docs/checkpoint.md](docs/checkpoint.md): the device and two-machine checks, with a results table.
- [SECURITY.md](SECURITY.md): reporting vulnerabilities.

## Licence

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
