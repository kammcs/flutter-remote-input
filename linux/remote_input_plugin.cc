// The plugin's method channel on Linux: only the RemoteDesktop portal, whose
// dialog is asynchronous (docs/design.md §7.5). Injection, geometry and the
// safety checks go through dart:ffi (remote_input_native.h).
//
// Methods, matched by lib/src/host/linux/linux_portal.dart:
// - `portalStart` {screenCast, sourceTypes, multiple, cursorMode}: opens a
//   RemoteDesktop session (the system's dialog) and answers with a map
//   (remote_input_portal.h).
// - `portalClose`: closes it.
// And to Dart: `portalClosed` {reason} when a session ends.
#include "include/remote_input/remote_input_plugin.h"

#include <X11/Xlib-xcb.h>
#include <gdk/gdk.h>
#include <gdk/gdkx.h>
#include <gtk/gtk.h>
#include <xcb/xcb.h>

#include <atomic>
#include <cstring>

#include "remote_input_native.h"
#include "remote_input_portal.h"

namespace {

FlMethodChannel* g_channel = nullptr;
guint g_own_timer = 0;
std::atomic<int32_t> g_own_focused{-1};
std::atomic<int32_t> g_own_pointer{-1};

FlValue* Lookup(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return nullptr;
  return fl_value_lookup_string(args, key);
}

bool BoolArg(FlValue* args, const char* key, bool fallback) {
  FlValue* v = Lookup(args, key);
  return v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_BOOL ? fl_value_get_bool(v)
                                                                      : fallback;
}

int64_t IntArg(FlValue* args, const char* key, int64_t fallback) {
  FlValue* v = Lookup(args, key);
  return v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_INT ? fl_value_get_int(v)
                                                                     : fallback;
}

// This process's windows on Wayland, where no client knows where its windows
// are: whether one has focus, and whether the pointer is over one (from the
// compositor's pointer focus). Read every 20 ms while a portal session is
// open, so the FFI calls can answer from any thread.
gboolean ReadOwnWindows(gpointer) {
  bool focused = false;
  GList* windows = gtk_window_list_toplevels();
  for (GList* l = windows; l != nullptr; l = l->next) {
    if (gtk_window_is_active(GTK_WINDOW(l->data))) focused = true;
  }
  g_list_free(windows);
  bool over = false;
  GdkDisplay* display = gdk_display_get_default();
  GdkSeat* seat = display != nullptr ? gdk_display_get_default_seat(display) : nullptr;
  GdkDevice* pointer = seat != nullptr ? gdk_seat_get_pointer(seat) : nullptr;
  if (pointer != nullptr) over = gdk_device_get_window_at_position(pointer, nullptr, nullptr);
  g_own_focused.store(focused ? 1 : 0);
  g_own_pointer.store(over ? 1 : 0);
  return G_SOURCE_CONTINUE;
}

void StartOwnWindows() {
  if (g_own_timer != 0) return;
  ReadOwnWindows(nullptr);
  g_own_timer = g_timeout_add(20, ReadOwnWindows, nullptr);
}

void StopOwnWindows() {
  if (g_own_timer != 0) g_source_remove(g_own_timer);
  g_own_timer = 0;
  g_own_focused.store(-1);
  g_own_pointer.store(-1);
}

void OnPortalDone(FlValue* result, gpointer data) {
  auto* call = static_cast<FlMethodCall*>(data);
  FlValue* status = fl_value_lookup_string(result, "status");
  if (status != nullptr && strcmp(fl_value_get_string(status), "ok") == 0) StartOwnWindows();
  fl_method_call_respond_success(call, result, nullptr);
  fl_value_unref(result);
  g_object_unref(call);
}

void OnPortalClosed(const char* reason, gpointer) {
  StopOwnWindows();
  if (g_channel == nullptr) return;
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "reason", fl_value_new_string(reason));
  fl_method_channel_invoke_method(g_channel, "portalClosed", args, nullptr, nullptr, nullptr);
}

void OnMethodCall(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  if (strcmp(method, "portalStart") == 0) {
    RiPortalOptions options;
    options.screen_cast = BoolArg(args, "screenCast", false);
    options.source_types = static_cast<uint32_t>(IntArg(args, "sourceTypes", 1));
    options.multiple = BoolArg(args, "multiple", false);
    options.cursor_mode = static_cast<uint32_t>(IntArg(args, "cursorMode", 2));
    ri_portal_start(options, OnPortalDone, g_object_ref(call));
    return;
  }
  if (strcmp(method, "portalClose") == 0) {
    ri_portal_close();
    StopOwnWindows();
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  fl_method_call_respond_not_implemented(call, nullptr);
}

void ReadGdkX11Base() {
  GdkDisplay* display = gdk_display_get_default();
  if (display == nullptr || !GDK_IS_X11_DISPLAY(display)) return;
  Display* xdisplay = gdk_x11_display_get_xdisplay(display);
  xcb_connection_t* conn = xdisplay != nullptr ? XGetXCBConnection(xdisplay) : nullptr;
  if (conn == nullptr) return;
  const xcb_setup_t* setup = xcb_get_setup(conn);
  ri_set_gdk_x11_base(setup->resource_id_base, setup->resource_id_mask);
}

}  // namespace

// On the main thread (where Dart runs by default) GTK is read there and
// then, so the answer is as fresh as GTK's own; elsewhere from the timer.
void RefreshIfOnMainThread() {
  if (g_own_timer != 0 && g_main_context_is_owner(g_main_context_default())) {
    ReadOwnWindows(nullptr);
  }
}

RI_EXPORT int32_t ri_wl_own_app_in_front(void) {
  RefreshIfOnMainThread();
  return g_own_focused.load();
}

RI_EXPORT int32_t ri_wl_pointer_over_own_window(void) {
  RefreshIfOnMainThread();
  return g_own_pointer.load();
}

void remote_input_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  ReadGdkX11Base();
  if (g_channel != nullptr) return;
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_channel = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar), "remote_input",
                                    FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_channel, OnMethodCall, nullptr, nullptr);
  ri_portal_set_closed_callback(OnPortalClosed, nullptr);
}
