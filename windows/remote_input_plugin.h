#ifndef FLUTTER_PLUGIN_REMOTE_INPUT_PLUGIN_H_
#define FLUTTER_PLUGIN_REMOTE_INPUT_PLUGIN_H_

#include <flutter/plugin_registrar_windows.h>

namespace remote_input {

// Registers the plugin with the app, which makes Flutter build and load
// remote_input_plugin.dll. Everything else goes through dart:ffi to the C
// API in remote_input_native.h: injection is synchronous, with no platform
// channel (docs/design.md §7.1).
class RemoteInputPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  RemoteInputPlugin();

  virtual ~RemoteInputPlugin();

  // Disallow copy and assign.
  RemoteInputPlugin(const RemoteInputPlugin&) = delete;
  RemoteInputPlugin& operator=(const RemoteInputPlugin&) = delete;
};

}  // namespace remote_input

#endif  // FLUTTER_PLUGIN_REMOTE_INPUT_PLUGIN_H_
