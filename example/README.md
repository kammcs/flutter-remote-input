# remote_input example

The example app for [`remote_input`](../README.md). For now it's a shell. Milestone M6 ([roadmap](../docs/roadmap.md)) turns it into a two-machine demo: one machine runs it as the **host** (Windows or macOS), which shares a surface and injects; the other runs it as the **viewer** (any platform), which captures input over the remote view.

```sh
flutter run -d macos      # or windows; or chrome, linux, an Android or iOS device as a viewer
```

The macOS app is sandboxed on purpose, so it tests the App Sandbox question in [design.md §7.3](../docs/design.md#73-macos).
