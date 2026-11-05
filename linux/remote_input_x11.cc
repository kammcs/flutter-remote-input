// X11 injection and window queries for the Linux host (docs/design.md §7.5):
// XTest for input, RandR for monitors, and the window tree for bounds,
// occlusion, focus and the host's own windows.
//
// The injector has its own X connection, used from the Dart thread only.
// X protocol errors on the package's connections (a window that has gone, for
// example) are trapped by a handler that passes every other connection's
// errors on to the handler it replaced (GDK's), so GDK keeps its own traps.
#include <X11/XKBlib.h>
#include <X11/Xatom.h>
#include <X11/Xlib-xcb.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XInput2.h>
#include <X11/extensions/XTest.h>
#include <X11/extensions/Xrandr.h>
#include <time.h>
#include <unistd.h>
#include <xcb/xcb.h>

#include <atomic>
#include <cstring>
#include <mutex>

#include "remote_input_native.h"
#include "remote_input_x11.h"

namespace {

std::mutex g_mutex;
Display* g_dpy = nullptr;
bool g_open_tried = false;
int32_t g_open_status = 1;
uint32_t g_resource_mask = 0x1fffff;

std::atomic<uint32_t> g_gdk_base{0};
std::atomic<uint32_t> g_gdk_mask{0};

XErrorHandler g_previous_handler = nullptr;
std::atomic<bool> g_handler_installed{false};
std::atomic<Display*> g_monitor_dpy{nullptr};
thread_local int t_error = 0;

int OnXError(Display* display, XErrorEvent* error) {
  if (display == g_dpy || display == g_monitor_dpy.load()) {
    t_error = error->error_code;
    return 0;
  }
  return g_previous_handler ? g_previous_handler(display, error) : 0;
}

// Spare keycodes for text the layout can't type: keycodes with no keysyms,
// each bound to a character while it's typed, least recently used first.
//
// X clients translate a key event with the keymap as it is when they read
// the event, fetched afresh after a MappingNotify, not as it was when the key
// was pressed. So a keycode is never rebound within kRebindAfterMs of its
// last press (a character that would need it is skipped instead), and the
// pool is as large as the keymap allows.
constexpr int kPoolSize = 128;
constexpr int64_t kRebindAfterMs = 1000;
struct PoolEntry {
  int keycode = 0;
  KeySym keysym = NoSymbol;
  int64_t used_ms = 0;
};
PoolEntry g_pool[kPoolSize];
int g_pool_count = -1;  // -1: not looked for yet.
int g_keysyms_per_keycode = 0;

int64_t NowMs() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

// The keyboard description for typing text with the layout, refreshed at
// most every second (a layout change shows within that).
XkbDescPtr g_xkb = nullptr;
int64_t g_xkb_read_ms = 0;

Atom g_net_active_window = None;
Atom g_net_wm_pid = None;
Atom g_wm_state = None;

uint32_t ClientBase(Window w) { return static_cast<uint32_t>(w) & ~g_resource_mask; }

bool Synced() {
  XSync(g_dpy, False);
  bool ok = t_error == 0;
  t_error = 0;
  return ok;
}

// The window's WM_STATE, or -1 without one.
long WmState(Window w) {
  Atom type;
  int format;
  unsigned long n, after;
  unsigned char* data = nullptr;
  long state = -1;
  if (XGetWindowProperty(g_dpy, w, g_wm_state, 0, 2, False, g_wm_state, &type, &format, &n,
                         &after, &data) == Success &&
      data != nullptr) {
    if (type == g_wm_state && format == 32 && n >= 1) {
      state = reinterpret_cast<long*>(data)[0];
    }
    XFree(data);
  }
  t_error = 0;
  return state;
}

// The client window inside top-level [top] (a frame): the first descendant
// with WM_STATE, or [top] itself (an override-redirect menu, or no WM).
Window ClientOf(Window top, int depth = 0) {
  if (top == None) return None;
  if (WmState(top) >= 0) return top;
  if (depth >= 3) return None;
  Window root, parent, *children = nullptr;
  unsigned int n = 0;
  Window found = None;
  if (XQueryTree(g_dpy, top, &root, &parent, &children, &n) && children != nullptr) {
    for (int i = static_cast<int>(n) - 1; i >= 0 && found == None; i--) {
      found = ClientOf(children[i], depth + 1);
    }
    XFree(children);
  }
  t_error = 0;
  if (found == None && depth == 0) return top;
  return found;
}

// The top-level window (a child of the root) at root pixel (x, y), honouring
// input shapes, or None. Sets *ok to false if the server couldn't be asked.
Window TopLevelAt(int x, int y, bool* ok) {
  Window root = DefaultRootWindow(g_dpy);
  Window child = None;
  int dx, dy;
  *ok = XTranslateCoordinates(g_dpy, root, root, x, y, &dx, &dy, &child) && t_error == 0;
  t_error = 0;
  return child;
}

long WindowPid(Window w) {
  Atom type;
  int format;
  unsigned long n, after;
  unsigned char* data = nullptr;
  long pid = -1;
  if (XGetWindowProperty(g_dpy, w, g_net_wm_pid, 0, 1, False, XA_CARDINAL, &type, &format, &n,
                         &after, &data) == Success &&
      data != nullptr) {
    if (type == XA_CARDINAL && format == 32 && n == 1) pid = reinterpret_cast<long*>(data)[0];
    XFree(data);
  }
  t_error = 0;
  return pid;
}

// Whether [w] is [shared]'s client's, or transient for one of its windows
// (a dialog of another process, as a GW_OWNER chain is on Windows).
bool BelongsTo(Window w, Window shared) {
  const uint32_t base = ClientBase(shared);
  for (int i = 0; i < 8 && w != None; i++) {
    if (ClientBase(w) == base) return true;
    Window parent = None;
    if (!XGetTransientForHint(g_dpy, w, &parent) || t_error != 0) {
      t_error = 0;
      return false;
    }
    w = parent;
  }
  return false;
}

bool IsOwn(Window client) {
  const uint32_t base = g_gdk_base.load();
  const uint32_t mask = g_gdk_mask.load();
  if (base != 0 && (static_cast<uint32_t>(client) & ~mask) == base) return true;
  return WindowPid(client) == getpid();
}

Window ActiveWindow(bool* ok) {
  Atom type;
  int format;
  unsigned long n, after;
  unsigned char* data = nullptr;
  Window active = None;
  bool have = false;
  if (XGetWindowProperty(g_dpy, DefaultRootWindow(g_dpy), g_net_active_window, 0, 1, False,
                         XA_WINDOW, &type, &format, &n, &after, &data) == Success &&
      data != nullptr) {
    if (type == XA_WINDOW && format == 32 && n == 1) {
      active = static_cast<Window>(reinterpret_cast<unsigned long*>(data)[0]);
      have = true;
    }
    XFree(data);
  }
  t_error = 0;
  if (!have) {
    int revert;
    *ok = XGetInputFocus(g_dpy, &active, &revert) != 0;
    if (active == PointerRoot) active = None;
  } else {
    *ok = true;
  }
  return active;
}

int32_t Open() {
  if (g_dpy != nullptr) return 0;
  if (g_open_tried) return g_open_status;
  g_open_tried = true;
  g_dpy = XOpenDisplay(nullptr);
  if (g_dpy == nullptr) return g_open_status = 1;
  if (!g_handler_installed.exchange(true)) g_previous_handler = XSetErrorHandler(OnXError);
  int ev, err, major, minor;
  if (!XTestQueryExtension(g_dpy, &ev, &err, &major, &minor)) {
    XCloseDisplay(g_dpy);
    g_dpy = nullptr;
    return g_open_status = 2;
  }
  int opcode;
  int xi_major = 2, xi_minor = 2;
  if (!XQueryExtension(g_dpy, "XInputExtension", &opcode, &ev, &err) ||
      XIQueryVersion(g_dpy, &xi_major, &xi_minor) != Success) {
    XCloseDisplay(g_dpy);
    g_dpy = nullptr;
    return g_open_status = 3;
  }
  xcb_connection_t* conn = XGetXCBConnection(g_dpy);
  if (conn != nullptr) g_resource_mask = xcb_get_setup(conn)->resource_id_mask;
  g_net_active_window = XInternAtom(g_dpy, "_NET_ACTIVE_WINDOW", False);
  g_net_wm_pid = XInternAtom(g_dpy, "_NET_WM_PID", False);
  g_wm_state = XInternAtom(g_dpy, "WM_STATE", False);
  return g_open_status = 0;
}

void FindPool() {
  g_pool_count = 0;
  int min = 0, max = 0;
  XDisplayKeycodes(g_dpy, &min, &max);
  int per = 0;
  KeySym* map = XGetKeyboardMapping(g_dpy, min, max - min + 1, &per);
  if (map == nullptr) return;
  g_keysyms_per_keycode = per;
  // From the top: the highest keycodes are the least likely to be on a
  // physical keyboard.
  for (int kc = max; kc >= min && g_pool_count < kPoolSize; kc--) {
    bool empty = true;
    for (int i = 0; i < per; i++) {
      if (map[(kc - min) * per + i] != NoSymbol) {
        empty = false;
        break;
      }
    }
    if (empty) g_pool[g_pool_count++].keycode = kc;
  }
  XFree(map);
}

// A key and the modifiers (Shift, Mod5 for AltGr) that type [sym] with the
// current layout group and locked modifiers (Caps Lock counts). Returns
// false if the layout can't.
bool FindInLayout(KeySym sym, KeyCode* key, unsigned int* mods) {
  const int64_t now = NowMs();
  if (g_xkb == nullptr || now - g_xkb_read_ms > 1000) {
    if (g_xkb != nullptr) XkbFreeKeyboard(g_xkb, 0, True);
    g_xkb = XkbGetMap(g_dpy, XkbAllClientInfoMask, XkbUseCoreKbd);
    g_xkb_read_ms = now;
    t_error = 0;
  }
  if (g_xkb == nullptr) return false;
  XkbStateRec state;
  if (XkbGetState(g_dpy, XkbUseCoreKbd, &state) != Success) return false;
  const unsigned int locked = state.locked_mods;
  const unsigned int candidates[] = {0, ShiftMask, Mod5Mask, ShiftMask | Mod5Mask};
  for (unsigned int extra : candidates) {
    for (int kc = g_xkb->min_key_code; kc <= g_xkb->max_key_code; kc++) {
      // Never a spare keycode the pool may rebind.
      bool spare = false;
      for (int i = 0; i < g_pool_count; i++) {
        if (g_pool[i].keycode == kc) spare = true;
      }
      if (spare) continue;
      unsigned int consumed = 0;
      KeySym out = NoSymbol;
      // Group in bits 13-14, as in a key event's state.
      const unsigned int event_state = locked | extra | (state.group << 13);
      if (!XkbTranslateKeyCode(g_xkb, static_cast<KeyCode>(kc), event_state, &consumed, &out)) {
        continue;
      }
      if (out == sym) {
        *key = static_cast<KeyCode>(kc);
        *mods = extra;
        return true;
      }
    }
  }
  return false;
}

// The first keycode whose first keysym is [sym] (a modifier key).
KeyCode ModifierKey(KeySym sym) {
  if (g_xkb == nullptr) return 0;
  for (int kc = g_xkb->min_key_code; kc <= g_xkb->max_key_code; kc++) {
    if (XkbKeycodeToKeysym(g_dpy, static_cast<KeyCode>(kc), 0, 0) == sym) {
      return static_cast<KeyCode>(kc);
    }
  }
  return 0;
}

KeySym KeysymFor(uint32_t cp) {
  if ((cp >= 0x20 && cp <= 0x7e) || (cp >= 0xa0 && cp <= 0xff)) return cp;
  return 0x01000000 | cp;
}

bool Bind(PoolEntry* e, KeySym sym) {
  KeySym syms[8];
  int per = g_keysyms_per_keycode < 1 ? 1 : (g_keysyms_per_keycode > 8 ? 8 : g_keysyms_per_keycode);
  for (int i = 0; i < per; i++) syms[i] = sym;
  XChangeKeyboardMapping(g_dpy, e->keycode, per, syms, 1);
  if (!Synced()) return false;
  e->keysym = sym;
  return true;
}

}  // namespace

void ri_x11_set_monitor_display(Display* display) { g_monitor_dpy.store(display); }

void ri_x11_install_error_handler() {
  if (!g_handler_installed.exchange(true)) g_previous_handler = XSetErrorHandler(OnXError);
}

void ri_set_gdk_x11_base(uint32_t base, uint32_t mask) {
  g_gdk_mask.store(mask);
  g_gdk_base.store(base);
}

RI_EXPORT int32_t ri_x11_open(void) {
  std::lock_guard<std::mutex> lock(g_mutex);
  return Open();
}

RI_EXPORT int32_t ri_x11_move(int32_t x, int32_t y) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (Open() != 0) return RI_FAILED;
  if (!XTestFakeMotionEvent(g_dpy, -1, x, y, CurrentTime)) return RI_FAILED;
  XFlush(g_dpy);
  return RI_OK;
}

RI_EXPORT int32_t ri_x11_button(int32_t button, int32_t down) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (Open() != 0 || button < 1 || button > 9) return RI_FAILED;
  if (!XTestFakeButtonEvent(g_dpy, static_cast<unsigned int>(button), down ? True : False,
                            CurrentTime)) {
    return RI_FAILED;
  }
  XFlush(g_dpy);
  return RI_OK;
}

RI_EXPORT int32_t ri_x11_key(int32_t code, int32_t down) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (Open() != 0 || code < 0 || code > 247) return RI_FAILED;
  if (!XTestFakeKeyEvent(g_dpy, static_cast<unsigned int>(code + 8), down ? True : False,
                         CurrentTime)) {
    return RI_FAILED;
  }
  XFlush(g_dpy);
  return RI_OK;
}

RI_EXPORT int32_t ri_x11_text(uint32_t codepoint) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (Open() != 0) return RI_FAILED;
  if (g_pool_count < 0) FindPool();
  const KeySym sym = KeysymFor(codepoint);
  // With the layout first: no keymap change, so every client reads it right.
  KeyCode key = 0;
  unsigned int mods = 0;
  if (FindInLayout(sym, &key, &mods)) {
    const KeyCode shift = (mods & ShiftMask) ? ModifierKey(XK_Shift_L) : 0;
    const KeyCode l3 = (mods & Mod5Mask) ? ModifierKey(XK_ISO_Level3_Shift) : 0;
    if (((mods & ShiftMask) && shift == 0) || ((mods & Mod5Mask) && l3 == 0)) {
      key = 0;
    } else {
      if (shift) XTestFakeKeyEvent(g_dpy, shift, True, CurrentTime);
      if (l3) XTestFakeKeyEvent(g_dpy, l3, True, CurrentTime);
      XTestFakeKeyEvent(g_dpy, key, True, CurrentTime);
      XTestFakeKeyEvent(g_dpy, key, False, CurrentTime);
      if (l3) XTestFakeKeyEvent(g_dpy, l3, False, CurrentTime);
      if (shift) XTestFakeKeyEvent(g_dpy, shift, False, CurrentTime);
      return Synced() ? RI_OK : RI_FAILED;
    }
  }
  if (g_pool_count == 0) return RI_UNMAPPED;
  const int64_t now = NowMs();
  PoolEntry* entry = nullptr;
  for (int i = 0; i < g_pool_count; i++) {
    if (g_pool[i].keysym == sym) entry = &g_pool[i];
  }
  if (entry == nullptr) {
    // The least recently used keycode, if it's old enough to rebind.
    PoolEntry* oldest = &g_pool[0];
    for (int i = 1; i < g_pool_count; i++) {
      if (g_pool[i].used_ms < oldest->used_ms) oldest = &g_pool[i];
    }
    if (oldest->keysym != NoSymbol && now - oldest->used_ms < kRebindAfterMs) return RI_UNMAPPED;
    if (!Bind(oldest, sym)) return RI_FAILED;
    entry = oldest;
  }
  entry->used_ms = now;
  XTestFakeKeyEvent(g_dpy, static_cast<unsigned int>(entry->keycode), True, CurrentTime);
  XTestFakeKeyEvent(g_dpy, static_cast<unsigned int>(entry->keycode), False, CurrentTime);
  return Synced() ? RI_OK : RI_FAILED;
}

RI_EXPORT void ri_x11_text_restore(void) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_dpy == nullptr || g_pool_count <= 0) return;
  bool any = false;
  const int64_t now = NowMs();
  for (int i = 0; i < g_pool_count; i++) {
    if (g_pool[i].keysym == NoSymbol || now - g_pool[i].used_ms < kRebindAfterMs) continue;
    KeySym none[8] = {NoSymbol, NoSymbol, NoSymbol, NoSymbol,
                      NoSymbol, NoSymbol, NoSymbol, NoSymbol};
    int per = g_keysyms_per_keycode < 1 ? 1 : (g_keysyms_per_keycode > 8 ? 8 : g_keysyms_per_keycode);
    XChangeKeyboardMapping(g_dpy, g_pool[i].keycode, per, none, 1);
    g_pool[i].keysym = NoSymbol;
    any = true;
  }
  if (any) Synced();
}

RI_EXPORT int32_t ri_x11_screen_size(int32_t* width, int32_t* height) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (Open() != 0) return 0;
  *width = DisplayWidth(g_dpy, DefaultScreen(g_dpy));
  *height = DisplayHeight(g_dpy, DefaultScreen(g_dpy));
  return 1;
}

RI_EXPORT int32_t ri_x11_monitors(int32_t max, int64_t* ids, int32_t* rects, int32_t* primary) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (Open() != 0) return 0;
  int n = 0;
  XRRMonitorInfo* monitors = XRRGetMonitors(g_dpy, DefaultRootWindow(g_dpy), True, &n);
  t_error = 0;
  if (monitors == nullptr) {
    if (max < 1) return 0;
    // No RandR 1.5: the whole root window as one display.
    ids[0] = 1;
    rects[0] = 0;
    rects[1] = 0;
    rects[2] = DisplayWidth(g_dpy, DefaultScreen(g_dpy));
    rects[3] = DisplayHeight(g_dpy, DefaultScreen(g_dpy));
    primary[0] = 1;
    return 1;
  }
  int count = n < max ? n : max;
  for (int i = 0; i < count; i++) {
    ids[i] = static_cast<int64_t>(monitors[i].name);
    rects[i * 4] = monitors[i].x;
    rects[i * 4 + 1] = monitors[i].y;
    rects[i * 4 + 2] = monitors[i].width;
    rects[i * 4 + 3] = monitors[i].height;
    primary[i] = monitors[i].primary ? 1 : 0;
  }
  XRRFreeMonitors(monitors);
  return count;
}

RI_EXPORT int32_t ri_x11_window(uint64_t xid, int32_t* x, int32_t* y, int32_t* width,
                                int32_t* height) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (Open() != 0) return 0;
  const Window w = static_cast<Window>(xid);
  XWindowAttributes a;
  t_error = 0;
  if (!XGetWindowAttributes(g_dpy, w, &a) || t_error != 0) {
    t_error = 0;
    return 0;
  }
  Window child;
  int rx = 0, ry = 0;
  if (!XTranslateCoordinates(g_dpy, w, a.root, 0, 0, &rx, &ry, &child) || t_error != 0) {
    t_error = 0;
    return 0;
  }
  *x = rx;
  *y = ry;
  *width = a.width;
  *height = a.height;
  if (a.map_state != IsViewable) return 2;
  if (WmState(w) == IconicState) return 2;
  return 1;
}

RI_EXPORT int32_t ri_x11_on_window(uint64_t xid, int32_t x, int32_t y) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (Open() != 0) return -1;
  bool ok;
  Window top = TopLevelAt(x, y, &ok);
  if (!ok) return -1;
  if (top == None) return 0;
  Window client = ClientOf(top);
  return BelongsTo(client, static_cast<Window>(xid)) ? 1 : 0;
}

RI_EXPORT int32_t ri_x11_has_focus(uint64_t xid) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (Open() != 0) return -1;
  bool ok;
  Window active = ActiveWindow(&ok);
  if (!ok) return -1;
  if (active == None) return 0;
  return BelongsTo(active, static_cast<Window>(xid)) ? 1 : 0;
}

RI_EXPORT int32_t ri_x11_own_window_at(int32_t x, int32_t y) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (Open() != 0) return -1;
  bool ok;
  Window top = TopLevelAt(x, y, &ok);
  if (!ok) return -1;
  if (top == None) return 0;
  return IsOwn(ClientOf(top)) ? 1 : 0;
}

RI_EXPORT int32_t ri_x11_own_app_in_front(void) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (Open() != 0) return -1;
  bool ok;
  Window active = ActiveWindow(&ok);
  if (!ok) return -1;
  if (active == None) return 0;
  return IsOwn(active) ? 1 : 0;
}
