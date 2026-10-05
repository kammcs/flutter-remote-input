import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // The example's own window, for sharing it (SharedSurface.window) and
    // for the injection test (integration_test/macos_injection_test.dart):
    // its CGWindowID and how far its content sits inside its frame, in
    // points (the title bar).
    let channel = FlutterMethodChannel(
      name: "remote_input_example/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, call.method == "describe" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let frame = self.frame
      let content = self.contentRect(forFrameRect: frame)
      result([
        "windowNumber": self.windowNumber,
        "insetLeft": content.minX - frame.minX,
        "insetTop": frame.maxY - content.maxY,
        "insetRight": frame.maxX - content.maxX,
        "insetBottom": content.minY - frame.minY,
      ])
    }

    super.awakeFromNib()
  }
}
