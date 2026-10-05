// The macOS host's native side: posting input events, reading display and
// window geometry, and the safety probes (docs/design.md §7.1, §7.3).
//
// Every function here is exposed to Dart as a C symbol (`@_cdecl`) and called
// synchronously through dart:ffi with `DynamicLibrary.process()`, from the
// Dart UI thread. They only use Core Graphics, Carbon's
// `IsSecureEventInputEnabled`, `NSWorkspace.frontmostApplication` and
// `NSRunningApplication.runningApplications(withBundleIdentifier:)`, which
// may be called from any thread.
//
// Privacy: nothing here logs. Key codes, text and positions pass through to
// the OS and nowhere else (docs/design.md §6.6).

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Status codes, matched by `MacosStatus` in
/// lib/src/host/macos/macos_native.dart.
enum RemoteInputStatus {
  static let ok: Int32 = 0
  static let permissionDenied: Int32 = 1
  static let failed: Int32 = 2
}

/// The tag every event the package posts carries in
/// `kCGEventSourceUserData`: "RINP".
let remoteInputEventTag: Int64 = 0x5249_4E50

/// The `CGEventFlags` bits the package computes from the modifiers the
/// session holds: Shift, Control, Option and Command, and their left and
/// right device bits (`NX_DEVICE*KEYMASK` in IOKit's IOLLEvent.h). Every
/// other bit (Caps Lock, Fn, the numeric pad flag on arrows and the
/// event-source bits) is kept as the event was created.
let remoteInputModifierMask: UInt64 =
  0x0000_0001 | 0x0000_0002 | 0x0000_0004 | 0x0000_0008 | 0x0000_0010
  | 0x0000_0020 | 0x0000_0040 | 0x0000_2000
  | CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue
  | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue

/// How long a `CGPreflightPostEventAccess()` answer is used before it is
/// refreshed in the background. The call costs about 12 ms (an IPC to
/// TCC), far too slow for every event, so a revoked permission is noticed
/// within about this long.
let remoteInputAccessLifetimeNanos: UInt64 = 1_000_000_000

/// The package's event source and its counters.
final class RemoteInputNative {
  static let shared = RemoteInputNative()

  /// A private-state source (open question 10): `CGEventSource.h` says
  /// "remote control programs ... should use kCGEventSourceStatePrivate"
  /// so their state is tracked "independent of other processes". Injected
  /// modifiers live in this table, not in the combined session state the
  /// local user's keyboard shares, and the flags of every event are set
  /// explicitly anyway.
  let source: CGEventSource?

  private let lock = NSLock()

  // Events this source posted, by the kinds the local-activity monitor
  // counts (lib/src/host/macos/macos_activity.dart). UInt32, wrapping, like
  // CGEventSource.counterForEventType.
  private var ownKeyDowns: UInt32 = 0
  private var ownFlagsChanged: UInt32 = 0
  private var ownButtonDowns: UInt32 = 0
  private var ownScrolls: UInt32 = 0
  private var ownMoves: UInt32 = 0

  private var access: Bool?
  private var accessCheckedAt: UInt64 = 0
  private var accessRefreshing = false

  private var displayGeneration: Int64 = 0
  private var reconfigurationRegistered = false

  private init() {
    let source = CGEventSource(stateID: .privateState)
    if let source = source {
      source.userData = remoteInputEventTag
      // Never hold back the local user's own input after a posted event:
      // local input must win (docs/design.md §6.3). These are the defaults
      // ("the system does not suppress local hardware events"), set
      // explicitly so they stay that way.
      source.localEventsSuppressionInterval = 0
      let all: CGEventFilterMask = [
        .permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents,
      ]
      source.setLocalEventsFilterDuringSuppressionState(all, state: .eventSuppressionStateSuppressionInterval)
      source.setLocalEventsFilterDuringSuppressionState(all, state: .eventSuppressionStateRemoteMouseDrag)
    }
    self.source = source
  }

  // MARK: Permission

  /// Whether this process may post events. With [fresh], asks TCC now
  /// (about 12 ms); otherwise answers from the cache, refreshing it in the
  /// background once it's older than [remoteInputAccessLifetimeNanos].
  func hasPostAccess(fresh: Bool) -> Bool {
    let now = DispatchTime.now().uptimeNanoseconds
    lock.lock()
    if !fresh, let cached = access {
      if now &- accessCheckedAt > remoteInputAccessLifetimeNanos && !accessRefreshing {
        accessRefreshing = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
          let granted = CGPreflightPostEventAccess()
          self.storeAccess(granted)
        }
        return cached
      }
      lock.unlock()
      return cached
    }
    lock.unlock()
    let granted = CGPreflightPostEventAccess()
    storeAccess(granted)
    return granted
  }

  /// The status for a release (a key up, a modifier's flagsChanged up, or a
  /// button up), which is posted whatever the cached access says: a stale
  /// "denied" must never leave a key or button stuck down (review M5). If
  /// the permission really is gone, the OS drops the event, as it would
  /// anyway. Returns `permissionDenied` when the cache says so, so the
  /// caller still learns that the permission seems to be missing.
  func releaseStatus() -> Int32 {
    hasPostAccess(fresh: false) ? RemoteInputStatus.ok : RemoteInputStatus.permissionDenied
  }

  func storeAccess(_ granted: Bool) {
    lock.lock()
    access = granted
    accessCheckedAt = DispatchTime.now().uptimeNanoseconds
    accessRefreshing = false
    lock.unlock()
  }

  // MARK: Posting

  /// Posts [event] at the HID tap, tagged, and counts it.
  func post(_ event: CGEvent) {
    event.setIntegerValueField(.eventSourceUserData, value: remoteInputEventTag)
    event.post(tap: .cghidEventTap)
    count(event)
  }

  private func count(_ event: CGEvent) {
    lock.lock()
    switch event.type {
    case .keyDown:
      if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { ownKeyDowns &+= 1 }
    case .flagsChanged:
      ownFlagsChanged &+= 1
    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
      ownButtonDowns &+= 1
    case .scrollWheel:
      ownScrolls &+= 1
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
      ownMoves &+= 1
    default:
      break
    }
    lock.unlock()
  }

  /// The counters of events posted by this source, in the order of
  /// `MacosActivityCounts`.
  func ownCounts() -> [UInt32] {
    lock.lock()
    defer { lock.unlock() }
    return [ownKeyDowns, ownFlagsChanged, ownButtonDowns, ownScrolls, ownMoves]
  }

  // MARK: Displays

  func registerDisplayReconfiguration() {
    lock.lock()
    if reconfigurationRegistered {
      lock.unlock()
      return
    }
    reconfigurationRegistered = true
    lock.unlock()
    CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
      if !flags.contains(.beginConfigurationFlag) {
        RemoteInputNative.shared.bumpDisplayGeneration()
      }
    }, nil)
  }

  func bumpDisplayGeneration() {
    lock.lock()
    displayGeneration &+= 1
    lock.unlock()
  }

  /// The display configuration's generation: changes after each
  /// reconfiguration, or stays 0 if the callback isn't registered (the Dart
  /// side then refreshes on a timer).
  func currentDisplayGeneration() -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    return displayGeneration
  }
}

/// Merges the session's modifier [flags] into [event]'s own flags.
func remoteInputApplyFlags(_ event: CGEvent, _ flags: UInt64) {
  let kept = event.flags.rawValue & ~remoteInputModifierMask
  event.flags = CGEventFlags(rawValue: kept | (flags & remoteInputModifierMask))
}

/// The backing scale of the display at [point]: physical pixels per point.
func remoteInputScale(at point: CGPoint) -> Double {
  var display: CGDirectDisplayID = 0
  var count: UInt32 = 0
  if CGGetDisplaysWithPoint(point, 1, &display, &count) != .success || count == 0 {
    display = CGMainDisplayID()
  }
  return remoteInputScale(of: display)
}

func remoteInputScale(of display: CGDirectDisplayID) -> Double {
  guard let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 else { return 1 }
  let scale = Double(mode.pixelWidth) / Double(mode.width)
  return scale.isFinite && scale > 0 ? scale : 1
}

func remoteInputRect(_ value: Any?) -> CGRect? {
  guard let dict = value as? NSDictionary else { return nil }
  return CGRect(dictionaryRepresentation: dict as CFDictionary)
}

// MARK: - C entry points

/// Whether this process may post events (the Accessibility permission):
/// 1 or 0. With [fresh] non-zero, asks TCC now (about 12 ms).
@_cdecl("remote_input_post_access")
public func remote_input_post_access(_ fresh: Int32) -> Int32 {
  RemoteInputNative.shared.hasPostAccess(fresh: fresh != 0) ? 1 : 0
}

/// Posts a mouse event of CGEventType [type] at ([x], [y]) in global
/// display points. [button] is the CGMouseButton number (0 left, 1 right,
/// 2 middle, 3 back, 4 forward); [clickState] is set when positive;
/// [flags] are the held modifiers' CGEventFlags. A button up is posted even
/// when the cached access says denied, so a button never stays down.
@_cdecl("remote_input_post_mouse")
public func remote_input_post_mouse(
  _ type: UInt32, _ x: Double, _ y: Double, _ button: Int32, _ clickState: Int32, _ flags: UInt64
) -> Int32 {
  let native = RemoteInputNative.shared
  let isRelease = remoteInputIsButtonUp(type)
  let status = isRelease ? native.releaseStatus() : RemoteInputStatus.ok
  guard isRelease || native.hasPostAccess(fresh: false) else { return RemoteInputStatus.permissionDenied }
  guard let source = native.source,
    let eventType = CGEventType(rawValue: type),
    let mouseButton = CGMouseButton(rawValue: UInt32(max(0, button))),
    x.isFinite, y.isFinite
  else { return RemoteInputStatus.failed }
  let point = CGPoint(x: x, y: y)
  let previous = CGEvent(source: nil)?.location
  guard let event = CGEvent(
    mouseEventSource: source, mouseType: eventType, mouseCursorPosition: point, mouseButton: mouseButton)
  else { return RemoteInputStatus.failed }
  if eventType == .otherMouseDown || eventType == .otherMouseUp || eventType == .otherMouseDragged {
    event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
  }
  if clickState > 0 {
    event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
  }
  switch eventType {
  case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
    // Apps that read relative motion (games, some drawing tools) see the
    // move as a delta too.
    if let previous = previous {
      event.setIntegerValueField(.mouseEventDeltaX, value: Int64((x - previous.x).rounded()))
      event.setIntegerValueField(.mouseEventDeltaY, value: Int64((y - previous.y).rounded()))
    }
  default:
    break
  }
  remoteInputApplyFlags(event, flags)
  native.post(event)
  return status
}

/// Whether CGEventType [type] releases a mouse button.
func remoteInputIsButtonUp(_ type: UInt32) -> Bool {
  type == CGEventType.leftMouseUp.rawValue || type == CGEventType.rightMouseUp.rawValue
    || type == CGEventType.otherMouseUp.rawValue
}

/// Posts a scroll event at ([x], [y]). [unit] is 0 for pixels and 1 for
/// lines; [wheel1] is vertical and [wheel2] horizontal, in Core Graphics'
/// sign convention (positive scrolls up and left).
@_cdecl("remote_input_post_scroll")
public func remote_input_post_scroll(
  _ x: Double, _ y: Double, _ unit: Int32, _ wheel1: Int32, _ wheel2: Int32, _ flags: UInt64
) -> Int32 {
  let native = RemoteInputNative.shared
  guard native.hasPostAccess(fresh: false) else { return RemoteInputStatus.permissionDenied }
  guard let source = native.source, x.isFinite, y.isFinite,
    let event = CGEvent(
      scrollWheelEvent2Source: source, units: unit == 1 ? .line : .pixel,
      wheelCount: 2, wheel1: wheel1, wheel2: wheel2, wheel3: 0)
  else { return RemoteInputStatus.failed }
  event.location = CGPoint(x: x, y: y)
  remoteInputApplyFlags(event, flags)
  native.post(event)
  return RemoteInputStatus.ok
}

/// Posts a key event for virtual key [keyCode] (`kVK_*`). [autorepeat]
/// marks a key repeat; [flags] are the modifiers held after this event.
/// Modifier keys come out as `flagsChanged` events, as from a keyboard. A
/// key up (a modifier's included) is posted even when the cached access
/// says denied, so a key never stays down.
@_cdecl("remote_input_post_key")
public func remote_input_post_key(
  _ keyCode: UInt16, _ down: Int32, _ autorepeat: Int32, _ flags: UInt64
) -> Int32 {
  let native = RemoteInputNative.shared
  let isRelease = down == 0
  let status = isRelease ? native.releaseStatus() : RemoteInputStatus.ok
  guard isRelease || native.hasPostAccess(fresh: false) else { return RemoteInputStatus.permissionDenied }
  guard let source = native.source,
    let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down != 0)
  else { return RemoteInputStatus.failed }
  if autorepeat != 0 && down != 0 {
    event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
  }
  remoteInputApplyFlags(event, flags)
  native.post(event)
  return status
}

/// Types [length] UTF-16 code units (1 to 20; macOS truncates longer
/// strings) as a key down and up with the string attached and no
/// modifiers, whatever the keyboard layout.
@_cdecl("remote_input_post_text")
public func remote_input_post_text(_ units: UnsafePointer<UInt16>?, _ length: Int32) -> Int32 {
  let native = RemoteInputNative.shared
  guard native.hasPostAccess(fresh: false) else { return RemoteInputStatus.permissionDenied }
  guard let units = units, length >= 1, length <= 20, let source = native.source else {
    return RemoteInputStatus.failed
  }
  for down in [true, false] {
    // Virtual key 0 is only a carrier; the string is what apps insert.
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else {
      return RemoteInputStatus.failed
    }
    event.keyboardSetUnicodeString(stringLength: Int(length), unicodeString: units)
    remoteInputApplyFlags(event, 0)
    native.post(event)
  }
  return RemoteInputStatus.ok
}

/// Writes the pointer's location in global display points to [out] (two
/// doubles). Returns 1, or 0 if it can't be read.
@_cdecl("remote_input_cursor_location")
public func remote_input_cursor_location(_ out: UnsafeMutablePointer<Double>?) -> Int32 {
  guard let out = out, let location = CGEvent(source: nil)?.location else { return 0 }
  out[0] = Double(location.x)
  out[1] = Double(location.y)
  return 1
}

/// Writes up to [capacity] displays to [out], 7 doubles each: id, x, y,
/// width, height (points, global display space), scale, isPrimary.
/// Returns how many there are (which may exceed [capacity]).
@_cdecl("remote_input_displays")
public func remote_input_displays(_ out: UnsafeMutablePointer<Double>?, _ capacity: Int32) -> Int32 {
  RemoteInputNative.shared.registerDisplayReconfiguration()
  var count: UInt32 = 0
  guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return 0 }
  var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
  guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return 0 }
  let main = CGMainDisplayID()
  if let out = out {
    for (i, id) in ids.prefix(Int(min(count, UInt32(max(0, capacity))))).enumerated() {
      let bounds = CGDisplayBounds(id)
      let base = out + i * 7
      base[0] = Double(id)
      base[1] = Double(bounds.origin.x)
      base[2] = Double(bounds.origin.y)
      base[3] = Double(bounds.width)
      base[4] = Double(bounds.height)
      base[5] = remoteInputScale(of: id)
      base[6] = id == main ? 1 : 0
    }
  }
  return Int32(count)
}

/// The display configuration's generation (see
/// `RemoteInputNative.currentDisplayGeneration`).
@_cdecl("remote_input_display_generation")
public func remote_input_display_generation() -> Int64 {
  RemoteInputNative.shared.currentDisplayGeneration()
}

/// Reads window [windowId] (a CGWindowID) and the on-screen windows above
/// it. No titles are read, so no Screen Recording permission is needed.
///
/// Writes a header of 7 doubles to [out] (x, y, width, height, on screen
/// 0/1, owner pid, scale), then up to [capacity] records of 7 doubles for
/// the windows above it, front to back (owner pid, layer, alpha, x, y,
/// width, height). Returns the number of records written, or -1 if the
/// window is gone.
@_cdecl("remote_input_window_info")
public func remote_input_window_info(
  _ windowId: UInt32, _ out: UnsafeMutablePointer<Double>?, _ capacity: Int32
) -> Int32 {
  guard let out = out,
    let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowId) as? [[String: Any]],
    let info = list.first,
    let bounds = remoteInputRect(info[kCGWindowBounds as String])
  else { return -1 }
  let onScreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.doubleValue ?? -1
  out[0] = Double(bounds.origin.x)
  out[1] = Double(bounds.origin.y)
  out[2] = Double(bounds.width)
  out[3] = Double(bounds.height)
  out[4] = onScreen ? 1 : 0
  out[5] = pid
  out[6] = remoteInputScale(at: CGPoint(x: bounds.midX, y: bounds.midY))
  guard onScreen, capacity > 0,
    let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], windowId)
      as? [[String: Any]]
  else { return 0 }
  return remoteInputWriteRecords(above, out + 7, capacity)
}

/// Writes up to [capacity] window records of 7 doubles to [out] (owner pid,
/// layer, alpha, x, y, width, height), in the list's order. Returns how
/// many were written.
func remoteInputWriteRecords(
  _ windows: [[String: Any]], _ out: UnsafeMutablePointer<Double>, _ capacity: Int32
) -> Int32 {
  var written: Int32 = 0
  for window in windows {
    if written >= capacity { break }
    guard let rect = remoteInputRect(window[kCGWindowBounds as String]) else { continue }
    let base = out + Int(written) * 7
    base[0] = (window[kCGWindowOwnerPID as String] as? NSNumber)?.doubleValue ?? -1
    base[1] = (window[kCGWindowLayer as String] as? NSNumber)?.doubleValue ?? 0
    base[2] = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
    base[3] = Double(rect.origin.x)
    base[4] = Double(rect.origin.y)
    base[5] = Double(rect.width)
    base[6] = Double(rect.height)
    written += 1
  }
  return written
}

/// Writes every on-screen window, front to back, to [out]: up to
/// [capacity] records of 7 doubles, the same as `remote_input_window_info`
/// writes for the windows above a window. Returns the number written, or -1
/// if the list can't be read. No titles are read, so no Screen Recording
/// permission is needed. About 0.3 to 0.6 ms with 25 windows (macOS 27).
@_cdecl("remote_input_window_list")
public func remote_input_window_list(_ out: UnsafeMutablePointer<Double>?, _ capacity: Int32) -> Int32 {
  guard let out = out,
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]]
  else { return -1 }
  return remoteInputWriteRecords(list, out, max(0, capacity))
}

/// Apps whose non-activating panels take keystrokes without becoming
/// `frontmostApplication` (review M4), and that own no on-screen window
/// except that panel. Spotlight is an `LSUIElement` agent started on demand:
/// at rest it isn't running, or its windows are off screen. Launchers with
/// a permanent status item (Alfred, Raycast) would need their panel told
/// apart from it, which the window list can't do without titles.
let remoteInputKeyboardPanelApps = ["com.apple.Spotlight"]

/// Writes the process ids of the running apps in
/// `remoteInputKeyboardPanelApps` to [out], up to [capacity]. Returns how
/// many were written. About 2 µs when none is running, 0.2 ms when one is.
@_cdecl("remote_input_keyboard_panel_pids")
public func remote_input_keyboard_panel_pids(_ out: UnsafeMutablePointer<Int32>?, _ capacity: Int32) -> Int32 {
  guard let out = out else { return 0 }
  var written: Int32 = 0
  for bundleId in remoteInputKeyboardPanelApps {
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
      if written >= capacity { return written }
      out[Int(written)] = app.processIdentifier
      written += 1
    }
  }
  return written
}

/// The process id of the frontmost app, or -1.
@_cdecl("remote_input_frontmost_pid")
public func remote_input_frontmost_pid() -> Int32 {
  NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
}

/// Whether Secure Event Input is on (a password field has focus, or
/// Terminal's Secure Keyboard Entry): 1 or 0.
@_cdecl("remote_input_secure_input")
public func remote_input_secure_input() -> Int32 {
  IsSecureEventInputEnabled() ? 1 : 0
}

/// Whether the user's session can take input: 0 if it can, 1 if it isn't
/// on the console (fast user switching, the login window), 2 if the screen
/// is locked, 3 if there is no window-server session.
@_cdecl("remote_input_session_state")
public func remote_input_session_state() -> Int32 {
  guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return 3 }
  if let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool, !onConsole { return 1 }
  // Not in the public header, but long-standing and widely relied on.
  if let locked = session["CGSSessionScreenIsLocked"] as? Bool, locked { return 2 }
  return 0
}

/// Writes a snapshot for the local-activity monitor to [out], 12 doubles:
/// the HID system's counts of key downs, flag changes (modifier keys),
/// button downs, scrolls and moves (with drags); the pointer's x and y;
/// then the same five counts for events this package posted.
///
/// The HID system state table "reflects the combined state of all hardware
/// event sources posting from the HID system" (`CGEventSource.h`), and the
/// package posts from its own private-state source, so its events are not
/// expected in these counts (open question 2: verified on a device by
/// example/integration_test/macos_injection_test.dart).
@_cdecl("remote_input_activity_snapshot")
public func remote_input_activity_snapshot(_ out: UnsafeMutablePointer<Double>?) {
  guard let out = out else { return }
  func hid(_ type: CGEventType) -> UInt32 {
    CGEventSource.counterForEventType(.hidSystemState, eventType: type)
  }
  out[0] = Double(hid(.keyDown))
  out[1] = Double(hid(.flagsChanged))
  out[2] = Double(hid(.leftMouseDown) &+ hid(.rightMouseDown) &+ hid(.otherMouseDown))
  out[3] = Double(hid(.scrollWheel))
  out[4] = Double(
    hid(.mouseMoved) &+ hid(.leftMouseDragged) &+ hid(.rightMouseDragged) &+ hid(.otherMouseDragged))
  let location = CGEvent(source: nil)?.location ?? .zero
  out[5] = Double(location.x)
  out[6] = Double(location.y)
  for (i, value) in RemoteInputNative.shared.ownCounts().enumerated() {
    out[7 + i] = Double(value)
  }
}

/// Keeps the C entry points in the binary: Dart finds them by name with
/// `dlsym`, which the linker can't see, so dead-code stripping would drop
/// them from a statically linked plugin. Called from the plugin's
/// `register(with:)`.
func remoteInputKeepEntryPoints() -> [UnsafeRawPointer] {
  let access: @convention(c) (Int32) -> Int32 = remote_input_post_access
  let mouse: @convention(c) (UInt32, Double, Double, Int32, Int32, UInt64) -> Int32 =
    remote_input_post_mouse
  let scroll: @convention(c) (Double, Double, Int32, Int32, Int32, UInt64) -> Int32 =
    remote_input_post_scroll
  let key: @convention(c) (UInt16, Int32, Int32, UInt64) -> Int32 = remote_input_post_key
  let text: @convention(c) (UnsafePointer<UInt16>?, Int32) -> Int32 = remote_input_post_text
  let cursor: @convention(c) (UnsafeMutablePointer<Double>?) -> Int32 = remote_input_cursor_location
  let displays: @convention(c) (UnsafeMutablePointer<Double>?, Int32) -> Int32 = remote_input_displays
  let generation: @convention(c) () -> Int64 = remote_input_display_generation
  let window: @convention(c) (UInt32, UnsafeMutablePointer<Double>?, Int32) -> Int32 =
    remote_input_window_info
  let windows: @convention(c) (UnsafeMutablePointer<Double>?, Int32) -> Int32 = remote_input_window_list
  let panels: @convention(c) (UnsafeMutablePointer<Int32>?, Int32) -> Int32 = remote_input_keyboard_panel_pids
  let frontmost: @convention(c) () -> Int32 = remote_input_frontmost_pid
  let secure: @convention(c) () -> Int32 = remote_input_secure_input
  let session: @convention(c) () -> Int32 = remote_input_session_state
  let activity: @convention(c) (UnsafeMutablePointer<Double>?) -> Void = remote_input_activity_snapshot
  return [
    unsafeBitCast(access, to: UnsafeRawPointer.self),
    unsafeBitCast(mouse, to: UnsafeRawPointer.self),
    unsafeBitCast(scroll, to: UnsafeRawPointer.self),
    unsafeBitCast(key, to: UnsafeRawPointer.self),
    unsafeBitCast(text, to: UnsafeRawPointer.self),
    unsafeBitCast(cursor, to: UnsafeRawPointer.self),
    unsafeBitCast(displays, to: UnsafeRawPointer.self),
    unsafeBitCast(generation, to: UnsafeRawPointer.self),
    unsafeBitCast(window, to: UnsafeRawPointer.self),
    unsafeBitCast(windows, to: UnsafeRawPointer.self),
    unsafeBitCast(panels, to: UnsafeRawPointer.self),
    unsafeBitCast(frontmost, to: UnsafeRawPointer.self),
    unsafeBitCast(secure, to: UnsafeRawPointer.self),
    unsafeBitCast(session, to: UnsafeRawPointer.self),
    unsafeBitCast(activity, to: UnsafeRawPointer.self),
  ]
}
