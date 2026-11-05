# The Linux side of remote_input (docs/design.md §7.5): XTest on X11, and the
# RemoteDesktop portal with libei on Wayland.
#
# Build packages (Ubuntu 24.04 names): libgtk-3-dev, libx11-dev,
# libx11-xcb-dev, libxtst-dev, libxi-dev, libxrandr-dev, libudev-dev,
# libxkbcommon-dev and, for Wayland, libei-dev (libei 1.0 or later). Without
# libei the plugin builds with X11 only, and Wayland reports unsupported.
cmake_minimum_required(VERSION 3.10)

set(PROJECT_NAME "remote_input")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "remote_input_plugin")

add_library(${PLUGIN_NAME} SHARED
  "remote_input_plugin.cc"
  "remote_input_monitor.cc"
  "remote_input_wayland.cc"
  "remote_input_x11.cc"
)

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)

find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)
pkg_check_modules(RI_X11 REQUIRED IMPORTED_TARGET x11 x11-xcb xcb xtst xi xrandr)
pkg_check_modules(RI_SYSTEM REQUIRED IMPORTED_TARGET gio-unix-2.0 libudev xkbcommon)
pkg_check_modules(RI_EI IMPORTED_TARGET libei-1.0>=1.0)
target_link_libraries(${PLUGIN_NAME} PRIVATE
  PkgConfig::GTK PkgConfig::RI_X11 PkgConfig::RI_SYSTEM)
if(RI_EI_FOUND)
  target_compile_definitions(${PLUGIN_NAME} PRIVATE REMOTE_INPUT_HAS_EI)
  target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::RI_EI)
else()
  message(WARNING "remote_input: libei not found; Wayland injection is left out")
endif()

set(remote_input_bundled_libraries "" PARENT_SCOPE)
