#include "include/remote_input/remote_input_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "remote_input_plugin.h"

void RemoteInputPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  remote_input::RemoteInputPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
