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
//   stalled, long enough that Windows may have dropped its hooks. The hooks
//   are installed again, and the stall counts as local input only if input
//   in it went unseen: Windows recorded input (GetLastInputInfo) later than
//   the newest event the hooks saw (RIN-39). A stall alone isn't local
//   input: under load (a full-screen share being encoded, a stream of
//   injected events) the timer can run late with nobody at the machine. An
//   event the hooks got late, within LowLevelHooksTimeout, was still seen.
// - The hooks are installed again every kRehookMs anyway, in case one was
//   removed without a stall the timer could see. New hooks go in before the
//   old ones come out, so there's no gap.
// - If installing fails, g_installed is false (Dart reports the monitor as
//   down) and every tick retries.

constexpr UINT kHeartbeatMs = 100;
constexpr ULONGLONG kStallMs = 200;
constexpr ULONGLONG kRehookMs = 15000;

// How much later than the newest hooked event Windows' last-input time may
// be and still be that event: both come from GetTickCount(), whose
// resolution is about 16 ms.
constexpr DWORD kSeenSlackMs = 16;

std::atomic<uint64_t> g_count{0};

// What each count was, for diagnostics: indexed by remote_input_activity_*
// reason (remote_input_native.h). Counts only, never what was typed or
// where.
std::atomic<uint64_t> g_reasons[REMOTE_INPUT_REASON_COUNT] = {};
// The longest heartbeat gap seen, in milliseconds.
std::atomic<uint64_t> g_longest_gap{0};

// Mouse moves by origin, for diagnosing what counts (RIN-39): indexed by
// remote_input_activity_move_origin_count's index. Counts only.
std::atomic<uint64_t> g_move_origins[8] = {};
// The longest single untagged move, in whole pixels: a distance, never a
// position.
std::atomic<uint64_t> g_largest_step{0};

// Which of the move-origin counters an event with these fields goes in.
int MoveOrigin(DWORD flags, DWORD injected_flag, ULONG_PTR extra_info);

void Count(int32_t reason) {
  g_reasons[reason].fetch_add(1, std::memory_order_relaxed);
  if (reason != REMOTE_INPUT_REASON_STALL) {
    g_count.fetch_add(1, std::memory_order_relaxed);
  }
}

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
DWORD g_last_seen = 0;      // The newest hooked event's time, tagged or not.

// An address inside this module, for GetModuleHandleExW.
const char kModuleAnchor = 0;

uint64_t Tag() {
  static const uint64_t tag =
      kTagMagic | static_cast<uint64_t>(GetCurrentProcessId());
  return tag;
}

// Records that the hooks saw an event stamped [time] (GetTickCount()).
// Capped at now: software injecting with a future timestamp mustn't hide
// a later stall's missed input.
void Seen(DWORD time) {
  const DWORD now = GetTickCount();
  if (static_cast<LONG>(time - now) > 0) time = now;
  if (static_cast<LONG>(time - g_last_seen) > 0) g_last_seen = time;
}

bool IsOurs(DWORD flags, DWORD injected_flag, ULONG_PTR extra_info) {
  return (flags & injected_flag) != 0 &&
         static_cast<uint64_t>(extra_info) == Tag();
}

int MoveOrigin(DWORD flags, DWORD injected_flag, ULONG_PTR extra_info) {
  const uint64_t extra = static_cast<uint64_t>(extra_info);
  int kind = 3;  // Some other value.
  if (extra == 0) {
    kind = 0;
  } else if (extra == Tag()) {
    kind = 1;
  } else if ((extra & 0xFFFFFFFF00000000ull) == kTagMagic) {
    kind = 2;  // This package's tag from another process.
  }
  return ((flags & injected_flag) != 0 ? 4 : 0) + kind;
}

// Adds an untagged move to pt to the path. Whether the path now counts as
// local movement.
bool UntaggedMoveCounts(POINT pt) {
  const DWORD now = GetTickCount();
  if (now - g_path_time > kMoveGapMs) g_path = 0;
  g_path_time = now;
  const double dx = static_cast<double>(pt.x) - g_previous.x;
  const double dy = static_cast<double>(pt.y) - g_previous.y;
  const double step = std::sqrt(dx * dx + dy * dy);
  if (static_cast<uint64_t>(step) > g_largest_step.load()) {
    g_largest_step.store(static_cast<uint64_t>(step));
  }
  g_path += step;
  if (g_path <= kMoveThreshold) return false;
  g_path = 0;
  return true;
}

LRESULT CALLBACK MouseHook(int code, WPARAM message, LPARAM data) {
  if (code == HC_ACTION) {
    const auto* info = reinterpret_cast<const MSLLHOOKSTRUCT*>(data);
    Seen(info->time);
    if (message == WM_MOUSEMOVE) {
      g_move_origins[MoveOrigin(info->flags, LLMHF_INJECTED,
                                info->dwExtraInfo)]
          .fetch_add(1, std::memory_order_relaxed);
    }
    if (!IsOurs(info->flags, LLMHF_INJECTED, info->dwExtraInfo)) {
      // Buttons and the wheel always count; movement past the threshold.
      if (message != WM_MOUSEMOVE) {
        Count(REMOTE_INPUT_REASON_BUTTON);
      } else if (UntaggedMoveCounts(info->pt)) {
        Count(REMOTE_INPUT_REASON_MOVE);
      }
    }
    g_previous = info->pt;
  }
  return CallNextHookEx(nullptr, code, message, data);
}

LRESULT CALLBACK KeyboardHook(int code, WPARAM message, LPARAM data) {
  if (code == HC_ACTION) {
    const auto* info = reinterpret_cast<const KBDLLHOOKSTRUCT*>(data);
    Seen(info->time);
    if (!IsOurs(info->flags, LLKHF_INJECTED, info->dwExtraInfo)) {
      Count(REMOTE_INPUT_REASON_KEY);
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
  const ULONGLONG gap = now - g_last_beat;
  const bool stalled = gap > kStallMs;
  g_last_beat = now;
  if (gap > g_longest_gap.load(std::memory_order_relaxed)) {
    g_longest_gap.store(gap, std::memory_order_relaxed);
  }
  if (stalled) {
    Count(REMOTE_INPUT_REASON_STALL);
    // Hook calls queued during the stall ran before this timer message, so
    // g_last_seen is up to date. If the last-input time can't be read, the
    // stall counts (fail closed).
    LASTINPUTINFO last = {sizeof(LASTINPUTINFO), 0};
    const bool known = GetLastInputInfo(&last) != FALSE;
    if (remote_input::StallMissedInput(known, last.dwTime, g_last_seen)) {
      Count(REMOTE_INPUT_REASON_MISSED);
    }
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
  // Input before monitoring started isn't unseen input.
  g_last_seen = GetTickCount();

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

namespace remote_input {

bool StallMissedInput(bool last_input_known, uint32_t last_input,
                      uint32_t last_seen) {
  if (!last_input_known) return true;
  // Signed, so GetTickCount()'s wrap after 49.7 days compares right.
  return static_cast<int32_t>(last_input - last_seen) >
         static_cast<int32_t>(kSeenSlackMs);
}

}  // namespace remote_input

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

uint64_t remote_input_activity_reason_count(int32_t reason) {
  if (reason < 0 || reason >= REMOTE_INPUT_REASON_COUNT) return 0;
  return g_reasons[reason].load(std::memory_order_relaxed);
}

uint64_t remote_input_activity_longest_gap(void) {
  return g_longest_gap.load(std::memory_order_relaxed);
}

uint64_t remote_input_activity_move_origin_count(int32_t index) {
  if (index < 0 || index >= 8) return 0;
  return g_move_origins[index].load(std::memory_order_relaxed);
}

uint64_t remote_input_activity_largest_step(void) {
  return g_largest_step.load();
}
