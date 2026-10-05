# remote_input example

The example app for [`remote_input`](../README.md): **any device controls a Windows or macOS desktop.** One app, three roles:

| Role | Runs on | What it does |
|---|---|---|
| **One-machine demo** | Every platform, web and phones included | Host and viewer in one app over `MemoryInputLink.pair()`, with a drawn presenter's desktop. Click, drag, scroll and type in the viewer's view and watch it injected on the other side. Nothing is injected for real. **Start here.** |
| **Control another computer** | Every platform | The viewer: connects to a host over the development WebSocket link and sends mouse, keyboard and touch input. |
| **Host this computer** | Windows, macOS | The presenter: shows an address and a code, asks before anyone gets control, and replays the viewer's input on a display it shares. |

```sh
flutter run -d macos      # or windows; or chrome, linux, an Android or iOS device as a viewer
```

## The one-machine demo

A real `RemoteInputHost` on a `FakeHostPlatform` from `package:remote_input/testing.dart`: its `RecordingInjector` feeds a drawn desktop instead of the OS, so you see the whole path (capture, protocol, handshake, sequencing, rate limits, the safety state machine) without a second machine.

- The **viewer's view** stands in for the shared screen's video. The **presenter's desktop** shows the cursor, click ripples (thicker for double clicks), drag trails, a Notes window that receives text and keys (Backspace, Enter, Ctrl/⌘+A, C, V, Z), and a list that scrolls.
- **Stop**, **Pause**, **Simulate local input** (local input wins: control pauses, then resumes after 1.5 s), and **Password field focused** (keys are blocked, as Secure Event Input does on a Mac).
- The **settings** button picks the presenter's OS (it decides the Ctrl/⌘ mapping) and adds pointer-move loss and latency to the link.

## Two machines

**Development only.** The WebSocket link is plaintext `ws://`: anyone on the network can read what is typed. Use it on a network you trust. Real apps use an encrypted, authenticated transport, such as the call's WebRTC DataChannels ([below](#cloudflare_realtime)).

1. On the computer to control (Windows or macOS), choose **Host this computer**, pick the display to share, and **Start listening** (TCP port 47800, every IPv4 interface). It shows its LAN addresses and a six-digit code.
2. On the other device, choose **Control another computer** and enter an address and the code.
3. The host asks: **"A viewer wants to control this computer"**, with the name the viewer gave (not verified) and whether to allow the keyboard. Only on **Allow** does it call `host.enable(...)`, with a 30-minute expiry.
4. While a viewer is in control, the host shows a banner with the state (paused while you use your own mouse, blocked reasons, why it stopped), **Stop** and **Pause**, the viewer's platform and counts. Closing the app stops control (`RemoteInputHost.stopAll()`).

Pairing rules: one viewer at a time; each code works once, and five wrong codes replace it.

Notes per viewer platform:

- **Web:** serve the app over `http://` (`flutter run -d chrome`, or `flutter build web` behind a plain HTTP server). A page served over `https://` can't open a `ws://` socket.
- **iOS:** allow the local-network prompt on first connect.
- **macOS:** the app stays sandboxed; it has the network client and server entitlements.

**The viewer shows no video.** The example has no video stack, so the controlled view is a placeholder with the host display's aspect ratio, its size in pixels and a grid that maps onto it ([design.md §13](../docs/design.md#13-open-questions), question 14). Put the two machines side by side and watch the host's screen. A real app wraps its screen-share video in the capture widget instead.

The runbook for the two-machine checks (Windows ↔ macOS, web and phone viewers, mixed DPI, layouts, latency, local input wins, instant stop) is [docs/checkpoint.md](../docs/checkpoint.md).

## Status

- **Hosting needs the injectors.** Until the Windows (M2) and macOS (M3) injectors are in the package, `RemoteInputHost.isSupported` is false, and **Host this computer** explains that and offers the demo.
- **Capture is a stand-in.** [`lib/viewer/capture_view.dart`](lib/viewer/capture_view.dart) is a minimal stand-in for `RemoteInputCapture` (M4): mouse, desktop trackpad scrolling, one-finger direct touch and hardware keys. Trackpad touch mode, pinch-zoom, IMEs and the soft keyboard arrive with the widget. Until then, **Send keys → Type text…** types on phones.
- **macOS permission onboarding** ([`lib/host/permission_onboarding.dart`](lib/host/permission_onboarding.dart)) detects a missing Accessibility permission through `RemoteInputHost.checkAvailable()`; its buttons need `RemoteInputPermissions` (M3).

## Layout

| Path | What |
|---|---|
| `lib/home_page.dart` | The three roles |
| `lib/demo/` | The one-machine demo and the drawn desktop |
| `lib/viewer/` | The viewer screen, the capture view and the placeholder surface |
| `lib/host/` | The host screen and the permission onboarding |
| `lib/links/` | The WebSocket `InputLink` (one socket; a one-byte channel prefix for reliable and unreliable), the host's server (`dart:io`, behind a conditional import so the web build has none) and the viewer's client |
| `cloudflare_realtime_adapter/` | A separate package: the reference `InputLink` over `cloudflare_realtime` DataChannels |

The example never logs what is typed, key codes or positions; it only draws them ([design.md §6.6](../docs/design.md#66-privacy)).

## cloudflare_realtime

[`cloudflare_realtime_adapter/`](cloudflare_realtime_adapter/README.md) is the reference adapter for a call's DataChannels (design.md §9): about 150 lines to copy into an app. It is a separate package, so this example doesn't depend on WebRTC.
