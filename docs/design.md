# Design: `remote_input`

This package lets one person control another person's desktop with their keyboard and mouse, from inside a Flutter app. The **viewer** sees the **presenter's** shared screen (as video, from some other package), and their pointer and keyboard events over that view are captured, sent as a small versioned protocol over a transport the app provides, and **replayed as local input on the presenter's desktop**.

- **Status:** pre-release (October 2026). M0 (scaffold) and M1 (the protocol, the codec, the host's Dart core, the viewer controller and the test fakes) are done. The platform injectors (M2, M3), the capture widget (M4) and the native safety detectors (M5) aren't built yet; for those, this document is the plan.
- **Companion docs:** [roadmap.md](roadmap.md) (milestones, success criteria, the consumer checkpoint).
- Statements marked **(verify)** are believed true from documentation or forum answers but haven't been checked on a device. Each one has a milestone that checks it, and the result replaces the mark.

## Contents

1. [Why this package exists](#1-why-this-package-exists)
2. [Scope](#2-scope)
3. [Coordinates and the shared surface](#3-coordinates-and-the-shared-surface)
4. [The transport](#4-the-transport)
5. [Wire protocol v1](#5-wire-protocol-v1)
6. [Safety primitives](#6-safety-primitives)
7. [The host and platform injection](#7-the-host-and-platform-injection)
8. [Viewer-side capture](#8-viewer-side-capture)
9. [How the first consumer uses it](#9-how-the-first-consumer-uses-it)
10. [Public API sketch](#10-public-api-sketch)
11. [Security model and threats](#11-security-model-and-threats)
12. [Testing strategy](#12-testing-strategy)
13. [Open questions](#13-open-questions)

## 1. Why this package exists

- **No video SDK does remote control.** Not Cloudflare's SFU, not LiveKit, not the others. They carry media and app messages; turning a viewer's clicks into input on the presenter's machine is app-level work, and the same work whichever SFU is used.
- **There is no maintained, permissively licensed Flutter package for it.** The best-known open-source remote desktop built on Flutter, RustDesk, is AGPL, so its code can't be reused here (see the licensing rules in [CLAUDE.md](../CLAUDE.md)).
- **Injection is generic and platform-bound.** It can be built, tested and security-reviewed on its own, without any particular app. Who may control, and when, is each app's policy; that stays in the app (§9).

The first consumer is buildIt.Social, a private app with chat, video calls and screen sharing on [`cloudflare_realtime`](https://github.com/kammcs/flutter-cloudflare-realtime). Its call's DataChannels are the expected transport. **This package must not depend on either.**

## 2. Scope

### 2.1 What the package does

1. **A wire protocol** (§5): transport-agnostic, versioned, compact binary. Normalized coordinates relative to the shared surface; pointer moves on an unreliable channel; buttons, wheel, keys and text on a reliable channel; physical keys and text as two paths; sequence numbers and stale-move dropping.
2. **Injection on the presenter's machine** (§7):
   - **Windows:** `SendInput` through `dart:ffi`, with per-monitor DPI, virtual-desktop coordinates across monitors, and mapping to a shared monitor or window.
   - **macOS:** `CGEventPost`, in Swift inside the plugin, with the Accessibility permission checks and onboarding helpers, and a tested answer for the App Sandbox (§7.3).
3. **Viewer-side capture** (§8): a widget and a controller that turn pointer, touch and keyboard events over a remote video view into protocol messages, on every platform Flutter runs on.
4. **Safety primitives** (§6) that apps build their consent experience on: off by default, instant stop, local input wins, rate limits and bounds checks, and no injection into elevated or secure-input contexts.

### 2.2 Platforms

**The goal: any device can control a desktop.** A phone, a tablet, a browser, or another desktop runs the viewer; a Windows PC or a Mac is controlled. Phones and browsers are first-class viewers, not an afterthought: touch input gets its own modes (§8), and the soft keyboard goes through the text path (§5.4). Phones themselves can't be controlled (below).

| Role | Windows | macOS | Linux | Web | iOS | Android |
|---|---|---|---|---|---|---|
| **Presenter** (host: injects) | Yes, Windows 10 1703+ | Yes, macOS 12+ | Not planned | No | No | Not planned |
| **Viewer** (captures) | Yes | Yes | Yes | Yes | Yes (touch, keyboards) | Yes (touch, keyboards) |

Why the presenter side stops at Windows and macOS:

- **Linux:** X11's XTest extension could inject, but most distributions now default to **Wayland**, which has no general injection API for applications. The route there is the `xdg-desktop-portal` RemoteDesktop portal with libei, which behaves differently per compositor and asks the user for each session. No consumer needs it yet. It can be revisited on demand, as a separate injector behind the same interface.
- **Web:** a browser page can't create operating-system input, by design.
- **iOS:** there is no public API for injecting input into other apps.
- **Android:** the only route is an `AccessibilityService` (`dispatchGesture`, which does touch gestures but no general keyboard). Google Play restricts accessibility services to accessibility use cases and requires a prominent disclosure, which doesn't fit a generic package.

The library **imports and compiles everywhere** (the viewer runs everywhere). `dart:ffi` and `dart:io` stay behind conditional imports, and on a platform without an injector `RemoteInputHost.isSupported` is `false`.

### 2.3 Out of scope: the app's job

These need the app's identity, server and UI, so the package provides the primitives and the app builds them (§9):

- **Consent:** asking the presenter, and showing who asked.
- **The persistent "X is controlling your screen" banner and the border** around the shared surface.
- **Grants:** server-side records of who may control whom, with expiry, checked against the viewer's verified identity.
- **The revoke hotkey and its UI.** The package gives an instant `stop()` and a process-wide `stopAll()` for it to call; registering a global hotkey is the app's (or another package's) job.
- **Audit logs.** The package reports session starts, stops and their reasons; the app records them.
- Clipboard sync, file transfer, cursor-shape streaming, audio, multi-viewer control (one controller at a time in v1), and unattended access. Possible later; not planned.

## 3. Coordinates and the shared surface

### 3.1 On the wire: normalized, never absolute

The viewer sends a point as two **unsigned 16-bit values, 0 to 65535**, across the **content rect** of the remote video as it is rendered: the part of the view that shows the picture, **excluding letterbox or pillarbox bars**. 0 is the left (top) edge of the first pixel and 65535 the right (bottom) edge of the last.

- Desktop coordinates never appear on the wire, so a viewer can't address anything outside the shared surface (§11).
- 65,536 steps across an 8K-wide display is about 0.12 pixels per step: finer than needed.
- While a button is held, a pointer that leaves the content rect is clamped to its edge, so drags to an edge work. Without a button, moves outside it aren't sent.

### 3.2 On the host: the shared surface

The host maps a normalized point onto a **`SharedSurface`**, whose bounds are read in **each operating system's own desktop coordinates**, the ones its input APIs take:

- **macOS:** points in Core Graphics' global display space (`CGDisplayBounds`, `CGEvent` locations). The origin is the primary display's top-left corner and y grows downwards; displays left of or above it have negative coordinates.
- **Windows:** physical pixels of the virtual screen, as a per-monitor-DPI-aware process sees them (`GetMonitorInfo`, `SetCursorPos`). The origin is the primary monitor's top-left corner; monitors left of or above it are negative. With mixed scale factors there is no common logical unit, so no conversion is made.

This is the same convention as `cloudflare_realtime`'s `ScreenGeometry`, so a consumer on that package can pass its geometry straight through. The package doesn't depend on it.

Surface kinds:

| Kind | Bounds | When they're read |
|---|---|---|
| `SharedSurface.display(id)` | A display or monitor, from the package's own `RemoteInputHost.displays()` list | Cached; refreshed on display-configuration changes |
| `SharedSurface.window(handle)` | One top-level window: an `HWND` on Windows, a `CGWindowID` on macOS | **Before every pointer event** on Windows (`DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)` is cheap); on macOS with a short cache (`CGWindowListCopyWindowInfo` is slower; open question 4) |
| `SharedSurface.rect(bounds)` | Supplied by the app, which updates them with `surface.update(bounds)` (for example from a screen-share package's geometry stream) | When the app updates them |

Mapping, for a surface with bounds `(left, top, width, height)` and a wire value `v`:

```
x = left + (v + 0.5) * width / 65536        (and the same for y)
```

- **macOS** posts the point as is (fractional points are fine).
- **Windows** rounds to a pixel, then converts to `SendInput`'s absolute range over the virtual desktop with `MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK | MOUSEEVENTF_MOVE`. The documented normalization has a known off-by-one; the injector is tested by reading `GetCursorPos` back after each corner and centre (§12), and falls back to `SetCursorPos` plus a zero relative move if the absolute form can't be made exact (open question 3).
- **DPI awareness:** on Windows the host process must be **per-monitor DPI aware (V2)**, as Flutter's default runner manifest is. Otherwise Windows virtualizes the coordinates. The injector checks the thread's awareness context at start and refuses to start without it (`HostUnavailableReason.dpiUnaware`).

### 3.3 Surface epochs and captured content

- **Epochs.** Every surface change (another display chosen, a window replaced) increments a 16-bit **surface epoch**. The host announces it, the viewer stamps every pointer message with the epoch it was aimed at, and the host drops pointer messages for an old epoch. A click aimed at the old screen never lands on the new one.
- **Size.** The host announces the surface's pixel size with the epoch, so a viewer can lay out its content rect before the first video frame. Once frames arrive, the video's own frame size is authoritative for the viewer's mapping, because that is what's rendered.
- **Captured content vs. bounds (verify).** A window capture may include or exclude the title bar, shadow or borders, depending on the capturer. If the picture and the bounds disagree, clicks land offset. `SharedSurface` takes optional `contentInsets` for this, and M2/M3 calibrate the defaults by clicking known targets in a captured test window on each platform.

## 4. The transport

The package defines the transport as an interface and ships no network code in `lib/`:

```dart
/// A two-channel, message-oriented link between one host and one viewer,
/// set up and authenticated by the app.
abstract interface class InputLink {
  /// Ordered and retransmitted: buttons, wheel, keys, text and control.
  InputChannel get reliable;

  /// Unordered, without retransmits: pointer moves only. A transport with
  /// a single channel may return [reliable] here; moves then still work,
  /// with stale-move dropping keeping them correct.
  InputChannel get unreliable;
}

abstract interface class InputChannel {
  Stream<Uint8List> get messages;
  bool get isOpen;
  Stream<bool> get openChanges;
  /// Never blocks. May drop a message on the unreliable channel.
  void send(Uint8List message);
  /// Bytes queued, or null when the transport doesn't know.
  int? get bufferedAmount;
}
```

- **One link per host session and viewer, bound by the app to one authenticated peer.** The package never reads identity from a payload. A link must deliver messages from that peer only: an app that receives everything on a shared channel filters by the transport's verified sender before passing messages on (§11).
- **Backpressure.** The viewer coalesces moves to one per frame and skips a move when the unreliable channel's `bufferedAmount` is above a threshold (16 KiB by default). Moves are never queued behind each other.
- **In the package:** `MemoryInputLink.pair()` (in `testing.dart`): an in-memory pair for tests and single-process demos, with optional loss, reordering and delay. (A static on `InputLink` itself can't live in `testing.dart`, hence the separate class.)
- **In the example (M6):** a WebSocket link for two machines on a LAN (both channels on one socket; **plaintext, development only**), and a reference adapter for `cloudflare_realtime`'s DataChannels (§9).

## 5. Wire protocol v1

Binary, **little-endian**, one protocol message per transport message (WebSockets and DataChannels are message-oriented, so there is no framing). The codec is pure Dart, allocation-bounded, and never throws on bad input: a message that can't be decoded is dropped and counted (§6.4).

### 5.1 Header

Every message starts with:

| Field | Type | Meaning |
|---|---|---|
| `type` | u8 | Message type (below) |
| `sessionTag` | u16 | The low 16 bits of the session nonce from `HostHello`. Messages for another session are dropped. |

Viewer-to-host input messages then carry:

| Field | Type | Meaning |
|---|---|---|
| `seq` | u32 | One counter per session **across both channels**, incremented per message, compared with serial-number arithmetic (RFC 1982), so it may wrap. |

### 5.2 Messages

**Handshake and control** (reliable):

| Type | Name | Direction | Body |
|---|---|---|---|
| `0x01` | `HostHello` | host → viewer | `minVersion u8`, `maxVersion u8`, `nonce [16]`, `hostPlatform u8`, `capabilities u32`, `surfaceEpoch u16`, `surfaceWidth u32`, `surfaceHeight u32` (pixels) |
| `0x02` | `Hello` | viewer → host | `version u8` (chosen), `nonce [16]` (echoed), `viewerPlatform u8`, `capabilities u32` |
| `0x03` | `Bye` | either | `reason u8` |
| `0x04` | `HostState` | host → viewer | `state u8` (active, paused, blocked, stopped), `reason u8`, `surfaceEpoch u16` |
| `0x05` | `Surface` | host → viewer | `surfaceEpoch u16`, `width u32`, `height u32` |
| `0x06` | `Ping` | viewer → host | `id u32`, `viewerMicros u64` |
| `0x07` | `Pong` | host → viewer | the `Ping`'s body echoed |

The host sends `HostHello` when the app enables a session and the link is open. Input is dropped until the viewer's `Hello` echoes the nonce and picks a version both support.

**Input** (viewer → host; every body follows `seq`):

| Type | Name | Channel | Body |
|---|---|---|---|
| `0x10` | `PointerMove` | unreliable | `surfaceEpoch u16`, `x u16`, `y u16`, `buttons u8` (held, as a bitmask; a consistency check), `reliableSeq u32` (the last reliable input sent before this move, or the move's own `seq` if none; §5.3) |
| `0x11` | `PointerButton` | reliable | `surfaceEpoch u16`, `x u16`, `y u16`, `button u8` (left, right, middle, back, forward), `down u8`, `clickCount u8` |
| `0x12` | `Wheel` | reliable | `surfaceEpoch u16`, `x u16`, `y u16`, `dx i16`, `dy i16`, `unit u8` (pixel, line) |
| `0x20` | `Key` | reliable | `usage u32` (USB HID usage, §5.4), `action u8` (up, down, repeat), `modifiers u16` (the viewer's logical modifier state) |
| `0x21` | `Text` | reliable | `length u16`, then that many bytes of UTF-8 (at most 1024) |
| `0x22` | `ReleaseAll` | reliable | none: release every key and button this session holds |

Codes for buttons, key actions, wheel units, platforms (0 unknown, 1 Windows, 2 macOS, 3 Linux, 4 iOS, 5 Android, 6 Fuchsia) and state reasons are in `lib/src/protocol/wire_types.dart`, pinned by the golden-byte tests. `HostState.reason` is a code in the enum its `state` uses (`PauseReason`, `BlockReason`, `StopReason`), and a receiver maps a code it doesn't know to `other`, so hosts can add reasons within v1. A viewer in a browser reports the OS the browser runs on (it decides the shortcuts) and sets capability bit 0 (`web`).

Types `0xC0`–`0xFF` are reserved for **ignorable extensions**: a host that doesn't know one drops it silently. Any other unknown type counts as a violation (§6.4).

### 5.3 Ordering, stale moves and coalescing

- **Reliable messages** must arrive with increasing `seq` (gaps are normal: moves use numbers too). A reliable message whose `seq` isn't greater than the last reliable one is a duplicate or a replay: dropped and counted.
- **Every pointer message carries its own position**, so a click lands where the viewer clicked even if the moves before it were lost.
- **Stale-move dropping:** a `PointerMove` is applied only if its `seq` is greater than that of **every pointer message already applied**, moves and reliable ones alike. A move that arrives late, out of order, or after a click it preceded is dropped, so the pointer never jumps back.
- **Moves never overtake clicks.** The two channels are independent, so a move can arrive before the button press the viewer sent ahead of it. Each move carries `reliableSeq`, the last reliable input sent before it, and the host holds the move (as the one pending move, replaced by any newer one) until that message has arrived and been handled. Found by M1's tests: without it, a drag's first move could land before the double click that started it.
- **Coalescing:** the host keeps only the newest pending move and injects at most one per 4 ms (250 Hz). Excess moves are dropped, never queued.
- **Drags:** a button down (reliable) at its point, moves (unreliable; losses don't matter), and a button up (reliable) at its point. On macOS, moves with a button held are posted as drag events (`kCGEventLeftMouseDragged` and the others), or apps don't see a drag.
- **Click count:** the viewer counts clicks itself (its OS double-click interval and slop) and sends `clickCount`. macOS needs it on the posted event (`kCGMouseEventClickState`); Windows derives double-clicks from timing, so network jitter can split a double-click, and the Windows injector replays a `clickCount` of 2 or more with tight timing if needed (open question 6).

### 5.4 Keys: physical keys and text

Two paths, chosen per keystroke on the viewer:

- **Physical path (`Key`).** The key's **position**, as a USB HID usage (`page << 16 | id`), which is what Flutter's `PhysicalKeyboardKey.usbHidUsage` and the web's `KeyboardEvent.code` describe. The host maps it to a **set-1 scan code** (with the extended flag for `E0` keys; `KEYEVENTF_SCANCODE`) on Windows, or a **`CGKeyCode`** (`kVK_*`) on macOS. **The presenter's keyboard layout decides the character.**
- **Text path (`Text`).** Committed Unicode text. Windows types it with `KEYEVENTF_UNICODE` (a down and an up per UTF-16 code unit; a surrogate pair is two units). macOS uses `CGEventKeyboardSetUnicodeString`, chunked (at most 20 UTF-16 units per event). **What the viewer's own keyboard produced is what's typed,** whatever the two layouts are.

**Keyboard modes** (`KeyboardMode`, chosen on the viewer):

- **`auto` (default):** printable characters without a command modifier go by **text**: letters, digits, punctuation, dead-key results, IME commits, emoji, phone keyboards. Everything else goes by **physical key**: Enter, Tab, Escape, Backspace, Delete, arrows, Home/End, Page Up/Down, function keys, and any key pressed with Ctrl, Alt (Option) or Meta (Cmd/Win) held, so shortcuts work. Modifier keys themselves are sent physically. Lock keys (Caps Lock, Num Lock) aren't forwarded: the text path carries case.
- **`physical`:** every key by position, lock keys included. For games, terminals, or the same layout on both ends.
- **`text`:** printable input by text only, and non-printing keys physically.

**Modifiers.** Each `Key` carries the viewer's modifier state (bits: Shift 1, Control 2, Alt 4, Meta 8), and the host corrects drift: if it holds an injected Shift the viewer no longer reports, it releases it. **Cross-platform shortcuts:** with `ModifierMapping.auto`, the default, when exactly one end is an Apple platform (macOS or iOS), the host swaps Control and Meta (Command, the Windows key) in both keys and modifier bits. So a Mac viewer's Cmd+C is Ctrl+C on a Windows presenter, and a Windows viewer's Ctrl+C is Cmd+C on a Mac. Alt and Option are the same key either way. `ModifierMapping.none` sends keys by position, unchanged. The mapping happens on the host, which knows both platforms from the handshake.

**Keys that can't or won't be injected:**

- **Ctrl+Alt+Del** (the Windows secure attention sequence) can't be injected by `SendInput` at all.
- **Keys the viewer's own OS takes first** never reach Flutter: Cmd+Tab, Alt+Tab, the Windows key, Cmd+Space, and in browsers shortcuts like Cmd+W. The viewer offers `viewer.sendShortcut([...])` for a "Send keys" menu.
- An app-supplied **`KeyFilter`** on the host can drop combinations (for example Win+R). The package blocks nothing by default beyond §6.5.

The HID-to-scan-code and HID-to-`CGKeyCode` tables are built from the USB HID Usage Tables, Microsoft's keyboard scan-code documentation and Apple's `Events.h`, or from Flutter's generated key data (BSD-3-Clause), and tested against each other (§12).

### 5.5 Versioning

- `HostHello` offers a version range; `Hello` picks one. A viewer with no common version gets `Bye(unsupportedVersion)` and the host's state stays waiting.
- **Within v1:** new message types go in the ignorable range or behind `capabilities` bits; new fields go **at the end** of a body, and decoders ignore trailing bytes. A body shorter than its type's v1 size is malformed.
- **A breaking change is v2.** Hosts keep accepting v1 for at least one minor release after v2 ships.
- **Golden-byte tests** pin every message's encoding (§12). Changing them is a protocol change.

## 6. Safety primitives

These are the package's job because they have to be enforced at the point of injection, where the app can't reach. The app builds its consent experience on them (§9).

### 6.1 Off by default

- A `RemoteInputHost` injects nothing until the app calls **`host.enable(...)`**, which returns a **`ControlSession`** bound to **one link and one surface**.
- **One session at a time** per process in v1: a second `enable` while one is live throws a `StateError`.
- Optional **`expiresAt`**: a local backstop that stops the session at that time, whatever the app's own grant logic does.
- There is **no persistent "enabled" setting.** A session ends with its link, its surface, the app's `stop()`, or the process.

### 6.2 Instant stop

- **`session.stop()` is synchronous.** It sets the session's stopped flag before it returns, and the injector checks that flag immediately before every OS call. Queued input is discarded.
- After `stop()` returns, the **only** input the package injects is releasing the keys and buttons that session holds, so nothing stays stuck down. Releases complete within 50 ms (success criteria).
- **`RemoteInputHost.stopAll()`** stops every session in the process: for the app's global revoke hotkey, tray menu or crash handler.
- The session also stops by itself, with a reason, when its link closes, its surface goes away (a shared window closes), it expires, or it sees sustained violations (§6.4).
- **Stuck input:** the viewer sends `ReleaseAll` when its view loses focus. If nothing arrives for `heartbeatTimeout` (5 s by default) while keys or buttons are held, the host releases them.

### 6.3 Local input wins

When the person at the presenter's machine touches their own mouse or keyboard, injection stops for them at once:

- A platform **`LocalActivityMonitor`** reports physical input that this session didn't inject: any key, any button, or pointer movement beyond `localMoveThreshold` (4 points by default, to ignore sensor jitter).
- The session moves to **`paused(localInput)`**: queued input is dropped, held injected keys and buttons are released, and the viewer gets `HostState`.
- It resumes after `localIdle` (1.5 s by default) without local input with `ResumePolicy.automatic` (the default), or when the app calls `resume()` with `ResumePolicy.manual`.
- **Windows:** low-level hooks (`WH_MOUSE_LL`, `WH_KEYBOARD_LL`) on a dedicated native thread with its own message loop, in the plugin's C++ (a hook procedure must return quickly on a thread that pumps messages, which Dart can't guarantee). Injected events carry the `LLMHF_INJECTED` / `LLKHF_INJECTED` flag, and the package's own carry a tag in `dwExtraInfo`. Input injected by something else (an on-screen keyboard, another tool) counts as local.
- **macOS (verify, M3):** the preferred approach needs no extra permission: poll `CGEventSourceSecondsSinceLastEventType(.hidSystemState, ...)` at about 100 Hz, if events the package posts don't reset it. The fallback is a listen-only `CGEventTap` that recognizes the package's events by `kCGEventSourceUserData`, which needs a **second permission** (Input Monitoring). Open question 2.
- Targets: paused within 50 ms of the first local event on Windows and 100 ms on macOS (roadmap, success criteria).

### 6.4 Rate limits and bounds checks

Defaults, which the app can lower but not raise past the caps:

| Limit | Default | Cap |
|---|---|---|
| Message size | 2 KiB | 4 KiB |
| `Text` per message | 1024 bytes of UTF-8 | 1024 |
| Text rate | 200 characters/s, bursts to 400 | 1000/s |
| Moves applied | 250/s, coalesced (excess dropped) | 500/s |
| Keys, buttons and wheel events | 60/s, bursts to 120 (token bucket) | 200/s |
| Wheel delta per message | ±1200 pixels or ±10 lines (clamped) | — |
| Keys held at once | 8 | 16 |
| Queued reliable input | 64 events | 256 |

- **Coordinates** can only name a point inside the surface (they're normalized); points are clamped to it, and a stale `surfaceEpoch` is dropped.
- **Window surfaces:** a pointer event whose point isn't on the shared window, because another window covers it there, is dropped (`occluded`; open question 5 for the same app's menus and popups). **Keys are injected only while the shared window is in front**; otherwise they are dropped and the viewer is told.
- **Display surfaces confine the pointer, not the keyboard.** Keys go to whatever window has focus on that machine, including windows on other displays. Apps should say so in their consent text (§11).
- **Over the rate limits, reliable input queues; it isn't dropped.** Dropping a key release would leave a key stuck, so keys, buttons, wheel events and text wait in one ordered queue for their token bucket. Long text is typed in pieces as tokens refill. Moves wait while the queue isn't empty, so they never overtake it. A full queue stops the session with `stopped(flooding)`.
- **Text never acts like keys.** Control characters other than tab, line feed and carriage return (Escape, Backspace, the C1 range) are stripped from `Text` before it's typed.
- **Violations** (malformed, unknown type, replayed `seq`, wrong session tag, wrong channel, a host-only message, oversized) are dropped and counted in `session.stats`. More than 50 in 10 s **stops the session** with `stopped(protocolViolation)`.

### 6.5 No injection into elevated or secure contexts

The package never asks for elevation, never installs a service, and never uses `uiAccess`. Where the OS would block or should block input, the session reports **`blocked(reason)`**, drops input (it never queues it for later), and resumes when the condition clears:

| Context | Detection | State |
|---|---|---|
| **Windows UIPI:** the target window belongs to a process at a higher integrity level (an app run as administrator, Task Manager, an elevated installer). `SendInput` is blocked there, and silently. | The foreground window's process (keys) or the window under the point (pointer): its integrity level, or a failed query (verify, M5) | `blocked(elevatedTarget)` |
| **Windows secure desktop:** UAC prompts, the Ctrl+Alt+Del screen, the lock screen | The input desktop isn't `Default` (`OpenInputDesktop` fails or names another desktop) | `blocked(secureDesktop)` |
| **macOS Secure Event Input:** a password field has focus, or Terminal's Secure Keyboard Entry is on | `IsSecureEventInputEnabled()` | Keys: `blocked(secureInput)`; the pointer continues |
| **macOS session not active:** the login window, the lock screen, fast user switching | `CGSessionCopyCurrentDictionary()` (on console, screen locked) | `blocked(sessionInactive)` |
| **macOS permission missing or revoked** | `CGPreflightPostEventAccess()` | `unavailable(permissionDenied)` |

Detection is per event: each event is checked before it's injected, and a check that fails moves the session to `blocked(reason)`. While blocked, the host re-checks every 250 ms and returns to `active` when the condition clears. An injector that reports a refusal (`SendInput` failing with UIPI) blocks the session the same way, and a revoked permission stops it with `stopped(permissionDenied)`.

So a remote helper **can't type into a password field on macOS** in v1, and can't operate elevated apps or UAC prompts on Windows. The presenter does those themselves. `RemoteInputHost.limitations` lists these per platform, for apps to show in their UI.

### 6.6 Privacy

- Key codes, text and positions from the wire **never** go into logs, exceptions, `toString()` output or stats. Stats are counts and timings only.
- The example app follows the same rule.

## 7. The host and platform injection

### 7.1 Structure

```
RemoteInputHost / ControlSession          pure Dart: handshake, sequencing, coalescing,
        │                                 rate limits, the safety state machine
        ├── InputInjector                 platform: posts OS input events
        ├── LocalActivityMonitor          platform: local input not injected by us
        ├── SurfaceResolver               platform: displays, window bounds, occlusion, focus
        └── SecureContextProbe            platform: elevated, secure desktop, secure input
```

- Everything above the platform interfaces is **pure Dart and unit-tested with fakes** (`RecordingInjector`, `FakeLocalActivity`, `FakeSurfaceResolver` in `testing.dart`).
- **Injection goes through `dart:ffi`, synchronously,** on both platforms: the stop flag is checked right before each OS call (§6.2), there is no platform-channel hop to add latency, and calls are easy to time. On macOS the Swift code is exposed as `@_cdecl` C functions and looked up with `DynamicLibrary.process()`. A method channel is used only for what needs the main thread's UI: the permission prompt and opening System Settings.

### 7.2 Windows

- **Bindings:** `SendInput`, `GetSystemMetrics(SM_*VIRTUALSCREEN)`, `EnumDisplayMonitors`, `GetMonitorInfoW`, `GetDpiForMonitor`, `DwmGetWindowAttribute`, `WindowFromPoint`, `GetAncestor`, `GetForegroundWindow`, `IsIconic`, `OpenInputDesktop`, and the token queries. Through the `win32` package (BSD-3-Clause) or the package's own minimal bindings: open question 8.
- **Pointer:** absolute moves (§3.2); `MOUSEEVENTF_LEFTDOWN`/`UP` and the others, `XBUTTON1`/`2` for back and forward; `MOUSEEVENTF_WHEEL` and `HWHEEL` in `WHEEL_DELTA` units (120 per notch). Pixel deltas from trackpads are converted with the system's lines-per-notch setting (open question 9).
- **Keys:** scan codes with `KEYEVENTF_SCANCODE` (plus `KEYEVENTF_EXTENDEDKEY` for `E0` keys, such as the arrows and right Ctrl). AltGr is right Alt with the extended flag; on layouts that have it, Windows also synthesizes a left Ctrl. Text with `KEYEVENTF_UNICODE`.
- **Tagging:** every injected event carries the package's tag in `dwExtraInfo`, so the hook thread (§6.3) can tell them apart.
- **Failures:** `SendInput` returns how many events it inserted. Fewer than asked, with `ERROR_ACCESS_DENIED`, means UIPI; the session reports `blocked(elevatedTarget)` even if the pre-check missed it.
- **Other limits:** games that read raw input or use anti-cheat may ignore injected input, and a minimized Remote Desktop session has no input desktop. Neither is worked around.

### 7.3 macOS

- **Events:** `CGEvent` from a package-owned `CGEventSource`, posted at `.cghidEventTap`, with `kCGEventSourceUserData` set to the package's tag. Mouse moves, drags with a button held (§5.3), clicks with `kCGMouseEventClickState`, `CGEvent(scrollWheelEvent2Source:units:...)` with pixel or line units on two axes, `CGEvent(keyboardEventSource:virtualKey:keyDown:)` with explicit flags, and text with `keyboardSetUnicodeString`. Which event-source state to use, and how modifier flags combine with the user's own, is settled in M3 (open question 10).
- **Geometry:** `CGGetActiveDisplayList` and `CGDisplayBounds` for displays (points); `CGWindowListCopyWindowInfo` for a window's bounds (`kCGWindowBounds`), which needs no Screen Recording permission (titles would, and aren't read); windows above a point with `optionOnScreenAboveWindow` for occlusion; `NSWorkspace.frontmostApplication` against the window's owner for keyboard focus.

**Permissions.**

- Posting events needs the **Accessibility** permission (TCC's PostEvent service; System Settings → Privacy & Security → Accessibility).
- The API: `RemoteInputPermissions.status()` (granted, denied, or unknown), backed by `CGPreflightPostEventAccess()`; `request()`, which calls `CGRequestPostEventAccess()` and shows the system prompt (macOS shows it once; after that the user goes to Settings); `openSettings()`, which opens the Accessibility pane; and `statusChanges`, which polls while the app's onboarding screen is showing.
- **(verify, M3)** whether a new grant takes effect without relaunching the app. The answer goes in the onboarding docs.
- A grant is tied to the app's **code signature**. An ad-hoc-signed debug build that is rebuilt can count as a new app and lose it.
- Managed Macs can pre-approve Accessibility with an MDM privacy-preferences (PPPC) profile. This is worth documenting for business users.

**The App Sandbox.** This is the first consumer's open question (keep the sandbox on with Developer ID distribution?), and M3 answers it with a test, not a citation.

- **What is known:** Apple's developer technical support has said on the developer forums that `CGEventPost` works from a sandboxed app once the user grants the PostEvent (Accessibility) permission requested with `CGRequestPostEventAccess()`, while the Accessibility *API* for driving other apps' UI (`AXUIElement`) doesn't ([thread 707680](https://developer.apple.com/forums/thread/707680)). Mac App Store review has rejected sandboxed apps that post events (guideline 2.4.5; [thread 820594](https://developer.apple.com/forums/thread/820594)), which doesn't apply to Developer ID distribution.
- **Expected answer:** with Developer ID, the sandbox can stay on.
- **The M3 test**, on macOS 27, with the example app sandboxed (as it is now), hardened runtime on, signed with a development team:
  1. `CGRequestPostEventAccess()` prompts, and the grant works.
  2. Posted events reach other apps (Finder, TextEdit, a browser) on every display.
  3. Window bounds, the frontmost app, `IsSecureEventInputEnabled()` and the session dictionary can be read.
  4. The chosen local-activity approach (§6.3) works.
  5. The same build without the sandbox, for comparison.
- The result replaces this paragraph, and the consumer is told (CLAUDE.md, Related projects).

### 7.4 What can't be controlled

For apps' UI text (`RemoteInputHost.limitations`):

- **Windows:** apps run as administrator, UAC prompts, the lock and Ctrl+Alt+Del screens; Ctrl+Alt+Del itself; some games.
- **macOS:** password fields and other Secure Event Input (keys only), the login window and lock screen, and nothing at all until the Accessibility permission is granted.
- **Presenters on the web, iOS, Android and Linux** can't be controlled (§2.2).

## 8. Viewer-side capture

Two pieces, both pure Flutter, on every platform:

- **`RemoteInputViewer`** (built in M1): the controller. It owns the viewer's end of the link, the handshake, `seq`, coalescing (at most one move per 8 ms by default) and backpressure, pings every second for the round-trip time and as a heartbeat, and mirrors the host's state (`SessionWaiting`, `SessionActive`, `SessionPaused`, `SessionBlocked`, `SessionStopped`) for the app's UI. It sends nothing until the host says `active`. Its methods take **normalized points** (`Offset(0, 0)` to `Offset(1, 1)` across the picture, clamped): `pointerMove`, `pointerButton`, `click`, `wheel`, `key`, `text`, `sendShortcut`, `releaseAll` and `close`. Apps can call them directly, without the widget.
- **`RemoteInputCapture`**: a widget that wraps the remote video view:

```dart
RemoteInputCapture(
  viewer: viewer,
  contentSize: const Size(1920, 1080), // the video's frame size
  fit: BoxFit.contain,                 // how the view fits it, to find the letterbox
  keyboardMode: KeyboardMode.auto,
  child: videoView,
)
```

It computes the content rect from `contentSize` and `fit` (or takes `contentRect` for custom layouts) and maps events into it (§3.1).

- **Pointer (mouse and trackpad):** `Listener` for down, move, up, hover and signals. Buttons map from Flutter's `kPrimaryButton` and the others. Scroll signals and trackpad pan-zoom become `Wheel` messages (pinch is ignored). The view counts clicks itself (§5.3). Moves are coalesced to one per frame.
- **Touch (phones and tablets).** Phones controlling desktops is a primary use, and a desktop shown on a phone is small, so v1 has **two touch modes**, switchable at any time:
  - **Trackpad (the default on phones):** the viewer draws its own cursor over the video, and a finger moves it relatively, like a laptop trackpad, so the fingertip never hides the target and small targets can be hit. Tap clicks at the cursor, two-finger tap right-clicks, tap-and-drag drags, and a two-finger drag scrolls. The viewer still sends **absolute normalized positions** (the cursor's), so this needs no protocol change, and the host can't tell the modes apart.
  - **Direct (the default on tablets):** a tap is a left click at the finger, a long press a right click, a one-finger drag a left-button drag, and a two-finger drag a scroll.
  - In both, pinch zooms and pans the local view (it isn't sent), so a phone user can zoom in on part of a large desktop.
- **Keys a soft keyboard lacks:** the widget offers an optional key bar (Esc, Tab, Ctrl, Alt, Cmd/Win, the arrows, function keys, and sticky modifiers) built on `viewer.key()` and `sendShortcut()`. Soft-keyboard typing goes by the text path.
- **Keyboard:** a `Focus` node takes `HardwareKeyboard` events while the view has focus and control is active. In `auto` mode (§5.4) a `TextInputClient` (the delta client) is attached at the same time, so dead keys, IMEs and soft keyboards produce **committed text**, which goes as `Text`. Composing text shows only on the viewer, in a small overlay, until it's committed. Making the key path and the text path agree without sending a character twice is the hardest part of capture, and it differs per platform; M4 settles it with tests on every viewer platform (open question 11).
- **Leaving capture:** the view releases keyboard focus on a configurable `releaseShortcut`, and sends `ReleaseAll` whenever it loses focus.
- **Latency:** `viewer.stats` keeps the round-trip time from `Ping`/`Pong`.

## 9. How the first consumer uses it

buildIt.Social's Phase 6 adds remote control to its calls. The package's API is shaped for this flow without depending on the app or its video package:

1. **A call is running and the presenter is sharing** a display or a window. Their video package knows the shared source's geometry (in `cloudflare_realtime`: `ScreenShareSource.sourceGeometry` and `sourceGeometryChanges`).
2. **A viewer asks for control.** The app sends the request; the presenter's app shows its consent dialog; on consent, the app records a grant on its server, with an expiry, bound to the viewer's verified identity and the call's media session. *(All app.)*
3. **The presenter's app enables a session:**
   - On macOS, it checks `RemoteInputPermissions.status()` and runs its onboarding if needed.
   - It builds an `InputLink` from the call's DataChannels, **accepting messages only from the granted viewer**, identified by the channel's session (which the video package maps to a participant), never by the payload.
   - It calls `host.enable(link:, surface:, options: HostOptions(expiresAt: grantExpiry))`, with a `SharedSurface.rect` fed from the geometry stream, or `SharedSurface.window`.
   - It shows its banner and border, and follows `session.stateChanges` to say "Paused while you use your mouse" or "Can't control an app run as administrator".
4. **The viewer's app wraps the screen-share view** in `RemoteInputCapture` with its end of the link, and shows the host's state.
5. **Input travels over the call's DataChannels; the presenter's app injects.** Local input wins automatically (§6.3).
6. **Revoking:** the app's revoke hotkey, its banner's Stop button or the end of the grant calls `session.stop()` (or `RemoteInputHost.stopAll()`), and the app updates its grant and audit log from the session's stop reason. The package also stops by itself when the link closes, the shared window goes away, or the share's surface is replaced.

**The DataChannel layout** we expect over `cloudflare_realtime` (an adapter of about a hundred lines, in the consumer; a reference copy in this repo's example, M6):

| Channel | Published by | Profile | Subscribed by |
|---|---|---|---|
| `remote-input/reliable` | viewer | reliable | the presenter, only from the granted viewer |
| `remote-input/moves` | viewer | unreliable | the presenter, only from the granted viewer |
| `remote-input/host` | presenter | reliable | the granted viewer |

- `cloudflare_realtime`'s `room.data` gives each message's sender as a participant, derived from the channel's session and the room's signaling, never from the payload. The adapter passes on only the granted participant's messages.
- **Known gap:** a **web** endpoint of an unreliable channel still retransmits (a `dart_webrtc` limitation that `cloudflare_realtime` documents). Stale-move dropping keeps the pointer correct; moves from a browser viewer may just arrive later under packet loss.

What the app gets from the package to build its consent experience: `ControlSession.state` and `stateChanges` with reasons, `stop()`, `RemoteInputHost.stopAll()`, `HostOptions` (expiry, keyboard on or off, `KeyFilter`, limits), `session.stats`, `RemoteInputPermissions`, and `RemoteInputHost.limitations`. Nothing else should be needed; if the consumer finds a gap, it belongs in this list.

## 10. Public API sketch

M1 settled these names; the widget's are still proposals for M4. Style follows `cloudflare_realtime`'s: a getter for the value now, a `…Changes` stream that replays it, `…Options` for option classes, `final` value types and `sealed` state and exception roots.

```dart
import 'package:remote_input/remote_input.dart';

// --- Presenter (Windows or macOS) ------------------------------------------
if (!RemoteInputHost.isSupported) return;           // web, phones, Linux

final permission = await RemoteInputPermissions.status();   // macOS; granted elsewhere
if (permission != PermissionStatus.granted) {
  await RemoteInputPermissions.request();           // or .openSettings()
}

final host = RemoteInputHost();
final displays = await host.displays();             // id, bounds, scaleFactor, isPrimary

final session = host.enable(
  link: link,                                       // the app's InputLink to the granted viewer
  surface: SharedSurface.display(displays.first.id),
  options: const HostOptions(
    expiresAt: null,                                // a backstop for the app's own grant
    allowKeyboard: true,
    resumePolicy: ResumePolicy.automatic,
    localIdle: Duration(milliseconds: 1500),
  ),
);

session.stateChanges.listen((s) => switch (s) {
  SessionActive() => showBanner(),
  SessionPaused(:final reason) => showPaused(reason),     // localInput, ...
  SessionBlocked(:final reason) => showBlocked(reason),   // elevatedTarget, secureInput, ...
  SessionStopped(:final reason) => hideBanner(reason),    // byHost, linkClosed, expired, flooding, ...
  _ => null,
});

session.stop();                                     // synchronous; also RemoteInputHost.stopAll()

// --- Viewer (any platform) --------------------------------------------------
final viewer = RemoteInputViewer(link: link);
viewer.stateChanges.listen(updateControlBadge);
viewer.click(const Offset(0.5, 0.5));               // normalized; or let the widget do it
RemoteInputCapture(viewer: viewer, contentSize: videoSize, child: videoView);
await viewer.close();

// --- Tests (package:remote_input/testing.dart) -------------------------------
final pair = MemoryInputLink.pair(loss: 0.05, reorder: true); // .host, .viewer
final platform = FakeHostPlatform();                // RecordingInjector and the other fakes
final testHost = RemoteInputHost(platform: platform);
```

## 11. Security model and threats

**Trust model.**

- The package **trusts the host app** to decide who may control and when, and to bind each link to exactly one authenticated peer.
- It **trusts the transport** for confidentiality and peer identity (WebRTC DataChannels are encrypted with DTLS; the example's WebSocket link is plaintext and for development only).
- It **trusts nothing in a message.** Every field is validated, and identity is never read from one.
- **Keystrokes are sensitive data.** A viewer may type passwords for the presenter. They exist only in flight and in the OS event stream, never in logs (§6.6).

| Threat | Example | Package mitigation | Left to the app |
|---|---|---|---|
| **Unauthorized viewer** | Someone in the call who wasn't granted control sends input | Off by default; a session reads only the link the app bound; session nonce and tag | Consent, server-side grants, filtering the transport by verified sender |
| **Malicious authorized viewer** | Opens a terminal, downloads and runs something, reads files | Local input wins; instant stop and `stopAll()`; expiry backstop; keyboard can be off; `KeyFilter`; window surfaces confine the pointer and keys; no elevated targets | A visible banner and border, the revoke hotkey, trusting whom you grant, the audit log |
| **Replay** | Recorded input messages replayed later, or into another session | The session nonce in the handshake and the tag in every message; strictly increasing `seq` on the reliable channel; stale-move dropping; transport encryption | Grants bound to one call's media session |
| **Flooding** | Thousands of moves or keys per second, huge text messages | Size caps, token buckets, coalescing, bounded queues, drop rather than buffer, and a stop on sustained violations (§6.4) | Rate limits on the request and grant flow |
| **Coordinate escape** | Clicking outside the shared window or display | Normalized coordinates only, clamped to the surface; surface epochs; occlusion checks on window surfaces; a minimized window blocks input | Choosing a window share when control should be confined |
| **Keyboard escape** | Typing into another app than the shared one | Window surfaces: keys only while the shared window is in front. **Display surfaces: keys go to any focused window** | Saying so in the consent text |
| **Stuck input** | A key held down after the session ends | Releases on stop, pause, link loss, timeout and viewer blur | — |
| **Privilege escalation** | Driving a UAC prompt or an elevated app | No elevation, no `uiAccess`, no service; elevated and secure contexts are detected and reported (§6.5) | Showing the limits |
| **Malformed input** | Crafted bytes against the decoder | Strict length checks, no exceptions out of the decoder, fuzz tests (§12) | — |
| **Host spoofing towards the viewer** | Fake "paused" states | Low impact; the viewer's state is informational | Not presenting the viewer's state as a security guarantee |

**There is no cryptographic message authentication in v1.** The package relies on the transport's encryption and the app's peer binding. An optional HMAC with an app-provided key, for transports that don't authenticate the peer, is open question 12.

**An independent security review before the first consumer's pilot** (roadmap M7): the codec, the safety state machine, the native injectors and detectors, the reference adapters, and this section. Findings are fixed, or documented here as accepted risks, before 0.1.0.

## 12. Testing strategy

- **Unit (pure Dart, CI on Linux):**
  - The codec: golden bytes for every message type, round trips, version negotiation, trailing bytes, short bodies, and a fuzz test (at least a million random and mutated messages: no exception escapes, nothing invalid is applied).
  - Sequencing: serial-number wrap, stale-move dropping, coalescing.
  - Safety: the session state machine, every stop and pause reason, rate limits and timeouts with `fake_async`, release-on-stop, `stopAll()`.
  - Coordinates: mapping onto surfaces with negative origins, mixed scale factors, odd sizes and every corner; Windows absolute-coordinate conversion.
  - Key tables: HID to scan code and HID to `CGKeyCode`, checked against each other and Flutter's key data; `auto` mode's routing.
- **Widget tests:** `RemoteInputCapture`'s content rect for every `BoxFit`, letterboxing, edge clamping during drags, click counting, touch gestures, and IME commits through `TestTextInput`.
- **Integration tests on devices** (`example/integration_test/`): the example app **injects into its own window** and checks what Flutter receives: positions at every corner and centre of each display and of the window, buttons, wheel, keys, text in several layouts, and the local-input pause. On macOS this needs the Accessibility grant, which only the owner can give (CLAUDE.md). On Windows, CI's runner may be able to run them (open question 13).
- **Two machines, by hand:** a runbook (`docs/checkpoint.md`, M6) for the Windows ↔ macOS demo and the success criteria that need people: mixed-DPI rigs, layouts and IMEs, latency, and local input wins.
- **Latency harness:** timestamps at capture, send, receive, decode and OS call, with `Ping` for round-trip times; reported as percentiles by the example.

## 13. Open questions

For the agent building the package to resolve. Record each answer here (and in the roadmap if it moves scope).

1. **The macOS App Sandbox** (§7.3): confirm that `CGEventPost` works sandboxed with Developer ID signing on macOS 27, and report back to the first consumer. M3.
2. **Local activity on macOS** (§6.3): does `CGEventSourceSecondsSinceLastEventType(.hidSystemState, ...)` ignore events the package posts? If not, can posting at `.cgSessionEventTap` keep it clean, or is a listen-only event tap (and a second permission, Input Monitoring) needed?
3. **Windows absolute coordinates:** is the `MOUSEEVENTF_VIRTUALDESK` normalization exact at every pixel on mixed-DPI, negative-origin layouts, or should moves use `SetCursorPos`?
4. **macOS window bounds per event:** how fast is `CGWindowListCopyWindowInfo` for one window? Pick a cache lifetime, or follow window moves another way.
5. **Occlusion and the shared app's own windows:** should menus, popups and dialogs of the shared window's process count as the shared window? (Probably yes for menus; decide with tests.)
6. **Double-clicks on Windows** across network jitter: replay `clickCount` with tight timing, or trust Windows' own timing?
7. ~~**Cross-platform modifier mapping.**~~ **Answered (M1):** `auto` by default, swapping Control and Meta when exactly one end is Apple; Alt/Option unchanged (§5.4).
8. **`win32` or own bindings** on Windows: the `win32` package is large but maintained; about fifteen functions are needed.
9. **Pixel wheel deltas on Windows:** how to convert trackpad pixels to `WHEEL_DELTA` units so scrolling feels the same as local scrolling.
10. **macOS event source and flags:** which `CGEventSourceStateID` keeps injected modifiers from mixing with the local user's, and how text events should set flags while the viewer holds Shift.
11. **Viewer keyboard capture per platform:** how Flutter's `HardwareKeyboard` and a text-input client interact on each viewer platform (desktop, web, phones with soft keyboards), and how `auto` mode avoids sending a character twice or not at all.
12. **Message authentication:** is an optional HMAC worth having for transports without peer authentication, or is that the transport's job?
13. **CI injection tests on Windows:** can GitHub's Windows runners inject into a window (they need an interactive desktop)? If not, the Windows checks stay on a real machine.
14. **The example's video:** the example has no video stack. Is a surface placeholder with the right aspect ratio enough for the demo, or should it stream low-rate screenshots, or depend on `cloudflare_realtime` in a second example?
15. **Long text:** pasting a long text through the text path is slow at 200 characters a second. Is that acceptable, given that clipboard sync is out of scope?
16. **Platform tags on pub.dev:** the plugin declares only Windows and macOS, so pub.dev will list only those, though the viewer runs everywhere. Declare Dart-only implementations for the other platforms (`dartPluginClass`) so they're listed?
17. **The Swift package's identity when the directory isn't `remote_input`.** Flutter links the plugin's Swift package under the plugin's directory name (`flutter-remote-input` in a clone; `flutter-remote-input-<hash>` in pub's git cache, which is how consumers pin it). The CI runner's Xcode (macOS 26 image) refused that: "unable to override package 'remote_input' because its identity 'flutter-remote-input' doesn't match", so CI checks out into `remote_input`. Xcode 27.1 accepts it. Check a consumer's git-pinned macOS build on the Xcode versions it supports, and whether a hosted package (`remote_input-<version>` in pub's cache) has the same problem; fix it in the plugin's `Package.swift` if it can be fixed there. M3.
