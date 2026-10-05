# Two-machine checks: the runbook

The checks that need two machines and a person: the [consumer checkpoint](roadmap.md#consumer-checkpoint-week-4) and the [success criteria](roadmap.md#success-criteria) that tests can't cover. Run them with the example app ([example/README.md](../example/README.md)) and record the results at the [end of this file](#results).

- **Part A** is the week-4 checkpoint: pointer, keys, stop and local input, in both directions between Windows and macOS.
- **Part C** comes first on a new build: the device checks for each host platform (Windows injection, the macOS permission, injection test and App Sandbox test).
- **Part B** is the rest of the success criteria for 0.1.0: every viewer platform, mixed DPI, layouts and IMEs, latency, and the timing of local input and stop.
- The example's WebSocket link is the transport here. The checkpoint itself passes over the first consumer's call DataChannels, which its own team runs with the same steps; the [`cloudflare_realtime` adapter](../example/cloudflare_realtime_adapter/README.md) is the reference for that.

## Before you start

**People and safety.** These checks move the real pointer and type real keys on the host. The person at the host keeps a hand near their mouse (touching it pauses control) and the **Stop** button in view. Only run them when that machine is free.

**Machines.**

| Role | Requirement |
|---|---|
| Windows host | Windows 10 1703 or later. For B2: two monitors at 100 % and 150 %, one left of or above the primary. |
| Mac host | macOS 12 or later. For B2: a Retina display and a non-Retina external one, left of or above the main display. |
| Viewers | The other desktop; Chrome, Safari and Firefox; an iPhone or iPad; an Android phone. |
| Network | One LAN, wired or good Wi-Fi. Note which in the results. |

**Builds.** Record the commit under test.

- Desktop: `flutter run -d windows` / `-d macos` in `example/`, or a `--profile` build for B4's latency.
- Web viewer: `flutter run -d chrome` (served over `http://`; an `https://` page can't open the `ws://` link).
- Phones: `flutter run` on the device; allow iOS's local-network prompt.

**macOS host setup.**

1. Sign the debug build with a development team, so a rebuild keeps the Accessibility grant.
2. Start the app, choose **Host this computer**. With the permission missing it shows the onboarding card (A4).
3. Turn Hot Corners off for the session (System Settings → Desktop & Dock → Hot Corners), so corner clicks in B2 don't trigger them.

**Test targets on the host.** A plain text editor (Notepad, TextEdit in plain-text mode), a browser with a long page, and a file manager window.

**Pairing (every run).**

1. Host: **Host this computer** → pick the display → **Start listening**. Note the address and code.
2. Viewer: **Control another computer** → address and code → **Connect**.
3. Host: the consent dialog names the viewer → **Allow** (keyboard on).
4. Both: the viewer shows **You are in control**; the host shows the red **Being controlled** banner.

The viewer has no video ([design.md §13](design.md#13-open-questions), question 14): its view is a grid with the host display's aspect ratio. Sit where you can see the host's screen.

## A. The consumer checkpoint

Run A1–A3 twice: **Windows viewer → Mac host**, and **Mac viewer → Windows host**. A4 is once, on the Mac.

### A1. Pointer on a shared display

1. Move across the grid: the host's pointer follows, and stops at the display's edges.
2. Click into the text editor: the caret moves there.
3. Double-click a word: it is selected. Triple-click a line (where the editor supports it).
4. Drag across text to select it; drag a window by its title bar; drag a file in the file manager.
5. Start a drag and leave the grid with the button held: the host's pointer stays on the display's edge, and the drag ends where you release.
6. Right-click: a context menu opens where you clicked.
7. Scroll the browser page with the wheel, then with a trackpad (two fingers): both directions, smoothly.

**Pass:** every action lands where aimed, as judged on the host's screen.

### A2. Keys (US layouts)

1. In the text editor, type: `The quick brown fox jumps over the lazy dog. 0123456789 !@#$%^&*()`
2. Enter, Backspace, Delete, Tab, the four arrows, Home/End (Fn+arrows on a Mac keyboard).
3. With the viewer's own shortcut keys: select all, copy, paste, undo. From a Mac viewer to Windows that's ⌘A, ⌘C, ⌘V, ⌘Z; from Windows to a Mac, Ctrl+A and so on (the host swaps Control and Command).
4. **Send keys** menu: Alt+Tab or Meta+Tab switches apps on the host.

**Pass:** the text arrives exactly; the keys and shortcuts act as on the host itself.

### A3. Stop, and local input wins

1. **Stop with input held:** on the viewer, press and hold Shift, and start a drag with the left button held. On the host, press **Stop**.
   - The viewer shows **The host stopped control** at once.
   - On the host, type a letter (lower case: Shift isn't held) and move the mouse (no drag in progress). Nothing more arrives from the viewer.
2. **Local input wins:** reconnect. On the viewer, keep moving the pointer in circles. On the host, nudge the mouse.
   - The host shows **Paused while you use your mouse or keyboard**, and the viewer **Paused: the person at the host is using their computer**.
   - The two pointers don't fight: while you keep using your mouse, the viewer's moves aren't injected.
   - About 1.5 s after you stop, control resumes by itself.
   - Repeat with a key press on the host's keyboard.
3. **Pause:** the host's **Pause** stops input until **Resume**.
4. **Ends by itself:** close the viewer app: the host shows **The viewer left** or **The connection closed**. Turn off the viewer's Wi-Fi: the host stops within about 10 s (WebSocket keepalive).

**Pass:** nothing stays held after a stop, and the host's own input always wins.

### A4. macOS: the permission and the sandbox

1. Remove the example from Accessibility (System Settings → Privacy & Security → Accessibility), and start it.
2. **Host this computer** shows **Allow this app to control the computer**. Grant it, then **Check again**: the display picker and **Start listening** appear. Note whether a relaunch was needed.
3. The App Sandbox answer comes from [C3](#c3-macos-the-app-sandbox-test-design-73-open-question-1); record it here when it's in.

## B. Success criteria (for 0.1.0)

### B1. Every viewer, both hosts

A short pass (A1 steps 2, 3, 7 and A2 step 1) for each viewer against each host: Windows, macOS, Chrome, Safari, Firefox, iOS, Android, and a viewer in a browser on a phone.

- On phones, use touch: tap to click, drag to drag. The key bar (Esc, Tab, arrows, sticky Ctrl/Alt/Meta/Shift) sends what the soft keyboard lacks; **Send keys → Type text…** types text. (Trackpad touch mode and soft-keyboard capture arrive with the capture widget, M4.)
- The host's banner shows the viewer's platform, and "(browser)" for web viewers.

### B2. Coordinates on mixed-DPI, multi-monitor hosts

For **each display** of the host, pick it in **Shared display**, pair, and:

1. Move the pointer to each corner of the grid and to its centre (the brighter lines cross there). The host's pointer goes to the same corner or centre of **that** display, including a display left of or above the primary (negative coordinates).
2. Click a small target near each corner (a window's close button, a menu-bar item, the Start button).
3. Drag a window from one display to the shared one: the pointer stays confined to the shared display.

**Pass:** each lands on target. The 1-pixel (Windows) and 1-point (macOS) precision is measured by the integration tests that inject into the example's own window (M2, M3); by hand, a target the size of a close button is the check. Record each display's size, scale and position.

### B3. Text: layouts and IMEs

Needs the capture widget's text path (M4) for dead keys and IMEs; the stand-in sends hardware keys only.

| Viewer layout | Host layout | Type |
|---|---|---|
| US, German, French, Russian | US, German | `é ñ ü ß @ € { } [ ] \| ~ 😀` and `Привет` |
| Japanese or Chinese pinyin IME | US | `日本語` / `你好`: exactly the committed text, nothing from composing |

Then copy, paste, select all and undo in each direction. **Pass:** the text arrives exactly.

### B4. Latency

1. On the viewer, after a minute connected, read the toolbar: **RTT** with its p50 and p95 over the last minute (sampled from the viewer's pings). Record them, and whether the link is wired or Wi-Fi.
   - Target over a LAN: p50 ≤ 20 ms, p95 ≤ 50 ms.
2. **Under loss:** the WebSocket is TCP, so loss becomes retransmission, not dropped moves. Check the package's behaviour under 2 % move loss in the one-machine demo (settings → loss 2 %): the cursor stays smooth and the stats show no backlog. Over the SFU it is checked with the first consumer's call.
3. Host and viewer overheads (message received → OS call returned; Flutter event → message sent) need the latency harness (design.md §12, M7). Mark them "n/a" until it exists.

### B5. Local input wins, timed

1. Record the host's screen at 120 fps or more (a phone's slow-motion video works), with the host's mouse in view.
2. The viewer moves continuously; the host's person moves their mouse.
3. Count frames from the mouse's first movement to the last injected pointer movement.

**Pass:** at most 50 ms on Windows and 100 ms on macOS; held keys and buttons released within 100 ms; nothing injected while paused. The precise numbers come from M5's timing tests; this is the end-to-end confirmation.

### B6. Instant stop, timed

As A3 step 1, recorded as in B5: from **Stop** to the release of everything held. **Pass:** nothing is injected after Stop except releases, within 50 ms. Repeat by quitting the host app (it calls `RemoteInputHost.stopAll()`).

## C. Device checks for the host platforms

The Windows and macOS hosts are built and unit-tested; these are the checks that need the real OS. Part A needs them to pass first.

### C1. Windows

Built and unit-tested on macOS; the native C++ was compile-checked with mingw-w64. Nothing here has run on Windows yet. Run on a Windows machine with the example built from this repo.

1. Build the example. Run `remote_input_test.exe` (gtest), then, with the machine idle, `flutter test integration_test/windows_injection_test.dart -d windows`.
2. Coordinates (design §3.2, open question 3): every corner and the centre land exactly, by Flutter's position and by `GetCursorPos`, in both placements (absolute and the `SetCursorPos` fallback). Repeat on a mixed-DPI rig (100 % and 150 %) with a monitor left of or above the primary.
3. Captured content vs bounds (§3.3): compare `DWMWA_EXTENDED_FRAME_BOUNDS` with what the screen capturer captures for a window; calibrate default `contentInsets`.
4. Local input wins (§6.3): pause within 50 ms (the test prints it). The package's own events, its `SetCursorPos` fallback, and the left Ctrl Windows synthesizes for an injected AltGr must not pause the session.
5. Secure contexts (§6.5): keys and pointer blocked over an admin app (Task Manager), both by the integrity check and by `SendInput` refusing. UAC, Ctrl+Alt+Del and the lock screen show `secureDesktop` (check whether Win+L leaves the input desktop as `Default`). AppContainer/Store apps are not reported as elevated.
6. §7.2: back/forward buttons reach Flutter; both wheel axes scroll and feel right; extended keys (arrows, right Ctrl) and media keys work by scan code; emoji (surrogate pairs) type correctly.
7. `RemoteInputHost.isSupported` is true in the example, and `checkAvailable()` is `null` under Flutter's PerMonitorV2 manifest.
8. **Review fixes (M7):**
   - *Own windows:* share a display; the viewer clicks the host app's Stop button or consent dialog: nothing happens. With the host app in front, viewer keys are blocked (`hostAppInFront`); with another app in front, keys work.
   - *Movement while the viewer moves:* while the viewer drags or moves continuously, move the physical mouse slowly (about 1 cm): the session pauses within 50 ms. Resting a hand on the mouse or tapping the desk doesn't pause it.
   - *Hook health:* `remote_input_test.exe`'s `HealthFollowsTheHookThread` passes. Freeze the process about 2 s (debugger break, or Process Explorer's suspend), resume: during the freeze the session shows `blocked(localInputUnmonitored)`, then it pauses once for local input and resumes, and physical input still pauses it. Leave a session idle 60 s, then type on the physical keyboard: it pauses (the 15 s re-hooks work).
   - *Window ownership:* share one File Explorer window: its context menus, ribbon drop-downs and Properties dialog work; clicks on the taskbar, the desktop, Start and another Explorer window are dropped; after Win+R on the host, viewer keys are blocked. Share one Edge or Chrome window: its menus, `<select>` drop-downs, autofill and print/save dialogs work; a second window of the same browser over it drops clicks and blocks keys. Share Notepad: the File menu, the Font dialog and its drop-downs work.

### C2. macOS: the Accessibility grant and the injection test

Only when the machine is free: the test moves the real pointer and types real keys, into its own window only.

1. `cd example && flutter build macos --debug` (builds `example/build/macos/Build/Products/Debug/remote_input_example.app`, ad-hoc signed).
2. In System Settings → Privacy & Security → Accessibility, add and turn on **the terminal you run `flutter test` from** (Flutter launches the app's binary directly, so macOS credits the terminal) and **the `.app` above**. A rebuilt ad-hoc debug app can lose its grant; re-add it, or sign with your team.
3. `flutter test integration_test/macos_injection_test.dart -d macos`, hands off for about 20 seconds. Expect 2 passing tests: corners and centre within 1 point, clicks, right click, double click, drag, pixel and line scrolling, `a`, Shift+`A`, Backspace, Command+A, Unicode text and Enter, and **no pause caused by the package's own events** (open question 2).
4. If it fails at the permission check, the grant went to the other entry. At "The package's own events paused the session", switch `MacosLocalActivity`'s detector in `lib/src/host/macos/macos_host.dart` to `MacosActivityDetector(ownEventsReachHidState: true)` and re-run. At `aA` (you get `aa`), open question 10's premise is wrong: report it.
5. Afterwards, remove the terminal's grant if you don't want to keep it.
6. **Own windows (M7 review):** share a display with the example's host and pair from a second machine. The viewer clicks the host app's window, including **Stop** and the consent dialog: nothing happens (counted as `hostWindow`). Put another app's window over the host's: clicks there land on that app. Bring the host app to the front: the viewer's keys are blocked (`hostAppInFront`).
7. **Local mouse while the viewer moves:** the viewer moves in continuous circles; nudge the host's mouse about 1 point, then swipe the trackpad slowly: paused within 100 ms each time. Rest a hand on the mouse or trackpad without moving it for 10 s: no pause.
8. **Stale permission cache:** the viewer holds Shift and the left button (dragging). Remove the app's Accessibility grant in Settings, then release on the viewer. Shift and the button must not stay down on the host: type a lower-case letter and move the mouse locally.

### C3. macOS: the App Sandbox test (design §7.3, open question 1)

Preparation: open `example/macos/Runner.xcworkspace`; on the Runner target set your Team (Apple Development certificate) and add **Hardened Runtime**; leave App Sandbox on (both entitlements files are sandboxed). **Don't commit the team ID.** Then `cd example && flutter build macos --release -t lib/macos_check.dart`, check `codesign -dv --entitlements - build/macos/Build/Products/Release/remote_input_example.app` shows `flags=0x10000(runtime)`, `app-sandbox` true and an Apple Development authority, and remove old `remote_input_example` entries from the Accessibility list. Record the macOS build and each result:

1. **Prompt and grant:** `open build/macos/Build/Products/Release/remote_input_example.app` (so the app is its own TCC client). The page shows `denied`. **Request permission**: the system prompt names the app; enable it in Settings. Note whether the status turns `granted` within about a second without relaunching (design §7.3's open point). Requesting again shows no prompt.
2. **Events reach other apps on every display:** with a TextEdit document in front, **Type a line into the front app** and switch to TextEdit within 5 s: expect `remote_input check: héllo wörld 👋 0123456789` and a newline. Repeat in Safari's address bar and a Finder rename. Put a TextEdit window over the centre of each display and **Click the centre of each display**.
3. **Bounds, frontmost app, secure input and session can be read:** **Type into this window** and click the page's field: the text arrives. Repeat but switch apps during the countdown: the log shows `dropped {notFocused: …}`. Click the page's password field, press the button and click the field again: `SessionBlocked(secureInput)` (if Flutter's obscured field doesn't turn on Secure Event Input, use Terminal → Secure Keyboard Entry with Terminal in front). **Circle**, lock with Ctrl-Cmd-Q, unlock: `SessionBlocked(sessionInactive)`. With **Type into this window** running, press Cmd+Space during the countdown: keys are blocked (`windowNotInFront`) while Spotlight is open, and resume after Esc.
4. **Local input wins:** **Circle for 8 s**, nudge the mouse once: `SessionPaused(localInput)`, the circle stops, then `SessionActive` about 1.5 s after you let go. A key pauses it too. No pause while you don't touch anything.
5. **Spotlight probe (read-only):** `sleep 5; swift tool/macos/spotlight_probe.swift` in Terminal, and press Cmd+Space within 5 s. Record Spotlight's window layer, and confirm the frontmost app stays Terminal. Run it again after Esc: no Spotlight window lines.
6. **Without the sandbox, for comparison:** remove App Sandbox locally, rebuild, re-grant if asked, repeat 1–5.

The answer goes into [design.md §7.3](design.md#73-macos), the README's macOS section, and to the first consumer.

## Results

Fill in one row per run. Result: pass, fail, or n/a with a reason.

| Check | Viewer → host | Commit | Date | Network | Result | Notes |
|---|---|---|---|---|---|---|
| A1 Pointer | Windows → macOS | | | | | |
| A1 Pointer | macOS → Windows | | | | | |
| A2 Keys | Windows → macOS | | | | | |
| A2 Keys | macOS → Windows | | | | | |
| A3 Stop, local input | Windows → macOS | | | | | |
| A3 Stop, local input | macOS → Windows | | | | | |
| A4 Permission, sandbox | macOS | | | | | |
| B1 Chrome | → Windows / → macOS | | | | | |
| B1 Safari | → Windows / → macOS | | | | | |
| B1 Firefox | → Windows / → macOS | | | | | |
| B1 iOS | → Windows / → macOS | | | | | |
| B1 Android | → Windows / → macOS | | | | | |
| B2 Mixed DPI | → Windows (100 % + 150 %, negative origin) | | | | | |
| B2 Mixed DPI | → macOS (Retina + external, negative origin) | | | | | |
| B3 Layouts | each viewer layout → US / German | | | | | |
| B3 IME | Japanese or pinyin → each host | | | | | |
| B4 Latency (LAN) | each direction | | | | | p50 / p95 |
| B5 Local input timing | → Windows / → macOS | | | | | ms |
| B6 Stop timing | → Windows / → macOS | | | | | ms |
