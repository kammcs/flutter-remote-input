# Changelog

## Unreleased

- **M1: protocol, codec and the Dart core.**
  - The v1 wire codec, with golden-byte tests for every message type and a fuzz run of a million inputs. `PointerMove` carries `reliableSeq`, so a move never overtakes the click before it (docs/design.md §5.3).
  - `InputLink` and `InputChannel`, the transport interface.
  - `RemoteInputHost` and `ControlSession`: the handshake, sequencing, stale-move dropping, coalescing, rate limits with an ordered queue, bounds checks, Cmd↔Ctrl mapping, and the safety state machine (off by default, synchronous `stop()` and `stopAll()`, local input wins, blocked states, expiry, heartbeat release, violation and flooding stops).
  - The platform interfaces (`HostPlatform`, `InputInjector`, `SurfaceResolver`, `LocalActivityMonitor`, `SecureContextProbe`). No platform implements them yet, so `RemoteInputHost.isSupported` is false.
  - `RemoteInputViewer`: the viewer's controller, with normalized points.
  - `package:remote_input/testing.dart`: `MemoryInputLink.pair()`, `FakeHostPlatform`, `RecordingInjector` and the other fakes.

- **M0: scaffold and CI.** The plugin scaffold for Windows and macOS, an example app shell that also builds for the viewer platforms, CI (format, analyze, test, gitleaks, and debug builds on Windows and macOS), the gitleaks pre-commit hook, and the design and roadmap. Nothing is implemented yet.
