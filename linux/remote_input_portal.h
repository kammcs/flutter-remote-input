// Internal to the plugin: the RemoteDesktop portal session (Wayland), started
// from the method channel on the main thread.
#ifndef REMOTE_INPUT_PORTAL_H_
#define REMOTE_INPUT_PORTAL_H_

#include <flutter_linux/flutter_linux.h>

struct RiPortalOptions {
  // Also select ScreenCast sources on the same session: one dialog for the
  // share and the control.
  bool screen_cast = false;
  uint32_t source_types = 1;  // ScreenCast types: 1 monitor, 2 window.
  bool multiple = false;
  uint32_t cursor_mode = 2;  // 1 hidden, 2 embedded, 4 metadata.
};

// Called once with the result map: "status" ("ok", "cancelled", "noControl",
// "busy", "unsupported", "error"), "message", "streams" (a list of maps:
// nodeId, sourceType, x, y, width, height, mappingId, displayId) and
// "pipewireFd" (-1 without a screen cast). Takes ownership of [result].
typedef void (*RiPortalDone)(FlValue* result, gpointer user_data);

// Called when a portal session ends, with why: "closedByApp", "closed" (the
// portal or the user ended it) or "disconnected" (EIS went away).
typedef void (*RiPortalClosed)(const char* reason, gpointer user_data);

void ri_portal_start(const RiPortalOptions& options, RiPortalDone done, gpointer user_data);
void ri_portal_close();
void ri_portal_set_closed_callback(RiPortalClosed closed, gpointer user_data);

#endif  // REMOTE_INPUT_PORTAL_H_
