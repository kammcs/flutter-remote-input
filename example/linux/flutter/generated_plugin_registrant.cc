//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <remote_input/remote_input_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) remote_input_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "RemoteInputPlugin");
  remote_input_plugin_register_with_registrar(remote_input_registrar);
}
