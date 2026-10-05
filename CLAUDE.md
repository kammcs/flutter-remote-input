# CLAUDE.md

This repo is **`remote_input`**, a Flutter plugin for remote keyboard and mouse control. A viewer's input is captured over a remote view, sent as a small versioned protocol over a transport the app provides, and replayed as local input on the presenter's desktop: `SendInput` on Windows, `CGEventPost` on macOS. It is **public** and will be published to pub.dev. Its first consumer is the buildIt.Social app, which is private and developed separately ([Related projects](#related-projects)).

The package injects input into someone's computer. **Safety is part of the API, not an add-on:** injection is off by default, stops instantly, and yields to the local user. Read [docs/design.md §6](docs/design.md#6-safety-primitives) before changing anything that injects.

## Read first

- [docs/design.md](docs/design.md): the scope, the protocol, the platform injectors, the safety primitives, the security model and the open questions.
- [docs/roadmap.md](docs/roadmap.md): milestones, the success criteria, and the **consumer checkpoint**. Prioritize what the checkpoint needs.
- [README.md](README.md): the public face. Keep it in step with what actually works.

## Rules

- **This repo is public.**
  - Never commit secrets: tokens, signing identities, provisioning profiles, notarization credentials, `.env` files.
  - Never print secret values in output, logs, tests or docs.
  - **Don't put private details of any consuming app here:** its infrastructure, servers, costs, customers or security history. Saying that buildIt.Social is the first consumer, that it is private, and where it lives locally is fine. Its schema, table names, server URLs and grant logic are not.
- **Never log what the user types.** Key codes, text and pointer positions from the wire never go into logs, exceptions or analytics, in the package or the example. Counts and timings are fine.
- **Off by default.** No code path injects unless the host app has explicitly enabled a session ([design.md §6](docs/design.md#6-safety-primitives)). Don't add a "convenience" that enables it implicitly, in the package or the example.
- **The core package has no transport dependency.** The transport is an interface ([design.md §4](docs/design.md#4-the-transport)). It must not depend on `cloudflare_realtime`, WebRTC, WebSocket or any backend SDK. Adapters live in the example or in the consumer.
- **The protocol is versioned.** Any change to the wire format bumps or extends the version as [design.md §5](docs/design.md#5-wire-protocol-v1) says, with golden-byte tests.
- **Licensing:**
  - The package is MIT. Permissive references (MIT, BSD, Apache-2.0) may be ported; add each to [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) with its licence text and the source commit.
  - **Don't copy AGPL/GPL/LGPL code:** RustDesk, TigerVNC, x11vnc, Remmina, FreeRDP's GPL parts and similar. Reading their docs for concepts is fine; don't open their source while writing the matching code here.
  - Key-code tables: build them from the USB HID Usage Tables, Microsoft's scan-code documentation and Apple's `Events.h` (HIToolbox), or from Flutter's own generated key data (BSD-3-Clause, already a dependency).
- Keep `publish_to: none` until milestone M8.
- When a design decision changes, update `docs/design.md` (and the roadmap if the scope moves) in the same change.
- **Git identity:** `kammcs <85201048+kammcs@users.noreply.github.com>`. Commit messages end with the co-author line the session gives you.

## Tooling

- **Flutter:** 3.47.3 / Dart 3.13.3.
- **Before committing:** `dart format .`, `flutter analyze` and `flutter test` (and `flutter test` in `example/`). CI runs all of them, gitleaks, and debug builds of the example on Windows and macOS.
- **Pre-commit hook:** enable it once per clone with `git config core.hooksPath .githooks`. It runs `gitleaks git --staged`; commits fail if gitleaks isn't on `PATH`.
- The `public_member_api_docs` lint is on: document every public member.
- **Web must keep compiling.** The viewer side runs in browsers, so `dart:ffi` and `dart:io` stay behind conditional imports. Check with `flutter build web` in `example/` when you touch imports.

## This machine (macOS)

- **macOS 27, Xcode 27.1**, Apple silicon.
- **`gh`** (`/opt/homebrew/bin/gh`) is logged in as `kammcs`. **`gitleaks`** is in `/opt/homebrew/bin`.
- **Windows can't be built here.** Windows changes are checked by CI's `windows` job first, then on a Windows machine by the owner or the buildIt Windows session ([Related projects](#related-projects)). Say so in your report when a Windows change is only CI-checked.
- **Accessibility permission (TCC).** Injection tests on macOS need the test app (or the terminal running `flutter test integration_test`) in System Settings → Privacy & Security → Accessibility. Only the owner can grant it: give them the exact app path. A rebuilt ad-hoc-signed debug app can count as a new app and lose the grant; sign debug builds with a development team to keep it.
- **Don't take over the owner's machine.** Injection tests move the real pointer and type real keys. Run them only when the owner says the machine is free, inject only into the test app's own window, and keep each test's injected input inside it.
- Interactive logins (`gh auth login`) must be run by the owner in a regular terminal. Give them the exact command.

## Related projects

- **`cloudflare_realtime`** (public): [`kammcs/flutter-cloudflare-realtime`](https://github.com/kammcs/flutter-cloudflare-realtime), locally at `~/Projects/kammcs/flutter-cloudflare-realtime`. An unofficial Flutter client for the Cloudflare Realtime SFU, built by another agent.
  - **It's the transport we expect in practice:** its DataChannels (`room.data`, reliable and unreliable profiles, sender identity from the channel's session, never the payload; its `docs/design.md` §9).
  - Its `ScreenGeometry` (`ScreenSource.geometry`, `ScreenShareSource.sourceGeometryChanges`) gives the shared display's or window's bounds in each OS's own desktop coordinates, the same convention as this package's surfaces ([design.md §3](docs/design.md#3-coordinates-and-the-shared-surface)).
  - Read it for context. **Don't edit it, and don't depend on it** from `lib/`. An adapter may live in `example/`.
- **buildIt.Social** (private): [`kammcs/buildit-social`](https://github.com/kammcs/buildit-social), locally at `~/Projects/kammcs/buildit-social`. A chat, video and screen-sharing app for small businesses, and the **first consumer**.
  - Its Phase 6 is remote control. The app keeps the consent dialog, the banner and border, the revoke hotkey, server-side grants and the audit log; this package does the protocol, capture and injection ([design.md §9](docs/design.md#9-how-the-first-consumer-uses-it)).
  - **You may read it for context. Never edit it,** and never copy its private details here.
  - Its Mac orchestrator session integrates this package through a **git pin** (a commit SHA in its `pubspec.yaml`), the same way it pins `cloudflare_realtime`. So: keep `main` green, and say which commit is ready when you finish a milestone.
- **Coordinating:** the owner relays between sessions, or you message the buildIt Mac session directly (SendMessage, when it is reachable). Ask there for what the consumer needs next, or for a Windows device run. Keep messages short: what changed, the commit, what to check.
