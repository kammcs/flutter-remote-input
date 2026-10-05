# Two-machine checks: the runbook

The checks that need two machines and a person: the [consumer checkpoint](roadmap.md#consumer-checkpoint-week-4) and the [success criteria](roadmap.md#success-criteria) that tests can't cover. Run them with the example app ([example/README.md](../example/README.md)) and record the results at the [end of this file](#results).

- **Part A** is the week-4 checkpoint: pointer, keys, stop and local input, in both directions between Windows and macOS.
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
3. The App Sandbox answer comes from M3's test ([design.md §7.3](design.md#73-macos)); record it here when it's in.

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
