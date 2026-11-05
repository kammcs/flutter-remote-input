// Wayland injection for the Linux host (docs/design.md §7.5): the
// RemoteDesktop portal (org.freedesktop.portal.RemoteDesktop, v2) and libei
// through ConnectToEIS.
//
// - The portal session is made by RemoteDesktop.CreateSession, with
//   SelectDevices (keyboard and pointer, never persisted: the system asks for
//   every session) and, when asked, ScreenCast.SelectSources on the same
//   session, so one dialog covers the share and the control. Start shows it.
//   The screen cast's PipeWire fd (OpenPipeWireRemote) goes to the app, which
//   hands it to its capturer; this package keeps the session.
// - Everything runs on the main thread's GLib context: the portal's D-Bus
//   calls and signals on the process's shared session bus (the capturer's
//   handles belong to the same sender), and libei's fd. The injection calls
//   come from Dart, and take the same lock.
// - The session ends when the portal closes it (the user's Stop in the
//   system's indicator, say), EIS disconnects, or the app closes it. Each is
//   reported to Dart, which stops a live control session.
#include "remote_input_native.h"
#include "remote_input_portal.h"

#ifdef REMOTE_INPUT_HAS_EI

#include <gio/gio.h>
#include <gio/gunixfdlist.h>
#include <glib-unix.h>
#include <libei.h>
#include <linux/input-event-codes.h>
#include <sys/mman.h>
#include <unistd.h>
#include <xkbcommon/xkbcommon.h>

#include <atomic>
#include <cmath>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace {

constexpr int kStartTimeoutMs = 4000;

struct Device {
  struct ei_device* device = nullptr;
  bool resumed = false;
};

struct Region {
  int32_t id = 0;
  int32_t x = 0, y = 0, width = 0, height = 0;
  double scale = 1.0;
  std::string mapping;
  struct ei_device* device = nullptr;
};

std::recursive_mutex g_lock;
std::atomic<int32_t> g_generation{0};

struct ei* g_ei = nullptr;
guint g_ei_watch = 0;
std::vector<Device> g_devices;
std::vector<Region> g_regions;
std::map<std::string, int32_t> g_region_ids;
int32_t g_next_region_id = 1;
uint32_t g_sequence = 1;
bool g_connected = false;
struct ei_device* g_pointer = nullptr;  // The device of the last move.

struct xkb_context* g_xkb = nullptr;
struct xkb_keymap* g_keymap = nullptr;
uint32_t g_mods_depressed = 0, g_mods_latched = 0, g_mods_locked = 0, g_group = 0;

GDBusConnection* g_bus = nullptr;
char* g_session = nullptr;
guint g_closed_sub = 0;
int g_pipewire_fd = -1;
bool g_busy = false;
int g_token = 0;

RiPortalOptions g_options;
RiPortalDone g_done = nullptr;
gpointer g_done_data = nullptr;
FlValue* g_streams = nullptr;
guint g_start_timeout = 0;

RiPortalClosed g_closed = nullptr;
gpointer g_closed_data = nullptr;

void Teardown(const char* reason, bool close_session);

bool Has(struct ei_device* d, enum ei_device_capability c) {
  return d != nullptr && ei_device_has_capability(d, c);
}

Device* Find(struct ei_device* d) {
  for (Device& x : g_devices) {
    if (x.device == d) return &x;
  }
  return nullptr;
}

bool Resumed(struct ei_device* d) {
  Device* x = Find(d);
  return x != nullptr && x->resumed;
}

struct ei_device* FirstWith(enum ei_device_capability c) {
  struct ei_device* any = nullptr;
  for (Device& x : g_devices) {
    if (!Has(x.device, c)) continue;
    if (x.resumed) return x.device;
    if (any == nullptr) any = x.device;
  }
  return any;
}

void RebuildRegions() {
  g_regions.clear();
  for (Device& x : g_devices) {
    if (!Has(x.device, EI_DEVICE_CAP_POINTER_ABSOLUTE)) continue;
    for (size_t i = 0;; i++) {
      struct ei_region* r = ei_device_get_region(x.device, i);
      if (r == nullptr) break;
      Region region;
      region.x = static_cast<int32_t>(ei_region_get_x(r));
      region.y = static_cast<int32_t>(ei_region_get_y(r));
      region.width = static_cast<int32_t>(ei_region_get_width(r));
      region.height = static_cast<int32_t>(ei_region_get_height(r));
      region.scale = ei_region_get_physical_scale(r);
      const char* mapping = ei_region_get_mapping_id(r);
      region.mapping = mapping != nullptr ? mapping : "";
      region.device = x.device;
      std::string key = !region.mapping.empty()
                            ? region.mapping
                            : "desktop:" + std::to_string(region.x) + "," +
                                  std::to_string(region.y) + "," + std::to_string(region.width) +
                                  "x" + std::to_string(region.height);
      auto it = g_region_ids.find(key);
      if (it == g_region_ids.end()) it = g_region_ids.emplace(key, g_next_region_id++).first;
      region.id = it->second;
      // The same region on two devices (GNOME can add a pointer twice): keep
      // the resumed one.
      bool replaced = false;
      for (Region& other : g_regions) {
        if (other.id != region.id) continue;
        if (!Resumed(other.device) && x.resumed) other = region;
        replaced = true;
      }
      if (!replaced) g_regions.push_back(region);
    }
  }
  g_generation.fetch_add(1);
}

void LoadKeymap(struct ei_device* d) {
  struct ei_keymap* km = ei_device_keyboard_get_keymap(d);
  if (km == nullptr || ei_keymap_get_type(km) != EI_KEYMAP_TYPE_XKB) return;
  const size_t size = ei_keymap_get_size(km);
  const int fd = ei_keymap_get_fd(km);
  void* map = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
  if (map == MAP_FAILED) return;
  if (g_xkb == nullptr) g_xkb = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  struct xkb_keymap* keymap =
      g_xkb == nullptr ? nullptr
                       : xkb_keymap_new_from_buffer(g_xkb, static_cast<const char*>(map),
                                                    strnlen(static_cast<const char*>(map), size),
                                                    XKB_KEYMAP_FORMAT_TEXT_V1,
                                                    XKB_KEYMAP_COMPILE_NO_FLAGS);
  munmap(map, size);
  if (keymap == nullptr) return;
  if (g_keymap != nullptr) xkb_keymap_unref(g_keymap);
  g_keymap = keymap;
}

bool Ready() {
  return Resumed(FirstWith(EI_DEVICE_CAP_POINTER_ABSOLUTE)) &&
         Resumed(FirstWith(EI_DEVICE_CAP_KEYBOARD));
}

void FinishStart(const char* status, const char* message);

gboolean OnEi(gint, GIOCondition, gpointer) {
  std::lock_guard<std::recursive_mutex> lock(g_lock);
  if (g_ei == nullptr) return G_SOURCE_REMOVE;
  ei_dispatch(g_ei);
  struct ei_event* e;
  bool disconnected = false;
  while ((e = ei_get_event(g_ei)) != nullptr) {
    struct ei_device* d = ei_event_get_device(e);
    switch (ei_event_get_type(e)) {
      case EI_EVENT_SEAT_ADDED:
        ei_seat_bind_capabilities(ei_event_get_seat(e), EI_DEVICE_CAP_POINTER_ABSOLUTE,
                                  EI_DEVICE_CAP_KEYBOARD, EI_DEVICE_CAP_BUTTON,
                                  EI_DEVICE_CAP_SCROLL, nullptr);
        break;
      case EI_EVENT_DEVICE_ADDED:
        g_devices.push_back({ei_device_ref(d), false});
        if (Has(d, EI_DEVICE_CAP_KEYBOARD)) LoadKeymap(d);
        RebuildRegions();
        break;
      case EI_EVENT_DEVICE_RESUMED:
        if (Device* x = Find(d)) {
          x->resumed = true;
          ei_device_start_emulating(d, g_sequence++);
        }
        RebuildRegions();
        if (g_done != nullptr && Ready()) FinishStart("ok", nullptr);
        break;
      case EI_EVENT_DEVICE_PAUSED:
        if (Device* x = Find(d)) x->resumed = false;
        RebuildRegions();
        break;
      case EI_EVENT_DEVICE_REMOVED:
        for (size_t i = 0; i < g_devices.size(); i++) {
          if (g_devices[i].device != d) continue;
          if (g_pointer == d) g_pointer = nullptr;
          ei_device_unref(d);
          g_devices.erase(g_devices.begin() + static_cast<long>(i));
          break;
        }
        RebuildRegions();
        break;
      case EI_EVENT_KEYBOARD_MODIFIERS:
        g_mods_depressed = ei_event_keyboard_get_xkb_mods_depressed(e);
        g_mods_latched = ei_event_keyboard_get_xkb_mods_latched(e);
        g_mods_locked = ei_event_keyboard_get_xkb_mods_locked(e);
        g_group = ei_event_keyboard_get_xkb_group(e);
        break;
      case EI_EVENT_DISCONNECT:
        disconnected = true;
        break;
      default:
        break;
    }
    ei_event_unref(e);
  }
  if (disconnected) {
    g_ei_watch = 0;
    Teardown("disconnected", true);
    return G_SOURCE_REMOVE;
  }
  return G_SOURCE_CONTINUE;
}

int32_t Frame(struct ei_device* d) {
  ei_device_frame(d, ei_now(g_ei));
  ri_note_own_post();
  return RI_OK;
}

int32_t Check(struct ei_device* d) {
  if (!g_connected || g_ei == nullptr) return RI_PERMISSION_DENIED;
  if (d == nullptr) return RI_FAILED;
  if (!Resumed(d)) return RI_PAUSED;
  ri_note_own_post();
  return RI_OK;
}

// --- Text -------------------------------------------------------------------

xkb_keycode_t KeycodeFor(xkb_keysym_t sym) {
  if (g_keymap == nullptr) return XKB_KEYCODE_INVALID;
  struct xkb_state* state = xkb_state_new(g_keymap);
  if (state == nullptr) return XKB_KEYCODE_INVALID;
  xkb_keycode_t found = XKB_KEYCODE_INVALID;
  for (xkb_keycode_t kc = xkb_keymap_min_keycode(g_keymap);
       kc <= xkb_keymap_max_keycode(g_keymap) && found == XKB_KEYCODE_INVALID; kc++) {
    if (xkb_state_key_get_one_sym(state, kc) == sym) found = kc;
  }
  xkb_state_unref(state);
  return found;
}

int32_t Key(struct ei_device* kbd, uint32_t code, bool down) {
  ei_device_keyboard_key(kbd, code, down);
  return Frame(kbd);
}

}  // namespace

RI_EXPORT int32_t ri_has_wayland(void) { return 1; }

RI_EXPORT int32_t ri_wl_connected(void) {
  std::lock_guard<std::recursive_mutex> lock(g_lock);
  return g_connected && Ready() ? 1 : 0;
}

RI_EXPORT int32_t ri_wl_generation(void) { return g_generation.load(); }

RI_EXPORT int32_t ri_wl_paused(void) {
  std::lock_guard<std::recursive_mutex> lock(g_lock);
  return g_connected && !Ready() ? 1 : 0;
}

RI_EXPORT int32_t ri_wl_regions(int32_t max, int32_t* ids, int32_t* rects, int32_t* scales,
                                char* mapping) {
  std::lock_guard<std::recursive_mutex> lock(g_lock);
  int32_t n = 0;
  for (const Region& r : g_regions) {
    if (n >= max) break;
    ids[n] = r.id;
    rects[n * 4] = r.x;
    rects[n * 4 + 1] = r.y;
    rects[n * 4 + 2] = r.width;
    rects[n * 4 + 3] = r.height;
    scales[n] = static_cast<int32_t>(std::lround(r.scale * 1000));
    snprintf(mapping + n * 64, 64, "%s", r.mapping.c_str());
    n++;
  }
  return n;
}

RI_EXPORT int32_t ri_wl_move(int32_t region, double x, double y) {
  std::lock_guard<std::recursive_mutex> lock(g_lock);
  const Region* target = nullptr;
  for (const Region& r : g_regions) {
    if (region != 0 ? r.id == region
                    : (r.mapping.empty() && x >= r.x && y >= r.y && x < r.x + r.width &&
                       y < r.y + r.height)) {
      target = &r;
      break;
    }
  }
  struct ei_device* d = target != nullptr ? target->device : nullptr;
  const int32_t status = Check(d);
  if (status != RI_OK) return status;
  // Inside the region: EIS drops points outside every region.
  const double cx = std::fmin(std::fmax(x, target->x), target->x + target->width - 0.01);
  const double cy = std::fmin(std::fmax(y, target->y), target->y + target->height - 0.01);
  ei_device_pointer_motion_absolute(d, cx, cy);
  g_pointer = d;
  return Frame(d);
}

RI_EXPORT int32_t ri_wl_button(int32_t button, int32_t down) {
  std::lock_guard<std::recursive_mutex> lock(g_lock);
  struct ei_device* d =
      Has(g_pointer, EI_DEVICE_CAP_BUTTON) ? g_pointer : FirstWith(EI_DEVICE_CAP_BUTTON);
  const int32_t status = Check(d);
  if (status != RI_OK) return status;
  ei_device_button_button(d, static_cast<uint32_t>(button), down != 0);
  return Frame(d);
}

RI_EXPORT int32_t ri_wl_scroll(double dx, double dy, int32_t discrete) {
  std::lock_guard<std::recursive_mutex> lock(g_lock);
  struct ei_device* d =
      Has(g_pointer, EI_DEVICE_CAP_SCROLL) ? g_pointer : FirstWith(EI_DEVICE_CAP_SCROLL);
  const int32_t status = Check(d);
  if (status != RI_OK) return status;
  if (discrete) {
    ei_device_scroll_discrete(d, static_cast<int32_t>(dx), static_cast<int32_t>(dy));
  } else {
    ei_device_scroll_delta(d, dx, dy);
  }
  return Frame(d);
}

RI_EXPORT int32_t ri_wl_key(int32_t code, int32_t down) {
  std::lock_guard<std::recursive_mutex> lock(g_lock);
  struct ei_device* d = FirstWith(EI_DEVICE_CAP_KEYBOARD);
  const int32_t status = Check(d);
  if (status != RI_OK) return status;
  return Key(d, static_cast<uint32_t>(code), down != 0);
}

RI_EXPORT int32_t ri_wl_text(uint32_t codepoint) {
  std::lock_guard<std::recursive_mutex> lock(g_lock);
  struct ei_device* kbd = FirstWith(EI_DEVICE_CAP_KEYBOARD);
  const int32_t status = Check(kbd);
  if (status != RI_OK) return status;
  if (g_keymap == nullptr) return RI_UNMAPPED;
  const xkb_keysym_t sym = xkb_utf32_to_keysym(codepoint);
  if (sym == XKB_KEY_NoSymbol) return RI_UNMAPPED;
  const xkb_mod_index_t shift_index = xkb_keymap_mod_get_index(g_keymap, XKB_MOD_NAME_SHIFT);
  const xkb_mod_index_t l3_index = xkb_keymap_mod_get_index(g_keymap, "Mod5");
  const xkb_mod_mask_t shift = shift_index == XKB_MOD_INVALID ? 0 : 1u << shift_index;
  const xkb_mod_mask_t l3 = l3_index == XKB_MOD_INVALID ? 0 : 1u << l3_index;
  const xkb_mod_mask_t extras[] = {0, shift, l3, shift | l3};
  // Modifier keys the layout has.
  const xkb_keycode_t shift_key = KeycodeFor(XKB_KEY_Shift_L);
  const xkb_keycode_t l3_key = KeycodeFor(XKB_KEY_ISO_Level3_Shift);
  for (xkb_mod_mask_t extra : extras) {
    if ((extra & shift) && shift_key == XKB_KEYCODE_INVALID) continue;
    if ((extra & l3) && (l3 == 0 || l3_key == XKB_KEYCODE_INVALID)) continue;
    struct xkb_state* state = xkb_state_new(g_keymap);
    if (state == nullptr) return RI_FAILED;
    xkb_state_update_mask(state, g_mods_depressed | extra, g_mods_latched, g_mods_locked, 0, 0,
                          g_group);
    xkb_keycode_t found = XKB_KEYCODE_INVALID;
    for (xkb_keycode_t kc = xkb_keymap_min_keycode(g_keymap);
         kc <= xkb_keymap_max_keycode(g_keymap) && found == XKB_KEYCODE_INVALID; kc++) {
      if (kc == shift_key || kc == l3_key) continue;
      if (xkb_state_key_get_one_sym(state, kc) == sym) found = kc;
    }
    xkb_state_unref(state);
    if (found == XKB_KEYCODE_INVALID) continue;
    // evdev codes are xkb keycodes minus 8.
    const bool press_shift = (extra & shift) && !(g_mods_depressed & shift);
    const bool press_l3 = (extra & l3) && !(g_mods_depressed & l3);
    if (press_shift) Key(kbd, shift_key - 8, true);
    if (press_l3) Key(kbd, l3_key - 8, true);
    Key(kbd, found - 8, true);
    Key(kbd, found - 8, false);
    if (press_l3) Key(kbd, l3_key - 8, false);
    if (press_shift) Key(kbd, shift_key - 8, false);
    return RI_OK;
  }
  return RI_UNMAPPED;
}

// --- The portal ---------------------------------------------------------------

namespace {

char* NewToken() { return g_strdup_printf("remote_input_%d_%d", getpid(), ++g_token); }

char* RequestPath(const char* token) {
  char* sender = g_strdup(g_dbus_connection_get_unique_name(g_bus) + 1);
  for (char* p = sender; *p; p++) {
    if (*p == '.') *p = '_';
  }
  char* path = g_strdup_printf("/org/freedesktop/portal/desktop/request/%s/%s", sender, token);
  g_free(sender);
  return path;
}

typedef void (*Step)(guint32 code, GVariant* results);

struct PendingRequest {
  Step step;
  guint subscription;
};

void OnResponse(GDBusConnection*, const char*, const char*, const char*, const char*,
                GVariant* params, gpointer data) {
  auto* pending = static_cast<PendingRequest*>(data);
  g_dbus_connection_signal_unsubscribe(g_bus, pending->subscription);
  Step step = pending->step;
  delete pending;
  guint32 code = 2;
  GVariant* results = nullptr;
  g_variant_get(params, "(u@a{sv})", &code, &results);
  step(code, results);
  if (results != nullptr) g_variant_unref(results);
}

void OnCallDone(GObject* source, GAsyncResult* res, gpointer data) {
  std::lock_guard<std::recursive_mutex> lock(g_lock);
  GError* error = nullptr;
  GVariant* r = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), res, &error);
  if (r != nullptr) {
    g_variant_unref(r);
    return;
  }
  auto* pending = static_cast<PendingRequest*>(data);
  g_dbus_connection_signal_unsubscribe(g_bus, pending->subscription);
  delete pending;
  std::string message = error->message;
  g_error_free(error);
  if (g_done != nullptr) FinishStart("error", message.c_str());
}

// Calls portal method [method] whose last argument is the options in
// [options] (handle_token is added), and runs [step] with its Response.
void Request(const char* iface, const char* method, GVariant* leading, GVariantBuilder* options,
             Step step) {
  char* token = NewToken();
  char* path = RequestPath(token);
  g_variant_builder_add(options, "{sv}", "handle_token", g_variant_new_string(token));
  auto* pending = new PendingRequest{step, 0};
  pending->subscription = g_dbus_connection_signal_subscribe(
      g_bus, "org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request", "Response", path,
      nullptr, G_DBUS_SIGNAL_FLAGS_NO_MATCH_RULE, OnResponse, pending, nullptr);
  GVariant* params;
  if (leading != nullptr) g_variant_ref_sink(leading);
  if (leading == nullptr) {
    params = g_variant_new("(a{sv})", options);
  } else if (g_variant_is_of_type(leading, G_VARIANT_TYPE("(os)"))) {
    const char* session;
    const char* parent;
    g_variant_get(leading, "(&o&s)", &session, &parent);
    params = g_variant_new("(osa{sv})", session, parent, options);
    g_variant_unref(leading);
  } else {
    const char* session;
    g_variant_get(leading, "(&o)", &session);
    params = g_variant_new("(oa{sv})", session, options);
    g_variant_unref(leading);
  }
  g_dbus_connection_call(g_bus, "org.freedesktop.portal.Desktop",
                         "/org/freedesktop/portal/desktop", iface, method, params,
                         G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr, OnCallDone,
                         pending);
  g_free(token);
  g_free(path);
}

int CallForFd(const char* iface, const char* method, GError** error) {
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  GUnixFDList* out = nullptr;
  GVariant* r = g_dbus_connection_call_with_unix_fd_list_sync(
      g_bus, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", iface, method,
      g_variant_new("(oa{sv})", g_session, &options), G_VARIANT_TYPE("(h)"),
      G_DBUS_CALL_FLAGS_NONE, 5000, nullptr, &out, nullptr, error);
  if (r == nullptr) return -1;
  gint32 index = -1;
  g_variant_get(r, "(h)", &index);
  g_variant_unref(r);
  int fd = out != nullptr ? g_unix_fd_list_get(out, index, error) : -1;
  if (out != nullptr) g_object_unref(out);
  return fd;
}

void AddRegionIds(FlValue* streams) {
  if (streams == nullptr) return;
  for (size_t i = 0; i < fl_value_get_length(streams); i++) {
    FlValue* s = fl_value_get_list_value(streams, i);
    FlValue* mapping = fl_value_lookup_string(s, "mappingId");
    int32_t id = 0;
    if (mapping != nullptr && fl_value_get_type(mapping) == FL_VALUE_TYPE_STRING) {
      auto it = g_region_ids.find(fl_value_get_string(mapping));
      if (it != g_region_ids.end()) id = it->second;
    }
    fl_value_set_string_take(s, "displayId", fl_value_new_int(id));
    double scale = 1.0;
    for (const Region& r : g_regions) {
      if (r.id == id) scale = r.scale;
    }
    fl_value_set_string_take(s, "scale", fl_value_new_float(scale));
  }
}

void FinishStart(const char* status, const char* message) {
  if (g_start_timeout != 0) {
    g_source_remove(g_start_timeout);
    g_start_timeout = 0;
  }
  RiPortalDone done = g_done;
  gpointer data = g_done_data;
  g_done = nullptr;
  g_done_data = nullptr;
  const bool ok = strcmp(status, "ok") == 0;
  FlValue* result = fl_value_new_map();
  fl_value_set_string_take(result, "status", fl_value_new_string(status));
  if (message != nullptr) fl_value_set_string_take(result, "message", fl_value_new_string(message));
  if (ok) {
    g_connected = true;
    AddRegionIds(g_streams);
    fl_value_set_string_take(result, "streams",
                             g_streams != nullptr ? fl_value_ref(g_streams) : fl_value_new_list());
    fl_value_set_string_take(result, "pipewireFd", fl_value_new_int(g_pipewire_fd));
    g_generation.fetch_add(1);
  }
  if (g_streams != nullptr) {
    fl_value_unref(g_streams);
    g_streams = nullptr;
  }
  g_busy = false;
  if (!ok && g_session != nullptr) Teardown(nullptr, true);
  if (done != nullptr) done(result, data);
}

gboolean OnStartTimeout(gpointer) {
  std::lock_guard<std::recursive_mutex> lock(g_lock);
  g_start_timeout = 0;
  if (g_done != nullptr) FinishStart("error", "The compositor didn't resume the devices");
  return G_SOURCE_REMOVE;
}

void OnSessionClosed(GDBusConnection*, const char*, const char*, const char*, const char*,
                     GVariant*, gpointer) {
  std::lock_guard<std::recursive_mutex> lock(g_lock);
  if (g_done != nullptr) {
    FinishStart("error", "The portal closed the session");
    return;
  }
  Teardown("closed", false);
}

FlValue* StreamsFrom(GVariant* results) {
  FlValue* list = fl_value_new_list();
  GVariant* streams = g_variant_lookup_value(results, "streams", G_VARIANT_TYPE("a(ua{sv})"));
  if (streams == nullptr) return list;
  GVariantIter iter;
  g_variant_iter_init(&iter, streams);
  guint32 node = 0;
  GVariant* props = nullptr;
  while (g_variant_iter_next(&iter, "(u@a{sv})", &node, &props)) {
    FlValue* s = fl_value_new_map();
    fl_value_set_string_take(s, "nodeId", fl_value_new_int(node));
    guint32 type = 0;
    if (g_variant_lookup(props, "source_type", "u", &type)) {
      fl_value_set_string_take(s, "sourceType", fl_value_new_int(type));
    }
    gint32 x = 0, y = 0, w = 0, h = 0;
    if (g_variant_lookup(props, "position", "(ii)", &x, &y)) {
      fl_value_set_string_take(s, "x", fl_value_new_int(x));
      fl_value_set_string_take(s, "y", fl_value_new_int(y));
    }
    if (g_variant_lookup(props, "size", "(ii)", &w, &h)) {
      fl_value_set_string_take(s, "width", fl_value_new_int(w));
      fl_value_set_string_take(s, "height", fl_value_new_int(h));
    }
    const char* mapping = nullptr;
    if (g_variant_lookup(props, "mapping_id", "&s", &mapping)) {
      fl_value_set_string_take(s, "mappingId", fl_value_new_string(mapping));
    }
    fl_value_append_take(list, s);
    g_variant_unref(props);
  }
  g_variant_unref(streams);
  return list;
}

void OnStarted(guint32 code, GVariant* results) {
  std::lock_guard<std::recursive_mutex> lock(g_lock);
  if (code == 1) {
    FinishStart("cancelled", nullptr);
    return;
  }
  if (code != 0 || results == nullptr) {
    FinishStart("error", "Start failed");
    return;
  }
  guint32 devices = 0;
  g_variant_lookup(results, "devices", "u", &devices);
  if ((devices & 3) != 3) {
    // The person left "Allow Remote Interaction" off.
    FinishStart("noControl", nullptr);
    return;
  }
  g_streams = StreamsFrom(results);
  GError* error = nullptr;
  if (g_options.screen_cast) {
    g_pipewire_fd = CallForFd("org.freedesktop.portal.ScreenCast", "OpenPipeWireRemote", &error);
    if (g_pipewire_fd < 0) {
      FinishStart("error", error != nullptr ? error->message : "OpenPipeWireRemote failed");
      if (error != nullptr) g_error_free(error);
      return;
    }
  }
  const int fd = CallForFd("org.freedesktop.portal.RemoteDesktop", "ConnectToEIS", &error);
  if (fd < 0) {
    FinishStart("error", error != nullptr ? error->message : "ConnectToEIS failed");
    if (error != nullptr) g_error_free(error);
    return;
  }
  g_ei = ei_new_sender(nullptr);
  ei_configure_name(g_ei, "remote_input");
  if (ei_setup_backend_fd(g_ei, fd) != 0) {
    ei_unref(g_ei);
    g_ei = nullptr;
    FinishStart("error", "libei couldn't connect to EIS");
    return;
  }
  g_ei_watch = g_unix_fd_add(ei_get_fd(g_ei), G_IO_IN, OnEi, nullptr);
  // The answer goes back once the compositor resumes the devices.
  g_start_timeout = g_timeout_add(kStartTimeoutMs, OnStartTimeout, nullptr);
}

void Start() {
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  Request("org.freedesktop.portal.RemoteDesktop", "Start", g_variant_new("(os)", g_session, ""),
          &options, OnStarted);
}

void OnSources(guint32 code, GVariant*) {
  std::lock_guard<std::recursive_mutex> lock(g_lock);
  if (code != 0) {
    FinishStart(code == 1 ? "cancelled" : "error", code == 1 ? nullptr : "SelectSources failed");
    return;
  }
  Start();
}

void OnDevices(guint32 code, GVariant*) {
  std::lock_guard<std::recursive_mutex> lock(g_lock);
  if (code != 0) {
    FinishStart(code == 1 ? "cancelled" : "error", code == 1 ? nullptr : "SelectDevices failed");
    return;
  }
  if (!g_options.screen_cast) {
    Start();
    return;
  }
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "types", g_variant_new_uint32(g_options.source_types));
  g_variant_builder_add(&options, "{sv}", "multiple", g_variant_new_boolean(g_options.multiple));
  g_variant_builder_add(&options, "{sv}", "cursor_mode",
                        g_variant_new_uint32(g_options.cursor_mode));
  g_variant_builder_add(&options, "{sv}", "persist_mode", g_variant_new_uint32(0));
  Request("org.freedesktop.portal.ScreenCast", "SelectSources", g_variant_new("(o)", g_session),
          &options, OnSources);
}

void OnCreated(guint32 code, GVariant* results) {
  std::lock_guard<std::recursive_mutex> lock(g_lock);
  const char* handle = nullptr;
  if (code != 0 || results == nullptr ||
      !g_variant_lookup(results, "session_handle", "&s", &handle)) {
    FinishStart(code == 1 ? "cancelled" : "error", code == 1 ? nullptr : "CreateSession failed");
    return;
  }
  g_session = g_strdup(handle);
  g_closed_sub = g_dbus_connection_signal_subscribe(
      g_bus, "org.freedesktop.portal.Desktop", "org.freedesktop.portal.Session", "Closed",
      g_session, nullptr, G_DBUS_SIGNAL_FLAGS_NONE, OnSessionClosed, nullptr, nullptr);
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "types", g_variant_new_uint32(1 | 2));
  g_variant_builder_add(&options, "{sv}", "persist_mode", g_variant_new_uint32(0));
  Request("org.freedesktop.portal.RemoteDesktop", "SelectDevices", g_variant_new("(o)", g_session),
          &options, OnDevices);
}

uint32_t PortalVersion() {
  GVariant* r = g_dbus_connection_call_sync(
      g_bus, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
      "org.freedesktop.DBus.Properties", "Get",
      g_variant_new("(ss)", "org.freedesktop.portal.RemoteDesktop", "version"),
      G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 2000, nullptr, nullptr);
  if (r == nullptr) return 0;
  GVariant* v = nullptr;
  g_variant_get(r, "(v)", &v);
  uint32_t version = g_variant_is_of_type(v, G_VARIANT_TYPE_UINT32) ? g_variant_get_uint32(v) : 0;
  g_variant_unref(v);
  g_variant_unref(r);
  return version;
}

void Teardown(const char* reason, bool close_session) {
  const bool was_live = g_session != nullptr || g_ei != nullptr;
  if (g_ei_watch != 0) {
    g_source_remove(g_ei_watch);
    g_ei_watch = 0;
  }
  for (Device& d : g_devices) ei_device_unref(d.device);
  g_devices.clear();
  g_regions.clear();
  g_region_ids.clear();
  g_next_region_id = 1;
  g_pointer = nullptr;
  if (g_ei != nullptr) {
    ei_unref(g_ei);
    g_ei = nullptr;
  }
  if (g_keymap != nullptr) {
    xkb_keymap_unref(g_keymap);
    g_keymap = nullptr;
  }
  g_mods_depressed = g_mods_latched = g_mods_locked = g_group = 0;
  if (g_closed_sub != 0) {
    g_dbus_connection_signal_unsubscribe(g_bus, g_closed_sub);
    g_closed_sub = 0;
  }
  if (g_session != nullptr) {
    if (close_session) {
      g_dbus_connection_call(g_bus, "org.freedesktop.portal.Desktop", g_session,
                             "org.freedesktop.portal.Session", "Close", nullptr, nullptr,
                             G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr, nullptr);
    }
    g_free(g_session);
    g_session = nullptr;
  }
  if (g_pipewire_fd >= 0) {
    close(g_pipewire_fd);
    g_pipewire_fd = -1;
  }
  const bool was_connected = g_connected;
  g_connected = false;
  g_generation.fetch_add(1);
  if (reason != nullptr && was_live && was_connected && g_closed != nullptr) {
    g_closed(reason, g_closed_data);
  }
}

}  // namespace

void ri_portal_start(const RiPortalOptions& options, RiPortalDone done, gpointer user_data) {
  std::lock_guard<std::recursive_mutex> lock(g_lock);
  auto fail = [&](const char* status, const char* message) {
    FlValue* result = fl_value_new_map();
    fl_value_set_string_take(result, "status", fl_value_new_string(status));
    if (message != nullptr) {
      fl_value_set_string_take(result, "message", fl_value_new_string(message));
    }
    done(result, user_data);
  };
  if (g_busy || g_session != nullptr) {
    fail("busy", "A portal session is already open");
    return;
  }
  if (g_bus == nullptr) g_bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
  if (g_bus == nullptr) {
    fail("unsupported", "No session bus");
    return;
  }
  if (PortalVersion() < 2) {
    fail("unsupported", "The RemoteDesktop portal is missing or older than version 2");
    return;
  }
  g_busy = true;
  g_options = options;
  g_done = done;
  g_done_data = user_data;
  GVariantBuilder opts;
  g_variant_builder_init(&opts, G_VARIANT_TYPE_VARDICT);
  char* session_token = NewToken();
  g_variant_builder_add(&opts, "{sv}", "session_handle_token", g_variant_new_string(session_token));
  g_free(session_token);
  Request("org.freedesktop.portal.RemoteDesktop", "CreateSession", nullptr, &opts, OnCreated);
}

void ri_portal_close() {
  std::lock_guard<std::recursive_mutex> lock(g_lock);
  if (g_done != nullptr) {
    FinishStart("cancelled", nullptr);
    return;
  }
  Teardown("closedByApp", true);
}

void ri_portal_set_closed_callback(RiPortalClosed closed, gpointer user_data) {
  g_closed = closed;
  g_closed_data = user_data;
}

#else  // !REMOTE_INPUT_HAS_EI

RI_EXPORT int32_t ri_has_wayland(void) { return 0; }
RI_EXPORT int32_t ri_wl_connected(void) { return 0; }
RI_EXPORT int32_t ri_wl_generation(void) { return 0; }
RI_EXPORT int32_t ri_wl_paused(void) { return 0; }
RI_EXPORT int32_t ri_wl_regions(int32_t, int32_t*, int32_t*, int32_t*, char*) { return 0; }
RI_EXPORT int32_t ri_wl_move(int32_t, double, double) { return RI_PERMISSION_DENIED; }
RI_EXPORT int32_t ri_wl_button(int32_t, int32_t) { return RI_PERMISSION_DENIED; }
RI_EXPORT int32_t ri_wl_scroll(double, double, int32_t) { return RI_PERMISSION_DENIED; }
RI_EXPORT int32_t ri_wl_key(int32_t, int32_t) { return RI_PERMISSION_DENIED; }
RI_EXPORT int32_t ri_wl_text(uint32_t) { return RI_PERMISSION_DENIED; }

void ri_portal_start(const RiPortalOptions&, RiPortalDone done, gpointer user_data) {
  FlValue* result = fl_value_new_map();
  fl_value_set_string_take(result, "status", fl_value_new_string("unsupported"));
  fl_value_set_string_take(result, "message",
                           fl_value_new_string("Built without libei: no Wayland support"));
  done(result, user_data);
}
void ri_portal_close() {}
void ri_portal_set_closed_callback(RiPortalClosed, gpointer) {}

#endif  // REMOTE_INPUT_HAS_EI
