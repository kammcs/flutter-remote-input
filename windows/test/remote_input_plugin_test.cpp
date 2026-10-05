// Native unit tests: built with the example (Visual Studio or CI's windows
// job) and run as remote_input_test.exe. They inject nothing.
#include <gtest/gtest.h>
#include <windows.h>

#include "remote_input_native.h"
#include "remote_input_plugin.h"

namespace remote_input {
namespace test {

TEST(RemoteInputNative, InputLayoutMatchesDart) {
  // lib/src/host/windows/input_records.dart writes 40-byte records.
  EXPECT_EQ(remote_input_input_size(), 40);
}

TEST(RemoteInputNative, TagCarriesMagicAndProcessId) {
  const uint64_t tag = remote_input_tag();
  EXPECT_EQ(tag >> 32, 0x726D7469ull);
  EXPECT_EQ(tag & 0xFFFFFFFFull, static_cast<uint64_t>(GetCurrentProcessId()));
}

TEST(RemoteInputNative, SendInputRejectsWrongSize) {
  INPUT input = {};
  uint32_t error = 0;
  EXPECT_EQ(remote_input_send_input(1, &input, 12, &error), 0u);
  EXPECT_EQ(error, static_cast<uint32_t>(ERROR_INVALID_PARAMETER));
}

TEST(RemoteInputNative, ActivityStartsAndStopsIdempotently) {
  ASSERT_EQ(remote_input_activity_start(), 1);
  EXPECT_EQ(remote_input_activity_start(), 1);
  remote_input_activity_stop();
  remote_input_activity_stop();
  // And again after a stop.
  ASSERT_EQ(remote_input_activity_start(), 1);
  remote_input_activity_stop();
}

TEST(RemoteInputPlugin, Constructs) { RemoteInputPlugin plugin; }

}  // namespace test
}  // namespace remote_input
