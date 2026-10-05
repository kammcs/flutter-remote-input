#include "remote_input_plugin.h"

#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace remote_input {

// static
void RemoteInputPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  registrar->AddPlugin(std::make_unique<RemoteInputPlugin>());
}

RemoteInputPlugin::RemoteInputPlugin() {}

RemoteInputPlugin::~RemoteInputPlugin() {}

}  // namespace remote_input
