# remote_input

Remote keyboard and mouse control for Flutter apps. A **viewer** watching someone's shared screen (through any video package) can move the pointer, click, scroll and type, and the **presenter's** app replays that input on their own desktop.

Any device can be the viewer: a phone, a tablet, a browser or a desktop. Windows and macOS desktops can be controlled.

> **Pre-release.** The wire protocol, the host's safety core and the viewer controller are built and tested in pure Dart (milestone M1). The Windows and macOS injectors and the capture widget aren't yet, so nothing is injected on a real machine. The package isn't on pub.dev (`publish_to: none`). The API will change.

> **CI is off for now.** The workflow is kept in `.github/workflows/`, but GitHub Actions is disabled on this repository. `dart format`, `flutter analyze`, `flutter test` and gitleaks run locally before each push.

## What it will do

- **A versioned wire protocol** that works over any transport you give it: two message channels, one reliable and one unreliable. WebRTC DataChannels fit; so does a WebSocket. Coordinates are normalized to the shared screen or window, so desktop coordinates never travel.
- **Injection on the presenter's machine:** `SendInput` on Windows (per-monitor DPI, several monitors, a shared window or monitor) and `CGEventPost` on macOS (with Accessibility permission checks and onboarding helpers).
- **Capture on the viewer's side:** a widget that wraps your remote video view and turns mouse, trackpad, touch and keyboard input (including dead keys and IMEs) into protocol messages.
- **Safety primitives** for your consent experience.

## Platforms

| | Windows | macOS | Linux | Web | iOS | Android |
|---|---|---|---|---|---|---|
| Presenter (is controlled) | Planned | Planned | Not planned | No | No | Not planned |
| Viewer (controls) | Planned | Planned | Planned | Planned | Planned | Planned |

Phones and browsers are first-class viewers, with a trackpad-style touch mode so a desktop can be driven from a small screen. Browsers and iOS can't inject input into the operating system. Linux under Wayland and Android have no general way to do it that fits a generic package. [The design](docs/design.md#22-platforms) explains each one.

## Safety stance

The package injects input into someone's computer, so:

- **Off by default.** Nothing is injected until your app explicitly enables a session, for one viewer, one link and one shared screen or window.
- **Instant stop.** `stop()` is synchronous; afterwards the package only releases keys and buttons it was holding. `stopAll()` is there for a global revoke hotkey.
- **Local input wins.** When the presenter touches their own mouse or keyboard, injection pauses at once.
- **Rate limits and bounds checks** on every message. Input can't address anything outside the shared surface.
- **No elevated or secure contexts.** It won't drive administrator apps or UAC prompts on Windows, or type into password fields on macOS. It reports when it's blocked.
- **No logging of what anyone types.**

**Consent, banners, grants, revoke hotkeys and audit logs are your app's job.** The package gives you the states and controls to build them on. [The design's §9](docs/design.md#9-how-the-first-consumer-uses-it) shows how its first consumer uses it.

## Documentation

- [docs/design.md](docs/design.md): scope, coordinates, the transport, the wire protocol, safety, platform injection, viewer capture, the API sketch, the security model and open questions.
- [docs/roadmap.md](docs/roadmap.md): milestones and success criteria.
- [SECURITY.md](SECURITY.md): reporting vulnerabilities.

## Licence

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
