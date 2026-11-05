// The Linux local-activity monitor (docs/design.md §6.3): a native thread
// that counts the presenter's own input, keyboards and pointing devices that
// go away, and the session's lock state. Dart polls its counters.
//
// - X11: XInput 2 raw events on the root window, from every slave device
//   except the XTEST ones, where the package's own XTest input comes from
//   (like Windows' injected flag). Pointer movement counts past 4 pixels of
//   travel, the path reset after 100 ms without movement.
// - Wayland: no client can see other input. GNOME's idle time
//   (org.gnome.Mutter.IdleMonitor) is the only system-wide sign, and libei
//   input resets it too, so input counts only when the idle time says there
//   was input more than kOwnPostToleranceMs after the package's last post.
// - Both: udev "remove" events for keyboards and pointing devices (RIN-41),
//   and logind's LockedHint and Active for the session (every 250 ms).
//
// Counts and timings only: nothing about what was typed or where.
#include <X11/Xlib.h>
#include <X11/extensions/XInput2.h>
#include <gio/gio.h>
#include <libudev.h>
#include <poll.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <thread>

#include "remote_input_native.h"
#include "remote_input_x11.h"

namespace {

constexpr int64_t kHeartbeatMs = 100;
constexpr int64_t kStallMs = 200;
constexpr int64_t kIdlePollMs = 15;
constexpr int64_t kOwnPostToleranceMs = 40;
constexpr int64_t kSessionPollMs = 250;
constexpr double kMoveThresholdPx = 4.0;
constexpr int64_t kMovePathResetMs = 100;

int64_t NowUs() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return static_cast<int64_t>(ts.tv_sec) * 1000000 + ts.tv_nsec / 1000;
}

std::mutex g_thread_mutex;
std::thread g_thread;
std::atomic<bool> g_stop{false};
std::atomic<bool> g_running{false};
// Set once the thread has opened its sources and read the session, so
// ri_activity_start answers with their health rather than a guess.
std::atomic<bool> g_ready{false};
constexpr int64_t kReadyTimeoutMs = 1000;
std::atomic<int64_t> g_count{0};
std::atomic<int64_t> g_reasons[RI_REASON_COUNT];
std::atomic<int64_t> g_heartbeat_us{0};
std::atomic<int64_t> g_longest_gap_ms{0};
std::atomic<int64_t> g_devices_lost{0};
std::atomic<bool> g_udev_ok{false};
std::atomic<bool> g_healthy{false};
std::atomic<int32_t> g_session_state{RI_SESSION_UNKNOWN};
std::atomic<int64_t> g_last_own_post_us{0};

void Count(int reason) {
  g_reasons[reason].fetch_add(1);
  if (reason != RI_REASON_STALL) g_count.fetch_add(1);
}

// --- logind -------------------------------------------------------------

char* SessionPath(GDBusConnection* system) {
  // The user's graphical session: apps started from the desktop often run in
  // the user manager's scopes, outside any session, so "auto" can't be used.
  GVariant* r = g_dbus_connection_call_sync(
      system, "org.freedesktop.login1", "/org/freedesktop/login1/user/self",
      "org.freedesktop.DBus.Properties", "Get",
      g_variant_new("(ss)", "org.freedesktop.login1.User", "Display"), G_VARIANT_TYPE("(v)"),
      G_DBUS_CALL_FLAGS_NONE, 500, nullptr, nullptr);
  char* path = nullptr;
  if (r != nullptr) {
    GVariant* v = nullptr;
    g_variant_get(r, "(v)", &v);
    const char* id = nullptr;
    const char* object = nullptr;
    g_variant_get(v, "(&s&o)", &id, &object);
    if (object != nullptr && strcmp(object, "/") != 0) path = g_strdup(object);
    g_variant_unref(v);
    g_variant_unref(r);
  }
  if (path == nullptr) path = g_strdup("/org/freedesktop/login1/session/auto");
  return path;
}

int ReadBool(GDBusConnection* system, const char* path, const char* name) {
  GVariant* r = g_dbus_connection_call_sync(
      system, "org.freedesktop.login1", path, "org.freedesktop.DBus.Properties", "Get",
      g_variant_new("(ss)", "org.freedesktop.login1.Session", name), G_VARIANT_TYPE("(v)"),
      G_DBUS_CALL_FLAGS_NONE, 500, nullptr, nullptr);
  if (r == nullptr) return -1;
  GVariant* v = nullptr;
  g_variant_get(r, "(v)", &v);
  int value = g_variant_is_of_type(v, G_VARIANT_TYPE_BOOLEAN) ? g_variant_get_boolean(v) : -1;
  g_variant_unref(v);
  g_variant_unref(r);
  return value;
}

int32_t ReadSessionState(GDBusConnection* system, const char* path) {
  if (system == nullptr || path == nullptr) return RI_SESSION_UNKNOWN;
  const int locked = ReadBool(system, path, "LockedHint");
  const int active = ReadBool(system, path, "Active");
  if (locked < 0 && active < 0) return RI_SESSION_UNKNOWN;
  if (locked == 1) return RI_SESSION_LOCKED;
  if (active == 0) return RI_SESSION_INACTIVE;
  return RI_SESSION_ACTIVE;
}

// --- udev -----------------------------------------------------------------

bool IsInputDevice(struct udev_device* d) {
  const char* name = udev_device_get_sysname(d);
  if (name == nullptr || strncmp(name, "event", 5) != 0) return false;
  static const char* kProps[] = {"ID_INPUT_KEYBOARD",  "ID_INPUT_MOUSE",
                                 "ID_INPUT_TOUCHPAD",  "ID_INPUT_POINTINGSTICK",
                                 "ID_INPUT_TRACKBALL", "ID_INPUT_TABLET"};
  for (const char* p : kProps) {
    const char* v = udev_device_get_property_value(d, p);
    if (v != nullptr && strcmp(v, "1") == 0) return true;
  }
  return false;
}

// --- X11 ----------------------------------------------------------------

struct Valuator {
  bool absolute = false;
  double min = 0, max = 0;
  double last = NAN;
};

struct X11Watch {
  Display* dpy = nullptr;
  int opcode = 0;
  bool xtest[256] = {};
  Valuator axes[256][2];
  double path = 0;
  int64_t last_move_us = 0;
  int width = 1, height = 1;
};

void ReadDevices(X11Watch* w) {
  memset(w->xtest, 0, sizeof(w->xtest));
  int n = 0;
  XIDeviceInfo* info = XIQueryDevice(w->dpy, XIAllDevices, &n);
  if (info == nullptr) return;
  for (int i = 0; i < n; i++) {
    const int id = info[i].deviceid;
    if (id < 0 || id > 255) continue;
    w->xtest[id] = info[i].name != nullptr && strstr(info[i].name, "XTEST") != nullptr;
    for (int a = 0; a < 2; a++) w->axes[id][a] = Valuator();
    for (int c = 0; c < info[i].num_classes; c++) {
      if (info[i].classes[c]->type != XIValuatorClass) continue;
      auto* v = reinterpret_cast<XIValuatorClassInfo*>(info[i].classes[c]);
      if (v->number < 0 || v->number > 1) continue;
      Valuator& axis = w->axes[id][v->number];
      axis.absolute = v->mode == XIModeAbsolute;
      axis.min = v->min;
      axis.max = v->max;
    }
  }
  XIFreeDeviceInfo(info);
  w->width = DisplayWidth(w->dpy, DefaultScreen(w->dpy));
  w->height = DisplayHeight(w->dpy, DefaultScreen(w->dpy));
}

bool OpenX11(X11Watch* w) {
  ri_x11_install_error_handler();
  w->dpy = XOpenDisplay(nullptr);
  if (w->dpy == nullptr) return false;
  ri_x11_set_monitor_display(w->dpy);
  int ev, err;
  int major = 2, minor = 2;
  if (!XQueryExtension(w->dpy, "XInputExtension", &w->opcode, &ev, &err) ||
      XIQueryVersion(w->dpy, &major, &minor) != Success) {
    return false;
  }
  unsigned char raw[XIMaskLen(XI_LASTEVENT)] = {};
  XISetMask(raw, XI_RawKeyPress);
  XISetMask(raw, XI_RawButtonPress);
  XISetMask(raw, XI_RawMotion);
  unsigned char hierarchy[XIMaskLen(XI_LASTEVENT)] = {};
  XISetMask(hierarchy, XI_HierarchyChanged);
  XIEventMask masks[2];
  masks[0].deviceid = XIAllMasterDevices;
  masks[0].mask_len = sizeof(raw);
  masks[0].mask = raw;
  masks[1].deviceid = XIAllDevices;
  masks[1].mask_len = sizeof(hierarchy);
  masks[1].mask = hierarchy;
  XISelectEvents(w->dpy, DefaultRootWindow(w->dpy), masks, 2);
  XSync(w->dpy, False);
  ReadDevices(w);
  return true;
}

void CloseX11(X11Watch* w) {
  if (w->dpy == nullptr) return;
  ri_x11_set_monitor_display(nullptr);
  XCloseDisplay(w->dpy);
  w->dpy = nullptr;
}

void OnMotion(X11Watch* w, XIRawEvent* e) {
  const int id = e->sourceid;
  if (id < 0 || id > 255 || w->xtest[id]) return;
  double delta[2] = {0, 0};
  const double* values = e->valuators.values;
  int k = 0;
  for (int axis = 0; axis < e->valuators.mask_len * 8 && axis < 2; axis++) {
    if (!XIMaskIsSet(e->valuators.mask, axis)) continue;
    const double v = values[k++];
    Valuator& a = w->axes[id][axis];
    if (a.absolute) {
      const double range = a.max - a.min;
      const double px = range > 0 ? (v - a.min) / range * (axis == 0 ? w->width : w->height) : v;
      if (!std::isnan(a.last)) delta[axis] = px - a.last;
      a.last = px;
    } else {
      delta[axis] = v;
    }
  }
  const int64_t now = NowUs();
  if (now - w->last_move_us > kMovePathResetMs * 1000) w->path = 0;
  w->last_move_us = now;
  w->path += std::hypot(delta[0], delta[1]);
  if (w->path > kMoveThresholdPx) {
    w->path = 0;
    Count(RI_REASON_MOVE);
  }
}

void DrainX11(X11Watch* w) {
  while (XPending(w->dpy) > 0) {
    XEvent ev;
    XNextEvent(w->dpy, &ev);
    XGenericEventCookie* cookie = &ev.xcookie;
    if (cookie->type != GenericEvent || cookie->extension != w->opcode ||
        !XGetEventData(w->dpy, cookie)) {
      continue;
    }
    switch (cookie->evtype) {
      case XI_RawKeyPress: {
        auto* e = static_cast<XIRawEvent*>(cookie->data);
        if (e->sourceid >= 0 && e->sourceid <= 255 && !w->xtest[e->sourceid]) {
          Count(RI_REASON_KEY);
        }
        break;
      }
      case XI_RawButtonPress: {
        auto* e = static_cast<XIRawEvent*>(cookie->data);
        if (e->sourceid >= 0 && e->sourceid <= 255 && !w->xtest[e->sourceid]) {
          Count(RI_REASON_BUTTON);
        }
        break;
      }
      case XI_RawMotion:
        OnMotion(w, static_cast<XIRawEvent*>(cookie->data));
        break;
      case XI_HierarchyChanged: {
        auto* e = static_cast<XIHierarchyEvent*>(cookie->data);
        for (int i = 0; i < e->num_info; i++) {
          const XIHierarchyInfo& h = e->info[i];
          const bool gone = (h.flags & (XISlaveRemoved | XIDeviceDisabled)) != 0;
          const bool slave = h.use == XISlavePointer || h.use == XISlaveKeyboard ||
                             h.use == XIFloatingSlave;
          if (gone && slave && h.deviceid >= 0 && h.deviceid <= 255 && !w->xtest[h.deviceid]) {
            g_devices_lost.fetch_add(1);
          }
        }
        ReadDevices(w);
        break;
      }
      default:
        break;
    }
    XFreeEventData(w->dpy, cookie);
  }
}

// --- Wayland (GNOME's idle time) -------------------------------------------

struct IdleWatch {
  GDBusConnection* bus = nullptr;
  int64_t last_input_us = 0;
  bool primed = false;
};

bool PollIdle(IdleWatch* w) {
  if (w->bus == nullptr) return false;
  GVariant* r = g_dbus_connection_call_sync(
      w->bus, "org.gnome.Mutter.IdleMonitor", "/org/gnome/Mutter/IdleMonitor/Core",
      "org.gnome.Mutter.IdleMonitor", "GetIdletime", nullptr, G_VARIANT_TYPE("(t)"),
      G_DBUS_CALL_FLAGS_NONE, 200, nullptr, nullptr);
  const int64_t now = NowUs();
  if (r == nullptr) return false;
  guint64 idle_ms = 0;
  g_variant_get(r, "(t)", &idle_ms);
  g_variant_unref(r);
  const int64_t input_us = now - static_cast<int64_t>(idle_ms) * 1000;
  if (!w->primed) {
    w->primed = true;
    w->last_input_us = input_us;
    return true;
  }
  // The estimate jitters by a millisecond or two between polls (the idle
  // time is in whole ms, and the call takes time).
  if (input_us > w->last_input_us + 3000) {
    if (input_us > g_last_own_post_us.load() + kOwnPostToleranceMs * 1000) {
      Count(RI_REASON_IDLE);
    }
    w->last_input_us = input_us;
  }
  return true;
}

// --- The thread -------------------------------------------------------------

void Run() {
  const int backend = ri_backend();
  struct udev* udev = udev_new();
  struct udev_monitor* mon = nullptr;
  if (udev != nullptr) {
    mon = udev_monitor_new_from_netlink(udev, "udev");
    if (mon != nullptr) {
      udev_monitor_filter_add_match_subsystem_devtype(mon, "input", nullptr);
      if (udev_monitor_enable_receiving(mon) < 0) {
        udev_monitor_unref(mon);
        mon = nullptr;
      }
    }
  }
  g_udev_ok.store(mon != nullptr);

  X11Watch x11;
  IdleWatch idle;
  bool source_ok = false;
  if (backend == RI_BACKEND_X11) {
    source_ok = OpenX11(&x11);
  } else if (backend == RI_BACKEND_WAYLAND) {
    idle.bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
    source_ok = PollIdle(&idle);
  }
  g_healthy.store(source_ok);

  GDBusConnection* system = g_bus_get_sync(G_BUS_TYPE_SYSTEM, nullptr, nullptr);
  char* session_path = system != nullptr ? SessionPath(system) : nullptr;
  g_session_state.store(ReadSessionState(system, session_path));
  g_ready.store(true);

  int64_t last_beat = NowUs();
  int64_t last_session = last_beat;
  int64_t last_idle = last_beat;
  g_heartbeat_us.store(last_beat);
  while (!g_stop.load()) {
    struct pollfd fds[2];
    int nfds = 0;
    int x11_index = -1, udev_index = -1;
    if (x11.dpy != nullptr) {
      fds[nfds] = {ConnectionNumber(x11.dpy), POLLIN, 0};
      x11_index = nfds++;
    }
    if (mon != nullptr) {
      fds[nfds] = {udev_monitor_get_fd(mon), POLLIN, 0};
      udev_index = nfds++;
    }
    const int timeout = backend == RI_BACKEND_WAYLAND ? kIdlePollMs : kHeartbeatMs;
    // Xlib may hold events read off the socket already.
    if (x11.dpy != nullptr && XPending(x11.dpy) > 0) {
      DrainX11(&x11);
    }
    int ready = poll(fds, nfds, timeout);
    const int64_t now = NowUs();
    const int64_t gap_ms = (now - last_beat) / 1000;
    if (gap_ms > g_longest_gap_ms.load()) g_longest_gap_ms.store(gap_ms);
    if (gap_ms > kStallMs) Count(RI_REASON_STALL);
    last_beat = now;
    g_heartbeat_us.store(now);
    if (ready > 0 && x11_index >= 0 && (fds[x11_index].revents & POLLIN)) DrainX11(&x11);
    if (ready > 0 && x11_index >= 0 && (fds[x11_index].revents & (POLLHUP | POLLERR))) {
      g_healthy.store(false);
      CloseX11(&x11);
    }
    if (ready > 0 && udev_index >= 0 && (fds[udev_index].revents & POLLIN)) {
      struct udev_device* d;
      while ((d = udev_monitor_receive_device(mon)) != nullptr) {
        const char* action = udev_device_get_action(d);
        if (action != nullptr && strcmp(action, "remove") == 0 && IsInputDevice(d)) {
          g_devices_lost.fetch_add(1);
        }
        udev_device_unref(d);
      }
    }
    if (backend == RI_BACKEND_WAYLAND && now - last_idle >= kIdlePollMs * 1000) {
      last_idle = now;
      g_healthy.store(PollIdle(&idle));
    }
    if (now - last_session >= kSessionPollMs * 1000) {
      last_session = now;
      g_session_state.store(ReadSessionState(system, session_path));
    }
  }
  CloseX11(&x11);
  if (idle.bus != nullptr) g_object_unref(idle.bus);
  if (system != nullptr) g_object_unref(system);
  g_free(session_path);
  if (mon != nullptr) udev_monitor_unref(mon);
  if (udev != nullptr) udev_unref(udev);
  g_healthy.store(false);
  g_running.store(false);
}

}  // namespace

RI_EXPORT int32_t ri_backend(void) {
  const char* force = getenv("REMOTE_INPUT_LINUX_BACKEND");
  if (force != nullptr && strcmp(force, "x11") == 0) return RI_BACKEND_X11;
  const char* type = getenv("XDG_SESSION_TYPE");
  const char* wayland = getenv("WAYLAND_DISPLAY");
  if ((type != nullptr && strcmp(type, "wayland") == 0) ||
      (wayland != nullptr && wayland[0] != '\0')) {
    return RI_BACKEND_WAYLAND;
  }
  const char* display = getenv("DISPLAY");
  if (display != nullptr && display[0] != '\0') return RI_BACKEND_X11;
  return RI_BACKEND_NONE;
}

RI_EXPORT int32_t ri_euid(void) { return static_cast<int32_t>(geteuid()); }

RI_EXPORT int32_t ri_pid(void) { return static_cast<int32_t>(getpid()); }

RI_EXPORT int64_t ri_now_ms(void) { return NowUs() / 1000; }

RI_EXPORT int32_t ri_session_state(void) {
  if (g_running.load()) return g_session_state.load();
  // Not monitoring: read it now (a few hundred microseconds), at most every
  // 100 ms.
  static std::mutex mutex;
  static int64_t read_at = 0;
  static int32_t state = RI_SESSION_UNKNOWN;
  std::lock_guard<std::mutex> lock(mutex);
  const int64_t now = NowUs();
  if (read_at != 0 && now - read_at < 100000) return state;
  read_at = now;
  GDBusConnection* system = g_bus_get_sync(G_BUS_TYPE_SYSTEM, nullptr, nullptr);
  if (system == nullptr) return state = RI_SESSION_UNKNOWN;
  char* path = SessionPath(system);
  state = ReadSessionState(system, path);
  g_free(path);
  g_object_unref(system);
  return state;
}

RI_EXPORT int32_t ri_activity_start(void) {
  std::lock_guard<std::mutex> lock(g_thread_mutex);
  if (!g_running.load()) {
    if (g_thread.joinable()) g_thread.join();
    g_stop.store(false);
    g_ready.store(false);
    g_running.store(true);
    g_heartbeat_us.store(NowUs());
    g_thread = std::thread(Run);
    const int64_t until = NowUs() + kReadyTimeoutMs * 1000;
    while (!g_ready.load() && g_running.load() && NowUs() < until) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
  }
  return g_healthy.load() ? 1 : 0;
}

RI_EXPORT void ri_activity_stop(void) {
  std::lock_guard<std::mutex> lock(g_thread_mutex);
  g_stop.store(true);
  if (g_thread.joinable()) g_thread.join();
}

RI_EXPORT int64_t ri_activity_count(void) { return g_count.load(); }

RI_EXPORT int32_t ri_activity_healthy(void) { return g_running.load() && g_healthy.load() ? 1 : 0; }

RI_EXPORT int64_t ri_activity_heartbeat_age_ms(void) {
  if (!g_running.load()) return -1;
  return (NowUs() - g_heartbeat_us.load()) / 1000;
}

RI_EXPORT int64_t ri_activity_reason(int32_t reason) {
  if (reason < 0 || reason >= RI_REASON_COUNT) return 0;
  return g_reasons[reason].load();
}

RI_EXPORT int64_t ri_activity_longest_gap_ms(void) { return g_longest_gap_ms.load(); }

RI_EXPORT int64_t ri_activity_devices_lost(void) {
  if (g_running.load() && !g_udev_ok.load()) return -1;
  return g_devices_lost.load();
}

void ri_note_own_post(void) { g_last_own_post_us.store(NowUs()); }
