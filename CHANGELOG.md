# Changelog

## Unreleased

- **Feature complete in code; device checks pending** (docs/checkpoint.md).
- **M7 review fixes.** `HostOptions.protectHostWindows` (on by default) keeps viewers out of the host app's own windows; the `KeyFilter` sees repeats and new modifiers; text never acts like keys; no injection while local input is unmonitored (`BlockReason.localInputUnmonitored`); refused releases are retried; window surfaces confine by window ownership on Windows and block keys while Spotlight is open on macOS; local mouse movement is detected while a viewer moves the pointer; the viewer releases everything when its app leaves the foreground, tells the host when it times out, and caps long text (`ViewerOptions.maxTextBytes`); the example limits pairing guesses per address.
- **M2: Windows host.** `SendInput` through the package's own FFI bindings: absolute moves exact at every pixel of the virtual desktop, buttons, both wheel axes, scan-code keys and Unicode text; displays and window surfaces with per-monitor DPI, occlusion and focus; UIPI and secure-desktop detection; a native low-level-hook thread so local input pauses control.
- **M3: macOS host.** `CGEventPost` from a private-state source through `@_cdecl` Swift and FFI: moves, drags, click state, pixel and line scrolling, keys with explicit flags, Unicode text; displays and window surfaces with occlusion and focus; Secure Event Input and inactive-session detection; local input from the HID event counters; `RemoteInputPermissions` for Accessibility onboarding. The example builds from any directory name (open question 17).
- **M4: viewer capture.** `RemoteInputCapture`, `RemoteInputCaptureController` and `RemoteKeyBar`: letterbox-aware mapping, mouse and trackpad with click counting and wheel coalescing, touch in trackpad (default on phones) and direct modes with pinch zoom, and keyboard capture in `auto`, `physical` and `text` modes through a delta text-input client (dead keys, IMEs, soft keyboards).
- **M5: safety.** `RemoteInputHost.limitations` (`HostLimitation`), `BlockReason.windowNotInFront` (keys only), and the native detectors above.
- **M6: example.** A one-machine demo on every platform, two-machine control over a development WebSocket link with pairing and consent, a reference `cloudflare_realtime` adapter, and the runbook `docs/checkpoint.md`.
- **Protocol and API additions:** the host re-sends `HostHello` until answered; `RemoteInputViewer.hostPlatform`, `platform`, `ViewerOptions.hostTimeout` (`StopReason.timedOut`), round-trip percentiles; `KeyModifiers.unmapped` and `sendShortcut(mapModifiers: false)`.

- **M1: protocol, codec and the Dart core.**
  - The v1 wire codec, with golden-byte tests for every message type and a fuzz run of a million inputs. `PointerMove` carries `reliableSeq`, so a move never overtakes the click before it (docs/design.md §5.3).
  - `InputLink` and `InputChannel`, the transport interface.
  - `RemoteInputHost` and `ControlSession`: the handshake, sequencing, stale-move dropping, coalescing, rate limits with an ordered queue, bounds checks, Cmd↔Ctrl mapping, and the safety state machine (off by default, synchronous `stop()` and `stopAll()`, local input wins, blocked states, expiry, heartbeat release, violation and flooding stops).
  - The platform interfaces (`HostPlatform`, `InputInjector`, `SurfaceResolver`, `LocalActivityMonitor`, `SecureContextProbe`). No platform implements them yet, so `RemoteInputHost.isSupported` is false.
  - `RemoteInputViewer`: the viewer's controller, with normalized points.
  - `package:remote_input/testing.dart`: `MemoryInputLink.pair()`, `FakeHostPlatform`, `RecordingInjector` and the other fakes.

- **M0: scaffold and CI.** The plugin scaffold for Windows and macOS, an example app shell that also builds for the viewer platforms, CI (format, analyze, test, gitleaks, and debug builds on Windows and macOS), the gitleaks pre-commit hook, and the design and roadmap. Nothing is implemented yet.
