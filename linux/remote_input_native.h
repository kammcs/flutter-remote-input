// The Linux host's native calls (docs/design.md §7.5), as C functions that
// lib/src/host/linux/linux_ffi.dart looks up with dart:ffi. The method
// channel (remote_input_plugin.cc) is used only for the RemoteDesktop portal,
// whose dialog is asynchronous.
//
// Never log what is injected: key codes, characters and positions stay out of
// every message (CLAUDE.md, "Never log what the user types").
#ifndef REMOTE_INPUT_NATIVE_H_
#define REMOTE_INPUT_NATIVE_H_

#include <stdint.h>

#define RI_EXPORT extern "C" __attribute__((visibility("default")))

// What a post call returned, matched by LinuxStatus in linux_native.dart.
#define RI_OK 0
#define RI_PERMISSION_DENIED 1  // Wayland: no portal session, or it closed.
#define RI_FAILED 2
#define RI_UNMAPPED 3  // A character the keyboard layout can't type (Wayland).
#define RI_PAUSED 4    // Wayland: the compositor paused the devices.

// The backend, from the session (ri_backend).
#define RI_BACKEND_NONE 0
#define RI_BACKEND_X11 1
#define RI_BACKEND_WAYLAND 2

// Local-input reasons, in LinuxActivityReason order.
#define RI_REASON_KEY 0
#define RI_REASON_BUTTON 1
#define RI_REASON_MOVE 2
#define RI_REASON_IDLE 3   // Wayland: the idle time reset without our posts.
#define RI_REASON_STALL 4  // The monitor thread ran late (not local input).
#define RI_REASON_COUNT 5

// The user's session, from logind (ri_session_state).
#define RI_SESSION_ACTIVE 0
#define RI_SESSION_LOCKED 1
#define RI_SESSION_INACTIVE 2  // Another session is in front (user switching).
#define RI_SESSION_UNKNOWN 3   // No logind: treated as active.

// --- Common -----------------------------------------------------------------

// RI_BACKEND_*: Wayland when the session is a Wayland one (WAYLAND_DISPLAY or
// XDG_SESSION_TYPE=wayland), X11 when there's a DISPLAY, else none.
// REMOTE_INPUT_LINUX_BACKEND=x11 forces X11 (tests under XWayland).
RI_EXPORT int32_t ri_backend(void);

// Whether Wayland support was compiled in (libei was found at build time).
RI_EXPORT int32_t ri_has_wayland(void);

// The effective user id (0 is root).
RI_EXPORT int32_t ri_euid(void);

// This process's id.
RI_EXPORT int32_t ri_pid(void);

// RI_SESSION_*, as of the monitor thread's last read (every 250 ms while it
// runs; read once synchronously otherwise).
RI_EXPORT int32_t ri_session_state(void);

// Milliseconds on CLOCK_MONOTONIC.
RI_EXPORT int64_t ri_now_ms(void);

// --- X11 (XTest) ------------------------------------------------------------

// Opens the injector's X connection if needed. 0 when it's open with XTest
// and XInput 2; 1 no display; 2 no XTest; 3 no XInput 2.2.
RI_EXPORT int32_t ri_x11_open(void);

// Moves the pointer to root-window pixel (x, y).
RI_EXPORT int32_t ri_x11_move(int32_t x, int32_t y);

// Presses or releases X button [button] (1 left, 2 middle, 3 right, 4 to 7
// the wheel, 8 back, 9 forward).
RI_EXPORT int32_t ri_x11_button(int32_t button, int32_t down);

// Presses or releases the key at Linux evdev code [code] (X keycode code+8).
RI_EXPORT int32_t ri_x11_key(int32_t code, int32_t down);

// Types one Unicode code point by binding it to a spare keycode (a pool,
// rebound least recently used first) and pressing it.
RI_EXPORT int32_t ri_x11_text(uint32_t codepoint);

// Unbinds the spare keycodes ri_x11_text bound. Idempotent.
RI_EXPORT void ri_x11_text_restore(void);

// The root window's size in pixels.
RI_EXPORT int32_t ri_x11_screen_size(int32_t* width, int32_t* height);

// The monitors (RandR 1.5), up to [max]: each id (the monitor's name atom),
// x, y, width, height and whether it's primary. Returns how many.
RI_EXPORT int32_t ri_x11_monitors(int32_t max, int64_t* ids, int32_t* rects,
                                  int32_t* primary);

// Window [xid]'s client area in root pixels. Returns 0 gone, 1 shown,
// 2 hidden (unmapped, minimized).
RI_EXPORT int32_t ri_x11_window(uint64_t xid, int32_t* x, int32_t* y,
                                int32_t* width, int32_t* height);

// Whether root pixel (x, y) shows window [xid]: the topmost window there is
// [xid]'s own X client's (its menus and dialogs), or transient for it. 1 yes,
// 0 no, -1 unknown (counts as no).
RI_EXPORT int32_t ri_x11_on_window(uint64_t xid, int32_t x, int32_t y);

// Whether the active window (_NET_ACTIVE_WINDOW, else the input focus) is
// [xid]'s client's or transient for it. 1 yes, 0 no, -1 unknown.
RI_EXPORT int32_t ri_x11_has_focus(uint64_t xid);

// Whether the topmost window at (x, y) belongs to this process (its GDK
// connection, or _NET_WM_PID). 1 yes, 0 no, -1 unknown (counts as yes).
RI_EXPORT int32_t ri_x11_own_window_at(int32_t x, int32_t y);

// Whether this process's window is the active one. 1 yes, 0 no, -1 unknown
// (counts as yes).
RI_EXPORT int32_t ri_x11_own_app_in_front(void);

// --- Wayland (the RemoteDesktop portal and libei) ---------------------------

// Whether a portal session is connected to EIS with a pointer and keyboard.
RI_EXPORT int32_t ri_wl_connected(void);

// Grows each time the portal session or its devices or regions change.
RI_EXPORT int32_t ri_wl_generation(void);

// Whether a device the session needs is paused by the compositor.
RI_EXPORT int32_t ri_wl_paused(void);

// The regions of the absolute pointers, up to [max]: each id (1, 2, ...,
// stable for the portal session), x, y, width, height (logical pixels; a
// window stream's region starts at 0, 0), scale (x1000), and its mapping id
// into [mapping] (max * 64 bytes, NUL-terminated). Returns how many.
RI_EXPORT int32_t ri_wl_regions(int32_t max, int32_t* ids, int32_t* rects,
                                int32_t* scales, char* mapping);

// Moves the pointer to (x, y) in region [region] (0: whichever region
// contains the point, on a pointer whose regions are the desktop's).
RI_EXPORT int32_t ri_wl_move(int32_t region, double x, double y);

// Presses or releases evdev button [button] (BTN_LEFT...).
RI_EXPORT int32_t ri_wl_button(int32_t button, int32_t down);

// Scrolls by [dx], [dy] logical pixels, or by discrete steps of 120 per
// notch when [discrete].
RI_EXPORT int32_t ri_wl_scroll(double dx, double dy, int32_t discrete);

// Presses or releases the key at evdev code [code].
RI_EXPORT int32_t ri_wl_key(int32_t code, int32_t down);

// Types one code point with the compositor's keymap (Shift and AltGr as
// needed). RI_UNMAPPED when the layout can't type it.
RI_EXPORT int32_t ri_wl_text(uint32_t codepoint);

// --- The local-activity monitor (a native thread) ---------------------------

// Starts the thread if it isn't running. Whether it's watching.
RI_EXPORT int32_t ri_activity_start(void);

// Stops it.
RI_EXPORT void ri_activity_stop(void);

// Local input seen so far: a counter that only grows.
RI_EXPORT int64_t ri_activity_count(void);

// Whether the thread's sources are healthy: X11, XInput 2 selected on the
// root window; Wayland, the last idle-time read succeeded.
RI_EXPORT int32_t ri_activity_healthy(void);

// Milliseconds since the thread's loop last ran, or -1 if it isn't running.
RI_EXPORT int64_t ri_activity_heartbeat_age_ms(void);

// How many times [reason] (RI_REASON_*) was counted.
RI_EXPORT int64_t ri_activity_reason(int32_t reason);

// The longest gap between two runs of the thread's loop, in ms.
RI_EXPORT int64_t ri_activity_longest_gap_ms(void);

// Keyboards and pointing devices removed so far (udev, and XInput 2 slave
// removals on X11): a counter that only grows. -1 if udev couldn't be read.
RI_EXPORT int64_t ri_activity_devices_lost(void);

// Records that the package just posted input (Wayland's idle-time rule).
void ri_note_own_post(void);

// Starts and stops the GTK-side tracking of this process's windows on
// Wayland (focus and pointer), from the plugin's main-thread timer.
RI_EXPORT int32_t ri_wl_own_app_in_front(void);
RI_EXPORT int32_t ri_wl_pointer_over_own_window(void);

// For remote_input_plugin.cc.
void ri_set_gdk_x11_base(uint32_t base, uint32_t mask);
void ri_set_own_window_state(int32_t focused, int32_t pointer_over);

#endif  // REMOTE_INPUT_NATIVE_H_
