import Cocoa
import FlutterMacOS

/// The plugin's method channel: only what needs the main thread or would
/// block the Dart UI thread (docs/design.md §7.1). Injection, geometry and
/// the safety probes go through dart:ffi (RemoteInputNative.swift).
///
/// Methods, matched by lib/src/permissions.dart:
/// - `postEventAccess`: whether the Accessibility permission is granted,
///   checked off the main thread (the check takes about 12 ms).
/// - `requestPostEventAccess`: `CGRequestPostEventAccess()`, which shows
///   the system prompt the first time; returns whether it's granted now.
/// - `openAccessibilitySettings`: opens System Settings at Privacy &
///   Security > Accessibility; returns whether it opened.
public class RemoteInputPlugin: NSObject, FlutterPlugin {
  /// Holds the C entry points so the linker keeps them
  /// (remoteInputKeepEntryPoints).
  static var entryPoints: [UnsafeRawPointer] = []

  public static func register(with registrar: FlutterPluginRegistrar) {
    entryPoints = remoteInputKeepEntryPoints()
    RemoteInputNative.shared.registerDisplayReconfiguration()
    let channel = FlutterMethodChannel(name: "remote_input", binaryMessenger: registrar.messenger)
    let instance = RemoteInputPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "postEventAccess":
      DispatchQueue.global(qos: .userInitiated).async {
        let granted = CGPreflightPostEventAccess()
        RemoteInputNative.shared.storeAccess(granted)
        DispatchQueue.main.async { result(granted) }
      }
    case "requestPostEventAccess":
      let granted = CGRequestPostEventAccess()
      RemoteInputNative.shared.storeAccess(granted)
      result(granted)
    case "openAccessibilitySettings":
      guard
        let url = URL(
          string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
      else {
        result(false)
        return
      }
      result(NSWorkspace.shared.open(url))
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
