// The plugin's plain C API, called from Dart through dart:ffi
// (lib/src/host/windows/win32_ffi.dart). It doesn't depend on Flutter.
//
// - SendInput, with GetLastError read in the same native call, so the Dart
//   VM can't overwrite the error in between.
// - The local-activity monitor (docs/design.md §6.3): low-level mouse and
//   keyboard hooks on a dedicated thread with its own message loop, counting
//   input the package didn't inject, with a heartbeat and periodic
//   re-hooking so a hook Windows removed is noticed.
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
// injected by another process using this package still counts as local.
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

// Local input events seen since the DLL loaded: every key and button event
// and wheel notch not tagged by this process, every burst of untagged
// pointer movement past 4 pixels of travel (see MouseHook in the .cpp), and
// every stall of the hook thread that hid input from the hooks. Only grows.
REMOTE_INPUT_NATIVE_EXPORT uint64_t remote_input_activity_count(void);

// 1 while the hook thread runs with both hooks installed by its last
// (re)install, 0 otherwise. Windows removes low-level hooks silently, so
// this alone doesn't prove they're alive: read the heartbeat too.
REMOTE_INPUT_NATIVE_EXPORT int32_t remote_input_activity_hooks_installed(void);

// Why remote_input_activity_count grew, for diagnostics: counts only.
//
// - MISSED: a stall of the hook thread during which Windows recorded input
//   the hooks never saw.
// - KEY, BUTTON (buttons and wheel notches), MOVE (a burst of untagged
//   movement past the threshold): input the package didn't inject.
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

// The longest single untagged pointer move the hooks saw since the DLL
// loaded, in whole pixels: a distance, never a position.
REMOTE_INPUT_NATIVE_EXPORT uint64_t remote_input_activity_largest_step(void);

// Milliseconds since the hook thread's message loop last handled its
// heartbeat timer (every 100 ms), or -1 if the thread isn't running. A
// large value means the thread is stuck, and Windows may have removed its
// hooks.
REMOTE_INPUT_NATIVE_EXPORT int64_t remote_input_activity_heartbeat_age(void);

#if defined(__cplusplus)
}  // extern "C"

namespace remote_input {

// Whether a stall of the hook thread hid input from the hooks: Windows'
// last-input time [last_input] is more than a clock tick later than the
// newest event the hooks saw, [last_seen] (both GetTickCount()). Fails
// closed: true when the last-input time isn't known. Exposed for the tests.
bool StallMissedInput(bool last_input_known, uint32_t last_input,
                      uint32_t last_seen);

}  // namespace remote_input
#endif

#endif  // FLUTTER_PLUGIN_REMOTE_INPUT_NATIVE_H_
