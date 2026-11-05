#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <cstring>

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// The injection test's window channel (integration_test/
// linux_injection_test.dart): the window's X11 id and where the Flutter view
// sits in it, and fullscreen for the Wayland test.
static GtkWidget* g_view = nullptr;
static FlMethodChannel* g_window_channel = nullptr;

static void window_method_cb(FlMethodChannel* channel, FlMethodCall* call,
                             gpointer user_data) {
  GtkWindow* window = GTK_WINDOW(user_data);
  const gchar* name = fl_method_call_get_name(call);
  if (strcmp(name, "describe") == 0) {
    g_autoptr(FlValue) result = fl_value_new_map();
    GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
#ifdef GDK_WINDOWING_X11
    if (gdk_window != nullptr && GDK_IS_X11_WINDOW(gdk_window)) {
      fl_value_set_string_take(
          result, "xid",
          fl_value_new_int(static_cast<int64_t>(
              gdk_x11_window_get_xid(gdk_window))));
    }
#endif
    gint x = 0, y = 0;
    if (g_view != nullptr) {
      gtk_widget_translate_coordinates(g_view, GTK_WIDGET(window), 0, 0, &x,
                                       &y);
    }
    const int width = gdk_window != nullptr ? gdk_window_get_width(gdk_window) : 0;
    const int height =
        gdk_window != nullptr ? gdk_window_get_height(gdk_window) : 0;
    const int view_width =
        g_view != nullptr ? gtk_widget_get_allocated_width(g_view) : 0;
    const int view_height =
        g_view != nullptr ? gtk_widget_get_allocated_height(g_view) : 0;
    fl_value_set_string_take(result, "insetLeft", fl_value_new_int(x));
    fl_value_set_string_take(result, "insetTop", fl_value_new_int(y));
    fl_value_set_string_take(result, "insetRight",
                             fl_value_new_int(width - x - view_width));
    fl_value_set_string_take(result, "insetBottom",
                             fl_value_new_int(height - y - view_height));
    fl_value_set_string_take(
        result, "active", fl_value_new_bool(gtk_window_is_active(window)));
    fl_method_call_respond_success(call, result, nullptr);
  } else if (strcmp(name, "fullscreen") == 0) {
    gtk_window_fullscreen(window);
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else if (strcmp(name, "unfullscreen") == 0) {
    gtk_window_unfullscreen(window);
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else if (strcmp(name, "present") == 0) {
    gtk_window_present(window);
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "remote_input_example");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "remote_input_example");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_view = GTK_WIDGET(view);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_window_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "remote_input_example/window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_window_channel, window_method_cb,
                                            window, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
