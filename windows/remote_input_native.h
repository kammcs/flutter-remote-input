// The plugin's plain C API, called from Dart through dart:ffi
// (lib/src/host/windows/win32_ffi.dart). It doesn't depend on Flutter.
//
// - SendInput, with GetLastError read in the same native call, so the Dart
//   VM can't overwrite the error in between.
// - The local-activity monitor (docs/design.md §6.3): low-level mouse and
//   keyboard hooks on a dedicated thread with its own message loop, counting
//   input the package didn't inject.
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

// Starts the hook thread if it isn't running, and waits until its hooks are
// installed. Returns 1 if they are, 0 if they couldn't be. Idempotent.
REMOTE_INPUT_NATIVE_EXPORT int32_t remote_input_activity_start(void);

// Stops the hook thread and removes its hooks. Idempotent.
REMOTE_INPUT_NATIVE_EXPORT void remote_input_activity_stop(void);

// Local input events seen since the DLL loaded: every key and button event
// and wheel notch not tagged by this process, and every untagged pointer
// movement more than 4 pixels from the last reference point. Only grows.
REMOTE_INPUT_NATIVE_EXPORT uint64_t remote_input_activity_count(void);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // FLUTTER_PLUGIN_REMOTE_INPUT_NATIVE_H_
