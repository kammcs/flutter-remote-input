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

TEST(RemoteInputNative, HealthFollowsTheHookThread) {
  EXPECT_EQ(remote_input_activity_hooks_installed(), 0);
  EXPECT_EQ(remote_input_activity_heartbeat_age(), -1);
  ASSERT_EQ(remote_input_activity_start(), 1);
  EXPECT_EQ(remote_input_activity_hooks_installed(), 1);
  // The heartbeat ticks every 100 ms while the loop runs.
  Sleep(350);
  EXPECT_EQ(remote_input_activity_hooks_installed(), 1);
  const int64_t age = remote_input_activity_heartbeat_age();
  EXPECT_GE(age, 0);
  EXPECT_LT(age, 300);
  remote_input_activity_stop();
  EXPECT_EQ(remote_input_activity_hooks_installed(), 0);
  EXPECT_EQ(remote_input_activity_heartbeat_age(), -1);
}

// A stall of [gap] ms with the default hooks timeout (300 ms), after which
// Windows' last input is [last_input] and the hooks' newest physical and
// injected events are [physical] and [injected].
static remote_input::StallEvidence Stall(uint64_t gap, uint32_t last_input,
                                         uint32_t physical, uint32_t injected,
                                         bool known = true) {
  remote_input::StallEvidence e;
  e.gap_ms = gap;
  e.hooks_timeout_ms = 300;
  e.last_input_known = known;
  e.last_input = last_input;
  e.last_physical = physical;
  e.last_injected = injected;
  return e;
}

// RIN-39: a stall within the hooks timeout isn't local input by itself.
// Only input the hooks never saw is.
TEST(RemoteInputNative, StallWithEverythingSeenIsNotLocalInput) {
  // The newest input is the injected event the hooks got, late.
  EXPECT_FALSE(remote_input::StallMissedInput(Stall(250, 5000, 1000, 5000)));
  // ... or a physical one.
  EXPECT_FALSE(remote_input::StallMissedInput(Stall(250, 5000, 5000, 1000)));
  // No input at all since the hooks' last event.
  EXPECT_FALSE(remote_input::StallMissedInput(Stall(250, 4000, 5000, 3000)));
  // The same event, a clock tick apart.
  EXPECT_FALSE(remote_input::StallMissedInput(Stall(250, 5016, 1000, 5000)));
  // Exactly the timeout is still within it.
  EXPECT_FALSE(remote_input::StallMissedInput(Stall(300, 5000, 5000, 5000)));
}

TEST(RemoteInputNative, StallThatHidInputIsLocalInput) {
  EXPECT_TRUE(remote_input::StallMissedInput(Stall(250, 5300, 5000, 4000)));
  EXPECT_TRUE(remote_input::StallMissedInput(Stall(250, 5300, 4000, 5000)));
  // Across GetTickCount()'s wrap, for either kind.
  const uint32_t a = 0xFFFFFF00u;
  const uint32_t b = 0xFFFFFE00u;
  EXPECT_TRUE(remote_input::StallMissedInput(Stall(250, 200, a, b)));
  EXPECT_TRUE(remote_input::StallMissedInput(Stall(250, 200, b, a)));
  EXPECT_FALSE(remote_input::StallMissedInput(Stall(250, a, 200, b)));
  EXPECT_FALSE(remote_input::StallMissedInput(Stall(250, a, b, 200)));
}

TEST(RemoteInputNative, StallFailsClosedWithoutLastInputTime) {
  EXPECT_TRUE(
      remote_input::StallMissedInput(Stall(250, 0, 5000, 5000, false)));
}

// RIN-46: past the hooks timeout, Windows may have skipped the hooks for a
// physical event, and an injected event after it (seen by the re-installed
// hooks, and recorded by GetLastInputInfo too) would hide it. So such a
// stall always counts.
TEST(RemoteInputNative, StallLongerThanTheHooksTimeoutIsLocalInput) {
  // The masking case: the last input is the viewer's injected event, which
  // the hooks saw; the presenter's key in the stall was never hooked.
  EXPECT_TRUE(remote_input::StallMissedInput(Stall(301, 5000, 1000, 5000)));
  // Nothing at all seemed to be missed: it still counts.
  EXPECT_TRUE(remote_input::StallMissedInput(Stall(1500, 4000, 5000, 5000)));
  // With the timeout capped at 1000 ms.
  remote_input::StallEvidence e = Stall(1001, 5000, 5000, 5000);
  e.hooks_timeout_ms = 1000;
  EXPECT_TRUE(remote_input::StallMissedInput(e));
  e.gap_ms = 900;
  EXPECT_FALSE(remote_input::StallMissedInput(e));
}

TEST(RemoteInputNative, HooksTimeoutFollowsTheRegistry) {
  using remote_input::EffectiveHooksTimeout;
  using remote_input::HooksTimeoutSetting;
  EXPECT_EQ(EffectiveHooksTimeout(HooksTimeoutSetting::kValue, 250), 250u);
  EXPECT_EQ(EffectiveHooksTimeout(HooksTimeoutSetting::kValue, 1000), 1000u);
  // Windows 10 1709 and later cap it at 1000 ms.
  EXPECT_EQ(EffectiveHooksTimeout(HooksTimeoutSetting::kValue, 5000), 1000u);
  // Absent: the reported default.
  EXPECT_EQ(EffectiveHooksTimeout(HooksTimeoutSetting::kAbsent, 0), 300u);
  // Unreadable or zero: the stall threshold, so every stall counts.
  EXPECT_EQ(EffectiveHooksTimeout(HooksTimeoutSetting::kUnreadable, 900),
            200u);
  EXPECT_EQ(EffectiveHooksTimeout(HooksTimeoutSetting::kValue, 0), 200u);
}

TEST(RemoteInputNative, HooksTimeoutStringsParseStrictly) {
  uint32_t v = 0;
  EXPECT_TRUE(remote_input::ParseHooksTimeout(L"300", &v));
  EXPECT_EQ(v, 300u);
  EXPECT_TRUE(remote_input::ParseHooksTimeout(L" 5000 ", &v));
  EXPECT_EQ(v, 5000u);
  EXPECT_TRUE(remote_input::ParseHooksTimeout(L"4294967295", &v));
  EXPECT_EQ(v, 4294967295u);
  EXPECT_FALSE(remote_input::ParseHooksTimeout(L"4294967296", &v));
  EXPECT_FALSE(remote_input::ParseHooksTimeout(L"", &v));
  EXPECT_FALSE(remote_input::ParseHooksTimeout(L"  ", &v));
  EXPECT_FALSE(remote_input::ParseHooksTimeout(L"-1", &v));
  EXPECT_FALSE(remote_input::ParseHooksTimeout(L"0x12c", &v));
  EXPECT_FALSE(remote_input::ParseHooksTimeout(L"300ms", &v));
  EXPECT_FALSE(remote_input::ParseHooksTimeout(nullptr, &v));
}

TEST(RemoteInputNative, ReasonCountsOnlyGrowAndRejectUnknownReasons) {
  EXPECT_EQ(remote_input_activity_reason_count(-1), 0u);
  EXPECT_EQ(remote_input_activity_reason_count(REMOTE_INPUT_REASON_COUNT),
            0u);
  const uint64_t stalls =
      remote_input_activity_reason_count(REMOTE_INPUT_REASON_STALL);
  ASSERT_EQ(remote_input_activity_start(), 1);
  Sleep(350);
  remote_input_activity_stop();
  EXPECT_GE(remote_input_activity_reason_count(REMOTE_INPUT_REASON_STALL),
            stalls);
  // The heartbeat ran, so a gap was measured.
  EXPECT_GT(remote_input_activity_longest_gap(), 0u);
}

// RIN-41: keyboards and mice that go away (Bluetooth off) stop a session.
TEST(RemoteInputNative, RemovedDevicesCountsHandlesThatAreGone) {
  const uintptr_t before[] = {0x10, 0x20, 0x30};
  // Nothing changed, in another order.
  const uintptr_t same[] = {0x30, 0x10, 0x20};
  EXPECT_EQ(remote_input::RemovedDevices(before, 3, same, 3), 0u);
  // One went, one arrived: the count alone wouldn't show it.
  const uintptr_t swapped[] = {0x10, 0x30, 0x40};
  EXPECT_EQ(remote_input::RemovedDevices(before, 3, swapped, 3), 1u);
  // Bluetooth off: the wireless keyboard and mouse both go.
  const uintptr_t wired_only[] = {0x10};
  EXPECT_EQ(remote_input::RemovedDevices(before, 3, wired_only, 1), 2u);
  EXPECT_EQ(remote_input::RemovedDevices(before, 3, nullptr, 0), 3u);
  // Arrivals don't count.
  EXPECT_EQ(remote_input::RemovedDevices(nullptr, 0, before, 3), 0u);
  EXPECT_EQ(remote_input::RemovedDevices(wired_only, 1, before, 3), 0u);
}

TEST(RemoteInputNative, DeviceCountersStartEmptyAndFollowTheThread) {
  // Nothing was removed since the DLL loaded (no device is unplugged while
  // the tests run).
  EXPECT_EQ(remote_input_activity_devices_lost(), 0u);
  EXPECT_EQ(remote_input_activity_input_devices(), -1);
  ASSERT_EQ(remote_input_activity_start(), 1);
  // The thread read the list when it started: a count, which may be 0 on a
  // machine without a keyboard or mouse.
  EXPECT_GE(remote_input_activity_input_devices(), 0);
  Sleep(250);
  EXPECT_EQ(remote_input_activity_devices_lost(), 0u);
  remote_input_activity_stop();
  EXPECT_EQ(remote_input_activity_input_devices(), -1);
  EXPECT_EQ(remote_input_activity_devices_lost(), 0u);
}

TEST(RemoteInputNative, MoveOriginCountsRejectUnknownIndexes) {
  EXPECT_EQ(remote_input_activity_move_origin_count(-1), 0u);
  EXPECT_EQ(remote_input_activity_move_origin_count(8), 0u);
}

// RIN-39: Windows can deliver injected mouse moves without their
// dwExtraInfo tag. Injected input never counts, whatever its tag. A
// zero-distance relative move: the pointer doesn't move.
TEST(RemoteInputNative, InjectedMoveWithForeignTagIsNotLocalInput) {
  ASSERT_EQ(remote_input_activity_start(), 1);
  const uint64_t local = remote_input_activity_count();
  const uint64_t seen = remote_input_activity_move_origin_count(4 + 3);
  INPUT input = {};
  input.type = INPUT_MOUSE;
  input.mi.dwFlags = MOUSEEVENTF_MOVE;
  input.mi.dwExtraInfo = 0x12345678;  // Not the package's tag.
  uint32_t error = 0;
  ASSERT_EQ(remote_input_send_input(1, &input, sizeof(INPUT), &error), 1u);
  for (int i = 0; i < 50 && remote_input_activity_move_origin_count(4 + 3) ==
                                seen;
       i++) {
    Sleep(20);
  }
  const bool delivered =
      remote_input_activity_move_origin_count(4 + 3) > seen;
  const uint64_t after = remote_input_activity_count();
  remote_input_activity_stop();
  if (!delivered) GTEST_SKIP() << "no interactive desktop delivered the move";
  EXPECT_EQ(after, local);
}

TEST(RemoteInputPlugin, Constructs) { RemoteInputPlugin plugin; }

}  // namespace test
}  // namespace remote_input
