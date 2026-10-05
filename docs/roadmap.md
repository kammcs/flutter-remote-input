# Roadmap

Effort is in developer-weeks for the whole package. The total is **about 8–12 weeks** to a reviewed, published 0.1.0. The first consumer's MVP needs M1–M5 at a working level, which the [consumer checkpoint](#consumer-checkpoint-week-4) puts at about week 4.

| # | Milestone | Work | Est. |
|---|---|---|---|
| M0 | Scaffold and CI (**done**) | The plugin scaffold (Windows, macOS), an example app shell that also builds for the viewer platforms (web, Linux, Android, iOS), CI (format, analyze, test, gitleaks, and debug builds of the example on Windows and macOS), the gitleaks pre-commit hook, and these docs | S |
| M1 | Protocol, codec and the host's Dart core (**done**) | The v1 codec ([design.md §5](design.md#5-wire-protocol-v1)) with golden-byte and fuzz tests; `InputLink`/`InputChannel` and `MemoryInputLink.pair()` ([§4](design.md#4-the-transport)); `RemoteInputHost`/`ControlSession` in pure Dart: handshake, sequencing, stale-move dropping, coalescing, the safety state machine with off-by-default, `stop()`/`stopAll()`, rate limits and bounds ([§6](design.md#6-safety-primitives)); `RemoteInputViewer` without the widget; the platform interfaces and their fakes in `testing.dart` (`RecordingInjector` and the others). **The consumer can build its adapter and consent flow against this.** | 1–1.5 wk |
| M2 | Windows injection (**built; Windows device checks pending**) | `SendInput` through FFI: the pointer, buttons, wheel, scan-code keys and Unicode text; displays and the virtual desktop; per-monitor DPI and the DPI-awareness check; window surfaces (`DWMWA_EXTENDED_FRAME_BOUNDS` on every pointer event, minimized, occluded, foreground); the `dwExtraInfo` tag; the HID-to-scan-code table ([§7.2](design.md#72-windows)). Integration tests that inject into the example's own window. Built on the Mac, checked by CI's Windows job, then on a Windows machine | 1.5–2 wk |
| M3 | macOS injection and permissions (**built; injection and sandbox tests pending**) | `CGEventPost` through `@_cdecl` Swift and FFI: the pointer, drags, click state, pixel and line scrolling, `CGKeyCode` keys, Unicode text; displays and window surfaces; `RemoteInputPermissions` (status, request, open Settings, changes) with an onboarding section in the README; the HID-to-`CGKeyCode` table; **the App Sandbox test and its answer** ([§7.3](design.md#73-macos)), sent to the consumer | 1.5–2 wk |
| M4 | Viewer capture (**built; browser and phone checks pending**) | `RemoteInputCapture`: the content rect and letterboxing, mouse, trackpad and touch (**trackpad mode with a drawn cursor, the default on phones, and direct mode**; pinch-to-zoom of the local view), the key bar for soft keyboards, click counting, the keyboard in `auto`, `physical` and `text` modes with a text-input client for dead keys and IMEs, `sendShortcut`, the release shortcut, `ReleaseAll` on blur; checked on Windows, macOS, the web (Chrome, Safari, Firefox), Android and iOS ([§8](design.md#8-viewer-side-capture)) | 1–1.5 wk |
| M5 | Native safety primitives (**built; timing checks pending**) | Local input wins on Windows (low-level hooks on a native thread) and macOS (open question 2); elevated and secure-desktop detection on Windows; Secure Event Input and an inactive session on macOS; `blocked` states end to end; `RemoteInputHost.limitations`; timing tests against the targets below ([§6.3](design.md#63-local-input-wins), [§6.5](design.md#65-no-injection-into-elevated-or-secure-contexts)) | 1–1.5 wk |
| M6 | Example app: two-machine control (**done**) | Host and viewer roles in one app; a WebSocket link for a LAN (development only) and the in-memory link for a one-machine demo with a drawn cursor; a reference `cloudflare_realtime` DataChannel adapter ([§9](design.md#9-how-the-first-consumer-uses-it); in the example only, never in `lib/`); the latency read-out; `docs/checkpoint.md`, the runbook for the two-machine checks | 1 wk |
| M7 | Hardening and the security review | Fuzzing at scale, multi-monitor and mixed-DPI rigs, more layouts and IMEs, long sessions (stuck keys, sleep and wake, display changes, a shared window closing), the success criteria run in full, and **an independent security review before the first consumer's pilot** ([§11](design.md#11-security-model-and-threats)), with findings fixed or documented | 1.5–2.5 wk |
| M8 | Publish to pub.dev | API review, dartdoc, the README's setup guides (macOS permission and sandbox, Windows DPI awareness), platform listing (open question 16), pana, remove `publish_to: none`, 0.1.0. Held until the first consumer has validated the package; until then it pins a commit from git | S–M |

M4 can run alongside M2 and M3. M5's Windows half needs M2, and its macOS half needs M3.

## Consumer checkpoint (week 4)

The first consumer (buildIt.Social) plans its Phase 6 MVP, remote control in its calls, at **4–6 weeks**, and **6–10 weeks hardened**. Its app-side work (consent, grants, banner, revoke hotkey, audit log, the DataChannel adapter) runs in parallel and needs this package in stages:

| By | What the consumer needs | Milestones |
|---|---|---|
| **Week 2** | The host and viewer APIs with fakes: `InputLink`, `RemoteInputHost`/`ControlSession` with every state and reason, `RemoteInputViewer`, `memoryPair()` and `RecordingInjector`. It builds its adapter, consent flow and banner against them. | M1 |
| **Week 4: checkpoint** | All of the list below, through the consumer's own call DataChannels. | M2, M3, M4 and a basic M5 |
| **Week 6: MVP** | Window surfaces, multiple monitors and mixed DPI, non-US layouts and IMEs, the elevated and secure-input blocks, final rate limits, the latency targets met. | M2–M5 complete, M6 |
| **Week 6–10: hardened** | The security review done and its findings closed, and the full success criteria. | M7 |

**The week-4 checkpoint passes** when, between a Windows machine and a Mac, **in both directions**, over the consumer's call:

1. The viewer moves, clicks, double-clicks, drags and scrolls on a shared **display**, and lands where they aim.
2. The viewer types US-layout text, Enter, Backspace, the arrows and copy/paste shortcuts.
3. `stop()` ends control at once with nothing left held down, and **local input wins** pauses it.
4. macOS: the permission flow works, and the App Sandbox answer is in.

If it doesn't pass, the consumer narrows its MVP (for example, one presenter platform first, or pointer and text before full keyboard) rather than switching packages, and this roadmap is re-planned. **So until week 4, favour the checkpoint's paths over polish:** display surfaces before window surfaces, US layouts before IMEs, and the Dart safety core before the native detectors' edge cases.

## Success criteria

Release 0.1.0 (M8) needs all of these, measured with the example app and recorded in `docs/checkpoint.md`:

1. **Windows ↔ macOS in both directions:** a Windows viewer controls a Mac, and a Mac viewer controls a Windows PC, with the example app and in the first consumer's call. A web viewer and a phone viewer control each kind of presenter too.
2. **Correct coordinates on mixed-DPI, multi-monitor setups:**
   - **Windows:** at least two monitors at different scales (100 % and 150 %), one left of or above the primary (negative coordinates).
   - **macOS:** a Retina display and a non-Retina external one, arranged left of or above the main display.
   - Clicks at the four corners and the centre of every display, and of a shared window on each, land within **1 physical pixel** (Windows) or **1 point** (macOS) of the target. Measured by the integration tests (injecting into the app's own window), and by hand through a capture.
3. **Text, including non-US layouts and IMEs:**
   - With the viewer on a US, German (QWERTZ), French (AZERTY) and a Cyrillic layout, against a presenter on US and German layouts, text arrives exactly, including dead-key characters (é, ñ, ü), AltGr characters and emoji.
   - A CJK IME on the viewer (Japanese or Chinese pinyin) commits exactly the chosen text.
   - Copy, paste, select all and undo work across operating systems with the modifier mapping.
4. **Latency, typical case (proposed targets):**
   - **Host overhead** (message received → OS call returned): p50 ≤ 1 ms, p95 ≤ 5 ms.
   - **Viewer overhead** (Flutter event → message handed to the transport): p95 ≤ 2 ms.
   - **Over a LAN** (the WebSocket link, wired or good Wi-Fi), input round trip by `Ping`: p50 ≤ 20 ms, p95 ≤ 50 ms.
   - **Over an SFU DataChannel** in the same region: input round trip p50 ≤ 80 ms, p95 ≤ 150 ms. The package adds at most the overheads above; the rest is the network.
   - **Under 2 % packet loss,** pointer moves stay smooth at 60 Hz or more, with no backlog: stale moves are dropped, never queued.
5. **Local input wins within a stated time:** injection is paused **within 50 ms (Windows) or 100 ms (macOS)** of the first local key, click or pointer movement past the threshold. Held injected keys and buttons are released within 100 ms, and nothing is injected while paused.
6. **Instant stop:** after `stop()` returns, nothing is injected except releases of what the session held, and those complete within 50 ms.
7. **Tests:**
   - Unit tests for the codec (golden bytes for every message, round trips, a fuzz run of at least a million inputs with no exceptions) and the safety logic (every state and reason, rate limits, sequencing and wrap, timeouts), at **≥ 90 % line coverage** of the protocol and safety code.
   - Widget tests for capture.
   - Integration tests on Windows and macOS that inject into the example's own window.
8. **pub.dev readiness:** every public member documented, an example, a README with setup guides, platforms listed, no `pana` warnings, and the highest score pana allows (any gap explained in the changelog).
9. **The security review is done,** with every finding fixed or documented as an accepted risk in [design.md §11](design.md#11-security-model-and-threats).

## Testing

- **Every change:** `dart format .`, `flutter analyze`, `flutter test` (root and `example/`). CI also builds the example on Windows and macOS.
- **Windows can't be built on the Mac** this package is developed on. A Windows change is checked first by CI's `windows` job, then on a Windows machine by the owner or the buildIt Windows session (CLAUDE.md, Related projects). Say which applies in each report.
- **Injection tests move the real pointer.** Run them only when the owner says the machine is free, and inject only into the test app's own window ([design.md §12](design.md#12-testing-strategy)).

## Open gaps

- **Feature complete in code (2026-10-05).** M1–M6 are built and unit-tested on macOS: 398 package tests and 30 in the example; line coverage about 99 % for the protocol, 95 % for the session core, 93–98 % for the viewer and the platform code. The Windows C++ was compile-checked with mingw-w64; the macOS Swift builds in debug and release, with SwiftPM and CocoaPods.
- **M7's first review pass is done (2026-10-05):** an independent safety and security review of the host and both injectors, and a correctness review of the viewer, the capture widget and the example. Every finding is fixed or recorded as an accepted risk in [design.md §11](design.md#11-security-model-and-threats); the largest was that a viewer could operate the host app's own windows (now `HostOptions.protectHostWindows`). M7's device work (mixed DPI rigs, layouts and IMEs, long sessions) and **an external review before the consumer's pilot** remain.
- **Nothing has run on a device yet.** [checkpoint.md](checkpoint.md) Part C is the device checks per host platform (Windows injection and hooks; the macOS permission, the injection integration test and **the App Sandbox test**), then Parts A and B. These are the next step, and the consumer checkpoint depends on them.
- **Over an SFU, other call members could read the viewer's input** unless the consumer's server restricts subscriptions to the input channels ([design.md §9](design.md#9-how-the-first-consumer-uses-it)). Whether the package should also offer end-to-end encryption is open question 12.
- [design.md §13](design.md#13-open-questions) lists what's still open: device verification of 1, 2, 3 and 10; 12, 13, 15, 16 and 18.
