// Internal to the plugin: what the X11 code shares with the monitor thread.
#ifndef REMOTE_INPUT_X11_H_
#define REMOTE_INPUT_X11_H_

#include <X11/Xlib.h>

// The monitor thread's own X connection, so the error handler traps its
// errors too (nullptr when it closes).
void ri_x11_set_monitor_display(Display* display);

// Installs the package's X error handler, once (before any X call of ours).
void ri_x11_install_error_handler();

#endif  // REMOTE_INPUT_X11_H_
