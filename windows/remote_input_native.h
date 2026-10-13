// The plugin's plain C API, called from Dart through dart:ffi
// (lib/src/host/windows/win32_ffi.dart). It doesn't depend on Flutter.
//
// - SendInput, with GetLastError read in the same native call, so the Dart
//   VM can't overwrite the error in between.
// - The local-activity monitor (docs/design.md §6.3): low-level mouse and
//   keyboard hooks on a dedicated thread with its own message loop, counting
//   input the package didn't inject, with a heartbeat and periodic
//   re-hooking so a hook Windows removed is noticed, and a count of
//   keyboards and mice removed (RIN-41).
// - The tag every injected event carries in dwExtraInfo.

#ifndef FLUTTER_PLUGIN_REMOTE_INPUT_NATIVE_H_
#define FLUTTER_PLUGIN_REMOTE_INPUT_NATIVE_H_

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

#define REMOTE_INPUT_NATIVE_EXPORT __declspec(dllexport)

// The value the package puts in dwExtraInfo of every event it injects:
// "rmti" in the high 32 bits and this process's id in the low 32, so input
// injected by another process using this package can be told apart. Local
// input is detected by Windows' injected flag, not by this tag (RIN-39):
// it's for diagnostics, and for apps reading the events.
REMOTE_INPUT_NATIVE_EXPORT uint64_t remote_input_tag(void);

// sizeof(INPUT), which Dart checks against the layout it writes (40 on
// 64-bit Windows).
REMOTE_INPUT_NATIVE_EXPORT int32_t remote_input_input_size(void);

// SendInput(count, inputs, size). Returns the number of events inserted, and
// writes GetLastError() to *error when that is fewer than count (0
// otherwise).
REMOTE_INPUT_NATIVE_EXPORT uint32_t remote_input_send_input(uint32_t count,
                                                            const void* inputs,
                                                            int32_t size,
                                                            uint32_t* error);

// Starts the hook thread if it isn't running (or has exited), and waits
// until its hooks are installed. Returns 1 if they are, 0 if they couldn't
// be. Idempotent: with the thread running, returns whether its hooks are
// installed now.
REMOTE_INPUT_NATIVE_EXPORT int32_t remote_input_activity_start(void);

// Stops the hook thread and removes its hooks. Idempotent.
REMOTE_INPUT_NATIVE_EXPORT void remote_input_activity_stop(void);

// Local input events seen since the DLL loaded: every physical (not
// injected, by any process) key and button event and wheel notch, every
// burst of physical pointer movement past 4 pixels of travel (see MouseHook
// in the .cpp), and every stall of the hook thread that hid input from the
// hooks. Only grows.
REMOTE_INPUT_NATIVE_EXPORT uint64_t remote_input_activity_count(void);

// 1 while the hook thread runs with both hooks installed by its last
// (re)install, 0 otherwise. Windows removes low-level hooks silently, so
// this alone doesn't prove they're alive: read the heartbeat too.
REMOTE_INPUT_NATIVE_EXPORT int32_t remote_input_activity_hooks_installed(void);

// Why remote_input_activity_count grew, for diagnostics: counts only.
//
// - MISSED: a stall of the hook thread longer than LowLevelHooksTimeout
//   (RIN-46), or a shorter one during which Windows recorded input the
//   hooks never saw.
// - KEY, BUTTON (buttons and wheel notches), MOVE (a burst of physical
//   movement past the threshold): input no software injected.
// - STALL: every heartbeat gap over 200 ms, whether or not it hid input.
//   Not counted as local input itself: MISSED is.
#define REMOTE_INPUT_REASON_MISSED 0
#define REMOTE_INPUT_REASON_KEY 1
#define REMOTE_INPUT_REASON_BUTTON 2
#define REMOTE_INPUT_REASON_MOVE 3
#define REMOTE_INPUT_REASON_STALL 4
#define REMOTE_INPUT_REASON_COUNT 5

// How many times [reason] (a REMOTE_INPUT_REASON_ value) was counted since
// the DLL loaded, or 0 for an unknown reason. Only grows.
REMOTE_INPUT_NATIVE_EXPORT uint64_t
remote_input_activity_reason_count(int32_t reason);

// The longest gap between two heartbeats of the hook thread since the DLL
// loaded, in milliseconds. About 100 when the thread is never delayed.
REMOTE_INPUT_NATIVE_EXPORT uint64_t remote_input_activity_longest_gap(void);

// Mouse moves the hooks saw since the DLL loaded, by origin, for
// diagnostics: [index] is 4 if the event had the injected flag (else 0),
// plus 0 for no dwExtraInfo, 1 for this process's tag, 2 for this package's
// tag from another process, 3 for any other value. 0 for an index outside
// 0-7. Counts only.
REMOTE_INPUT_NATIVE_EXPORT uint64_t
remote_input_activity_move_origin_count(int32_t index);

// The longest single physical pointer move the hooks saw since the DLL
// loaded, in whole pixels: a distance, never a position.
REMOTE_INPUT_NATIVE_EXPORT uint64_t remote_input_activity_largest_step(void);

// Milliseconds since the hook thread's message loop last handled its
// heartbeat timer (every 100 ms), or -1 if the thread isn't running. A
// large value means the thread is stuck, and Windows may have removed its
// hooks.
REMOTE_INPUT_NATIVE_EXPORT int64_t remote_input_activity_heartbeat_age(void);

// Keyboards and mice removed since the DLL loaded, Bluetooth powering off
// included (RIN-41): the hook thread compares the raw input device list
// (GetRawInputDeviceList) with its previous read on every heartbeat, and
// counts each keyboard or mouse handle that's gone. Starts at 0 and only
// grows. See CheckInputDevices in the .cpp for why it polls.
REMOTE_INPUT_NATIVE_EXPORT uint64_t remote_input_activity_devices_lost(void);

// How many keyboards and mice the hook thread's last read of the raw input
// device list found, or -1 if it hasn't read one (no thread, or the list
// couldn't be read). For diagnostics: a count, nothing else.
REMOTE_INPUT_NATIVE_EXPORT int32_t remote_input_activity_input_devices(void);

#if defined(__cplusplus)
}  // extern "C"

#include <stddef.h>

namespace remote_input {

// How many of the [before_count] device handles in [before] aren't among
// the [after_count] in [after]: the devices removed between two reads of
// the raw input device list. Neither needs to be sorted. Exposed for the
// tests.
size_t RemovedDevices(const uintptr_t* before, size_t before_count,
                      const uintptr_t* after, size_t after_count);

// What HKCU\Control Panel\Desktop\LowLevelHooksTimeout held (RIN-46).
enum class HooksTimeoutSetting {
  // The value isn't there: Windows uses its default.
  kAbsent,
  // A number of milliseconds.
  kValue,
  // There, but not a number, or the key couldn't be read.
  kUnreadable,
};

// The LowLevelHooksTimeout Windows applies, in milliseconds, for what the
// registry held ([value] only for kValue): the value, capped at 1000 (the
// documented cap from Windows 10 1709); 300 when absent (the reported
// default, which Microsoft doesn't document); and 200, the stall threshold,
// for an unreadable value or 0, so every stall counts (fails closed).
// Exposed for the tests.
uint32_t EffectiveHooksTimeout(HooksTimeoutSetting setting, uint32_t value);

// Parses a REG_SZ LowLevelHooksTimeout: decimal digits, spaces around them
// allowed, at most 2^32 - 1. False for anything else. Exposed for the
// tests.
bool ParseHooksTimeout(const wchar_t* text, uint32_t* out);

// What the hook thread knows after a stall (a heartbeat gap over 200 ms).
// Times are GetTickCount() values.
struct StallEvidence {
  // The heartbeat gap, in milliseconds.
  uint64_t gap_ms = 0;
  // The effective LowLevelHooksTimeout (EffectiveHooksTimeout).
  uint32_t hooks_timeout_ms = 0;
  // Whether GetLastInputInfo succeeded, and its time: the newest input of
  // any kind, injected included.
  bool last_input_known = false;
  uint32_t last_input = 0;
  // The newest physical and the newest injected event the hooks saw.
  uint32_t last_physical = 0;
  uint32_t last_injected = 0;
};

// Whether a stall of the hook thread may have hidden input from the hooks,
// so it counts as local input:
// - a gap longer than the hooks timeout always does (RIN-46): Windows may
//   have skipped or removed the hooks, and a later injected event, seen by
//   the hooks and recorded by GetLastInputInfo, would hide a physical event
//   they never got;
// - a shorter one does when the last-input time is more than a clock tick
//   later than the newest event the hooks saw, physical or injected
//   (RIN-39), or isn't known (fails closed).
// Exposed for the tests.
bool StallMissedInput(const StallEvidence& evidence);

}  // namespace remote_input
#endif

#endif  // FLUTTER_PLUGIN_REMOTE_INPUT_NATIVE_H_
