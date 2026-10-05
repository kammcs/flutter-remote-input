#ifndef FLUTTER_PLUGIN_REMOTE_INPUT_PLUGIN_H_
#define FLUTTER_PLUGIN_REMOTE_INPUT_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace remote_input {

class RemoteInputPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  RemoteInputPlugin();

  virtual ~RemoteInputPlugin();

  // Disallow copy and assign.
  RemoteInputPlugin(const RemoteInputPlugin&) = delete;
  RemoteInputPlugin& operator=(const RemoteInputPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace remote_input

#endif  // FLUTTER_PLUGIN_REMOTE_INPUT_PLUGIN_H_
