import 'dart:typed_data';

/// A rectangle in desktop pixels, as Win32's `RECT`: [right] and [bottom]
/// are exclusive.
typedef WinRect = ({int left, int top, int right, int bottom});

/// A monitor, from `EnumDisplayMonitors` and `GetMonitorInfoW`.
final class WinMonitor {
  /// Creates a [WinMonitor].
  const WinMonitor({
    required this.handle,
    required this.bounds,
    required this.isPrimary,
    required this.deviceName,
  });

  /// The `HMONITOR`. Valid until the display configuration changes.
  final int handle;

  /// `rcMonitor`, in physical pixels of the virtual screen.
  final WinRect bounds;

  /// Whether `MONITORINFOF_PRIMARY` is set.
  final bool isPrimary;

  /// `szDevice`, such as `\\.\DISPLAY1`.
  final String deviceName;
}

/// The result of one `SendInput` call.
typedef SendInputResult = ({int sent, int error});

/// The Win32 calls the Windows host makes: a seam, so the injector, the
/// surface resolver and the probe are unit tested with a fake on any OS.
/// The real one is `FfiWin32Api` (`win32_ffi.dart`), the only code that
/// touches `dart:ffi`.
///
/// Handles (`HWND`, `HMONITOR`) are plain ints; 0 is `NULL`.
abstract interface class Win32Api {
  /// The tag every injected event carries in `dwExtraInfo`.
  int get injectionTag;

  /// Calls `SendInput` with [inputs], an array of `INPUT` records
  /// (`input_records.dart`), and reads `GetLastError` right after it.
  SendInputResult sendInput(Uint8List inputs);

  /// `SetCursorPos`: for the fallback pointer placement.
  bool setCursorPos(int x, int y);

  /// The virtual screen: `SM_XVIRTUALSCREEN` … `SM_CYVIRTUALSCREEN`.
  WinRect virtualScreen();

  /// `SPI_GETWHEELSCROLLLINES`.
  int wheelScrollLines();

  /// `SPI_GETWHEELSCROLLCHARS`.
  int wheelScrollChars();

  /// Whether the calling thread's DPI awareness context is per-monitor V2.
  bool isPerMonitorAwareV2();

  /// Every monitor, in `EnumDisplayMonitors` order.
  List<WinMonitor> monitors();

  /// The monitor [handle] now, or `null` if the handle is stale.
  WinMonitor? monitor(int handle);

  /// `IsWindow`.
  bool isWindow(int hwnd);

  /// `IsIconic`: minimized.
  bool isIconic(int hwnd);

  /// `IsWindowVisible`.
  bool isWindowVisible(int hwnd);

  /// Whether DWM cloaks the window (`DWMWA_CLOAKED`), as it does windows on
  /// another virtual desktop.
  bool isCloaked(int hwnd);

  /// The window's visible frame: `DWMWA_EXTENDED_FRAME_BOUNDS`, or
  /// `GetWindowRect` where DWM can't say. `null` if neither works.
  WinRect? windowBounds(int hwnd);

  /// `WindowFromPoint`.
  int windowFromPoint(int x, int y);

  /// `GetAncestor(hwnd, GA_ROOT)`.
  int rootWindow(int hwnd);

  /// `GetForegroundWindow`.
  int foregroundWindow();

  /// The id of the process that created [hwnd]
  /// (`GetWindowThreadProcessId`), or 0.
  int processIdOfWindow(int hwnd);

  /// `GetCurrentProcessId`.
  int get currentProcessId;

  /// Whether the input desktop is the user's `Default` desktop. False when
  /// `OpenInputDesktop` fails (the secure desktop: UAC, Ctrl+Alt+Del, the
  /// lock screen) or names another desktop.
  bool isInputDesktopDefault();

  /// The mandatory integrity level of process [pid] (its integrity SID's
  /// last sub-authority: 0x2000 medium, 0x3000 high), or `null` if the
  /// process or its token can't be queried.
  int? integrityLevel(int pid);

  /// This process's integrity level, or `null` if it can't be read.
  int? get ownIntegrityLevel;
}

/// The native side of the local-activity monitor: the plugin DLL's
/// low-level hooks and their counter (`windows/remote_input_native.cpp`).
abstract interface class NativeActivity {
  /// Starts the hook thread, if it isn't running. Whether the hooks are in.
  bool start();

  /// Stops the hook thread.
  void stop();

  /// Local input events seen so far: a counter that only grows.
  int count();
}

/// Integrity levels: the last sub-authority of a token's mandatory label
/// SID.
abstract final class IntegrityLevel {
  /// `SECURITY_MANDATORY_MEDIUM_RID`: a normal app.
  static const int medium = 0x2000;

  /// `SECURITY_MANDATORY_HIGH_RID`: run as administrator.
  static const int high = 0x3000;
}

/// The last sub-authority of the `SID` in [sid]: an integrity level, for a
/// mandatory label SID. `null` if [sid] isn't a well-formed SID.
///
/// A `SID` is `Revision` (1), `SubAuthorityCount` (1),
/// `IdentifierAuthority` (6), then `SubAuthorityCount` little-endian
/// `DWORD`s.
int? lastSubAuthority(Uint8List sid) {
  if (sid.length < 8 || sid[0] != 1) return null;
  final count = sid[1];
  if (count == 0 || sid.length < 8 + 4 * count) return null;
  return ByteData.sublistView(sid)
      .getUint32(8 + 4 * (count - 1), Endian.little);
}
