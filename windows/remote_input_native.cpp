// The plugin's plain C API: SendInput, the local-activity hooks and the
// injection tag. See remote_input_native.h. Independent of Flutter, so it
// builds (and is compile-checked) on its own.
//
// Privacy (docs/design.md §6.6): the hooks see every key and pointer
// position on the machine. They keep a count and one reference point for
// the movement threshold, nothing else, and never log or store what was
// typed.

#include "remote_input_native.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <atomic>
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

// Pointer movement counts as local only past this distance, in pixels, from
// the last reference point: sensor jitter and a bumped desk don't pause a
// session.
constexpr int64_t kMoveThreshold = 4;

std::atomic<uint64_t> g_count{0};

// Guards g_thread, g_thread_id and g_hooks_ok across start and stop.
SRWLOCK g_lock = SRWLOCK_INIT;
HANDLE g_thread = nullptr;
DWORD g_thread_id = 0;
HANDLE g_ready = nullptr;
bool g_hooks_ok = false;

// The hook thread's own: the last reference point for movement.
POINT g_reference = {0, 0};

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

bool PastThreshold(POINT pt) {
  const int64_t dx = static_cast<int64_t>(pt.x) - g_reference.x;
  const int64_t dy = static_cast<int64_t>(pt.y) - g_reference.y;
  return dx * dx + dy * dy > kMoveThreshold * kMoveThreshold;
}

LRESULT CALLBACK MouseHook(int code, WPARAM message, LPARAM data) {
  if (code == HC_ACTION) {
    const auto* info = reinterpret_cast<const MSLLHOOKSTRUCT*>(data);
    if (IsOurs(info->flags, LLMHF_INJECTED, info->dwExtraInfo)) {
      // Where the package put the pointer: local movement is measured from
      // here.
      g_reference = info->pt;
    } else if (message != WM_MOUSEMOVE || PastThreshold(info->pt)) {
      g_reference = info->pt;
      g_count.fetch_add(1, std::memory_order_relaxed);
    }
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

// Low-level hooks are called on the thread that installed them, through its
// message loop, and Windows drops a hook that doesn't return in time
// (LowLevelHooksTimeout). Hence a thread of their own, which only pumps
// messages.
DWORD WINAPI HookThread(LPVOID) {
  MSG msg;
  // Creates the thread's message queue, so stop's WM_QUIT can't be lost.
  PeekMessageW(&msg, nullptr, WM_USER, WM_USER, PM_NOREMOVE);

  HMODULE module = nullptr;
  GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                         GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                     reinterpret_cast<LPCWSTR>(&kModuleAnchor), &module);
  if (!GetCursorPos(&g_reference)) g_reference = POINT{0, 0};

  HHOOK mouse = SetWindowsHookExW(WH_MOUSE_LL, MouseHook, module, 0);
  HHOOK keyboard = SetWindowsHookExW(WH_KEYBOARD_LL, KeyboardHook, module, 0);
  g_hooks_ok = mouse != nullptr && keyboard != nullptr;
  SetEvent(g_ready);

  if (g_hooks_ok) {
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
      TranslateMessage(&msg);
      DispatchMessageW(&msg);
    }
  }
  if (mouse != nullptr) UnhookWindowsHookEx(mouse);
  if (keyboard != nullptr) UnhookWindowsHookEx(keyboard);
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
    ReleaseSRWLockExclusive(&g_lock);
    return 1;
  }
  g_hooks_ok = false;
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
  const bool ok = g_hooks_ok;
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
