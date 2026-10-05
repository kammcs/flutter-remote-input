// The plugin's plain C API: SendInput, the local-activity hooks and the
// injection tag. See remote_input_native.h. Independent of Flutter, so it
// builds (and is compile-checked) on its own.
//
// Privacy (docs/design.md §6.6): the hooks see every key and pointer
// position on the machine. They keep a count, the previous pointer position
// and a running movement distance for the threshold, nothing else, and
// never log or store what was typed.

#include "remote_input_native.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <atomic>
#include <cmath>
#include <cstddef>

// The INPUT layout lib/src/host/windows/input_records.dart writes.
#if defined(_WIN64)
static_assert(sizeof(INPUT) == 40, "INPUT is 40 bytes on 64-bit Windows");
static_assert(offsetof(INPUT, mi) == 8, "the INPUT union is at offset 8");
static_assert(offsetof(INPUT, ki) == 8, "the INPUT union is at offset 8");
static_assert(sizeof(MOUSEINPUT) == 32, "MOUSEINPUT is 32 bytes");
static_assert(offsetof(MOUSEINPUT, dx) == 0, "MOUSEINPUT.dx");
static_assert(offsetof(MOUSEINPUT, dy) == 4, "MOUSEINPUT.dy");
static_assert(offsetof(MOUSEINPUT, mouseData) == 8, "MOUSEINPUT.mouseData");
static_assert(offsetof(MOUSEINPUT, dwFlags) == 12, "MOUSEINPUT.dwFlags");
static_assert(offsetof(MOUSEINPUT, time) == 16, "MOUSEINPUT.time");
static_assert(offsetof(MOUSEINPUT, dwExtraInfo) == 24,
              "MOUSEINPUT.dwExtraInfo");
static_assert(sizeof(KEYBDINPUT) == 24, "KEYBDINPUT is 24 bytes");
static_assert(offsetof(KEYBDINPUT, wVk) == 0, "KEYBDINPUT.wVk");
static_assert(offsetof(KEYBDINPUT, wScan) == 2, "KEYBDINPUT.wScan");
static_assert(offsetof(KEYBDINPUT, dwFlags) == 4, "KEYBDINPUT.dwFlags");
static_assert(offsetof(KEYBDINPUT, time) == 8, "KEYBDINPUT.time");
static_assert(offsetof(KEYBDINPUT, dwExtraInfo) == 16,
              "KEYBDINPUT.dwExtraInfo");
static_assert(sizeof(ULONG_PTR) == 8, "dwExtraInfo holds the 64-bit tag");
#endif

namespace {

// "rmti", above the process id.
constexpr uint64_t kTagMagic = 0x726D746900000000ull;

// --- Pointer movement (docs/design.md §6.3) ---------------------------------
//
// Untagged pointer movement is measured on its own, so a viewer's moves
// can't mask it. Each untagged WM_MOUSEMOVE adds its distance from the
// previous mouse event, whatever that event's source, to a running path
// length. Tagged events only move that previous point: they never reset the
// path. The path resets when kMoveGapMs pass without untagged movement, and
// when it counts. Movement counts as local once the path is longer than
// kMoveThreshold pixels.
//
// - A physical mouse moved while a viewer streams moves at 250 Hz: each of
//   its events lands some pixels from where the viewer's last move put the
//   pointer, so its own displacements add up and count within a few events,
//   however many of the viewer's moves come in between.
// - Sensor jitter and a bumped desk: a pixel or two, then nothing for
//   kMoveGapMs. Less than kMoveThreshold in total doesn't pause a session.
// - Slow, steady physical movement keeps its path alive (its events are less
//   than kMoveGapMs apart) and counts after a few pixels.

// Pointer travel, in pixels, past which untagged movement counts.
constexpr double kMoveThreshold = 4.0;

// A gap in untagged movement this long, in milliseconds, starts a new path.
constexpr DWORD kMoveGapMs = 100;

// --- Hook health (docs/design.md §6.3) --------------------------------------
//
// Windows silently removes a low-level hook whose thread doesn't return in
// time (LowLevelHooksTimeout), and nothing tells the app. So:
// - The hook thread's message loop runs a timer every kHeartbeatMs, and each
//   tick stores the time (g_heartbeat). Dart reads its age and treats the
//   monitor as down while it's stale, so a stuck thread blocks injection
//   instead of failing open.
// - A tick more than kStallMs after the previous one means the thread was
//   stalled, long enough that Windows may have dropped its hooks and input
//   in the gap may have gone unseen: the stall counts as local input, and
//   the hooks are installed again.
// - The hooks are installed again every kRehookMs anyway, in case one was
//   removed without a stall the timer could see. New hooks go in before the
//   old ones come out, so there's no gap.
// - If installing fails, g_installed is false (Dart reports the monitor as
//   down) and every tick retries.

constexpr UINT kHeartbeatMs = 100;
constexpr ULONGLONG kStallMs = 200;
constexpr ULONGLONG kRehookMs = 15000;

std::atomic<uint64_t> g_count{0};

// Written by the hook thread, read by any thread.
std::atomic<bool> g_installed{false};
// GetTickCount64() at the last heartbeat; 0 while no thread runs.
std::atomic<uint64_t> g_heartbeat{0};

// Guards g_thread, g_thread_id, g_ready and g_start_ok across start and
// stop.
SRWLOCK g_lock = SRWLOCK_INIT;
HANDLE g_thread = nullptr;
DWORD g_thread_id = 0;
HANDLE g_ready = nullptr;
bool g_start_ok = false;

// The hook thread's own state: no other thread touches it.
HMODULE g_module = nullptr;
HHOOK g_mouse = nullptr;
HHOOK g_keyboard = nullptr;
ULONGLONG g_last_beat = 0;
ULONGLONG g_last_hooked = 0;
POINT g_previous = {0, 0};  // The previous mouse event's position.
double g_path = 0;          // Untagged travel in the current path, pixels.
DWORD g_path_time = 0;      // GetTickCount() at its last untagged move.

// An address inside this module, for GetModuleHandleExW.
const char kModuleAnchor = 0;

uint64_t Tag() {
  static const uint64_t tag =
      kTagMagic | static_cast<uint64_t>(GetCurrentProcessId());
  return tag;
}

bool IsOurs(DWORD flags, DWORD injected_flag, ULONG_PTR extra_info) {
  return (flags & injected_flag) != 0 &&
         static_cast<uint64_t>(extra_info) == Tag();
}

// Adds an untagged move to pt to the path. Whether the path now counts as
// local movement.
bool UntaggedMoveCounts(POINT pt) {
  const DWORD now = GetTickCount();
  if (now - g_path_time > kMoveGapMs) g_path = 0;
  g_path_time = now;
  const double dx = static_cast<double>(pt.x) - g_previous.x;
  const double dy = static_cast<double>(pt.y) - g_previous.y;
  g_path += std::sqrt(dx * dx + dy * dy);
  if (g_path <= kMoveThreshold) return false;
  g_path = 0;
  return true;
}

LRESULT CALLBACK MouseHook(int code, WPARAM message, LPARAM data) {
  if (code == HC_ACTION) {
    const auto* info = reinterpret_cast<const MSLLHOOKSTRUCT*>(data);
    if (!IsOurs(info->flags, LLMHF_INJECTED, info->dwExtraInfo)) {
      // Buttons and the wheel always count; movement past the threshold.
      if (message != WM_MOUSEMOVE || UntaggedMoveCounts(info->pt)) {
        g_count.fetch_add(1, std::memory_order_relaxed);
      }
    }
    g_previous = info->pt;
  }
  return CallNextHookEx(nullptr, code, message, data);
}

LRESULT CALLBACK KeyboardHook(int code, WPARAM message, LPARAM data) {
  if (code == HC_ACTION) {
    const auto* info = reinterpret_cast<const KBDLLHOOKSTRUCT*>(data);
    if (!IsOurs(info->flags, LLKHF_INJECTED, info->dwExtraInfo)) {
      g_count.fetch_add(1, std::memory_order_relaxed);
    }
  }
  return CallNextHookEx(nullptr, code, message, data);
}

void RemoveHooks() {
  // Fails harmlessly for a hook Windows already removed.
  if (g_mouse != nullptr) UnhookWindowsHookEx(g_mouse);
  if (g_keyboard != nullptr) UnhookWindowsHookEx(g_keyboard);
  g_mouse = nullptr;
  g_keyboard = nullptr;
}

// Installs both hooks, then removes the previous pair. On failure, keeps the
// previous pair (they may still work) but reports the hooks as not
// installed, since they can't be vouched for. Hook thread only.
bool InstallHooks() {
  HHOOK mouse = SetWindowsHookExW(WH_MOUSE_LL, MouseHook, g_module, 0);
  HHOOK keyboard =
      SetWindowsHookExW(WH_KEYBOARD_LL, KeyboardHook, g_module, 0);
  if (mouse == nullptr || keyboard == nullptr) {
    if (mouse != nullptr) UnhookWindowsHookEx(mouse);
    if (keyboard != nullptr) UnhookWindowsHookEx(keyboard);
    g_installed.store(false);
    return false;
  }
  RemoveHooks();
  g_mouse = mouse;
  g_keyboard = keyboard;
  g_last_hooked = GetTickCount64();
  g_installed.store(true);
  return true;
}

// The heartbeat timer's tick, on the hook thread.
void OnHeartbeat() {
  const ULONGLONG now = GetTickCount64();
  const bool stalled = now - g_last_beat > kStallMs;
  g_last_beat = now;
  if (stalled) {
    // Input during the stall may have gone unseen: count it as local.
    g_count.fetch_add(1, std::memory_order_relaxed);
  }
  if (stalled || !g_installed.load() || now - g_last_hooked >= kRehookMs) {
    InstallHooks();
  }
  g_heartbeat.store(now);
}

// Low-level hooks are called on the thread that installed them, through its
// message loop, and Windows drops a hook that doesn't return in time
// (LowLevelHooksTimeout). Hence a thread of their own, which only pumps
// messages and runs the heartbeat.
DWORD WINAPI HookThread(LPVOID) {
  MSG msg;
  // Creates the thread's message queue, so stop's WM_QUIT can't be lost.
  PeekMessageW(&msg, nullptr, WM_USER, WM_USER, PM_NOREMOVE);

  GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                         GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                     reinterpret_cast<LPCWSTR>(&kModuleAnchor), &g_module);
  if (!GetCursorPos(&g_previous)) g_previous = POINT{0, 0};
  g_path = 0;
  g_path_time = GetTickCount();

  const bool hooked = InstallHooks();
  // A thread timer: WM_TIMER with a null hwnd, handled in the loop below.
  const UINT_PTR timer =
      hooked ? SetTimer(nullptr, 0, kHeartbeatMs, nullptr) : 0;
  const bool ok = hooked && timer != 0;
  const ULONGLONG now = GetTickCount64();
  g_last_beat = now;
  g_heartbeat.store(ok ? now : 0);
  if (!ok) g_installed.store(false);
  g_start_ok = ok;
  SetEvent(g_ready);

  if (ok) {
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
      if (msg.message == WM_TIMER && msg.hwnd == nullptr &&
          msg.wParam == timer) {
        OnHeartbeat();
        continue;
      }
      TranslateMessage(&msg);
      DispatchMessageW(&msg);
    }
  }
  g_installed.store(false);
  g_heartbeat.store(0);
  if (timer != 0) KillTimer(nullptr, timer);
  RemoveHooks();
  return 0;
}

// Joins the hook thread. Called with g_lock held.
void JoinThread() {
  WaitForSingleObject(g_thread, INFINITE);
  CloseHandle(g_thread);
  g_thread = nullptr;
  g_thread_id = 0;
}

}  // namespace

uint64_t remote_input_tag(void) { return Tag(); }

int32_t remote_input_input_size(void) {
  return static_cast<int32_t>(sizeof(INPUT));
}

uint32_t remote_input_send_input(uint32_t count, const void* inputs,
                                 int32_t size, uint32_t* error) {
  if (inputs == nullptr || size != static_cast<int32_t>(sizeof(INPUT))) {
    if (error != nullptr) *error = ERROR_INVALID_PARAMETER;
    return 0;
  }
  SetLastError(ERROR_SUCCESS);
  const UINT sent =
      SendInput(count, const_cast<INPUT*>(static_cast<const INPUT*>(inputs)),
                size);
  if (error != nullptr) {
    *error = sent == count ? 0u : static_cast<uint32_t>(GetLastError());
  }
  return sent;
}

int32_t remote_input_activity_start(void) {
  AcquireSRWLockExclusive(&g_lock);
  if (g_thread != nullptr) {
    if (WaitForSingleObject(g_thread, 0) != WAIT_OBJECT_0) {
      // Running: its own heartbeat retries hooks that failed.
      const bool installed = g_installed.load();
      ReleaseSRWLockExclusive(&g_lock);
      return installed ? 1 : 0;
    }
    // The thread left its loop on its own: start a new one.
    JoinThread();
  }
  g_start_ok = false;
  g_ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (g_ready == nullptr) {
    ReleaseSRWLockExclusive(&g_lock);
    return 0;
  }
  g_thread = CreateThread(nullptr, 0, HookThread, nullptr, 0, &g_thread_id);
  if (g_thread == nullptr) {
    CloseHandle(g_ready);
    g_ready = nullptr;
    ReleaseSRWLockExclusive(&g_lock);
    return 0;
  }
  // Hook procedures must return quickly, whatever the app's threads do.
  SetThreadPriority(g_thread, THREAD_PRIORITY_HIGHEST);
  WaitForSingleObject(g_ready, INFINITE);
  CloseHandle(g_ready);
  g_ready = nullptr;
  const bool ok = g_start_ok;
  // A thread whose hooks failed has already left its loop.
  if (!ok) JoinThread();
  ReleaseSRWLockExclusive(&g_lock);
  return ok ? 1 : 0;
}

void remote_input_activity_stop(void) {
  AcquireSRWLockExclusive(&g_lock);
  if (g_thread != nullptr) {
    PostThreadMessageW(g_thread_id, WM_QUIT, 0, 0);
    JoinThread();
  }
  ReleaseSRWLockExclusive(&g_lock);
}

uint64_t remote_input_activity_count(void) {
  return g_count.load(std::memory_order_relaxed);
}

int32_t remote_input_activity_hooks_installed(void) {
  return g_installed.load() ? 1 : 0;
}

int64_t remote_input_activity_heartbeat_age(void) {
  const uint64_t beat = g_heartbeat.load();
  if (beat == 0) return -1;
  const uint64_t now = GetTickCount64();
  return now <= beat ? 0 : static_cast<int64_t>(now - beat);
}
