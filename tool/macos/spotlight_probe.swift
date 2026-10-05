// Read-only probe for docs/checkpoint.md C3: lists the on-screen windows of
// Spotlight (and the Dock, for comparison): layer, alpha and bounds. It posts
// nothing and needs no permission.
//
//   sleep 5; swift tool/macos/spotlight_probe.swift   # press Cmd+Space within 5 s
import AppKit
import CoreGraphics

let ids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Spotlight").map { $0.processIdentifier })
print("Spotlight pids:", ids.sorted(), "frontmost:", NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")
for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]] {
  let pid = (w[kCGWindowOwnerPID as String] as? Int32) ?? -1
  if ids.contains(pid) || (w[kCGWindowOwnerName as String] as? String) == "Dock" {
    print(w[kCGWindowOwnerName as String] ?? "?", "layer", w[kCGWindowLayer as String] ?? "?", "alpha", w[kCGWindowAlpha as String] ?? "?", w[kCGWindowBounds as String] ?? "?")
  }
}
