import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart' show LocalInputSource;
import 'package:remote_input/src/host/windows/win32_api.dart'
    show NativeActivityReason;
import 'package:remote_input/src/host/windows/windows_activity.dart';

import 'fake_win32.dart';

void main() {
  test('hooks run only while listened to', () {
    fakeAsync((async) {
      final native = FakeNativeActivity();
      final monitor = WindowsLocalActivity(native);
      expect(native.running, isFalse);
      final sub = monitor.activity.listen((_) {});
      expect(native.running, isTrue);
      expect(monitor.isMonitoring, isTrue);
      sub.cancel();
      expect(native.running, isFalse);
      expect(monitor.isMonitoring, isFalse);
      // And again.
      final again = monitor.activity.listen((_) {});
      expect(native.running, isTrue);
      again.cancel();
      expect(native.starts, 2);
      expect(native.stops, 2);
    });
  });

  test('emits within one poll of a change, once per change', () {
    fakeAsync((async) {
      final native = FakeNativeActivity()..counter = 41;
      final monitor = WindowsLocalActivity(native);
      var events = 0;
      final sub = monitor.activity.listen((_) => events++);
      // Counts from before listening don't count.
      async.elapse(const Duration(milliseconds: 50));
      expect(events, 0);
      native.counter += 3;
      async.elapse(const Duration(milliseconds: 10));
      expect(events, 1);
      async.elapse(const Duration(milliseconds: 100));
      expect(events, 1);
      native.counter++;
      async.elapse(const Duration(milliseconds: 10));
      expect(events, 2);
      sub.cancel();
    });
  });

  test('retries the hooks if they fail to start', () {
    fakeAsync((async) {
      final native = FakeNativeActivity()..failStart = true;
      final monitor = WindowsLocalActivity(native);
      var events = 0;
      final sub = monitor.activity.listen((_) => events++);
      expect(monitor.isMonitoring, isFalse);
      async.elapse(const Duration(seconds: 3));
      expect(native.starts, 4);
      native.failStart = false;
      async.elapse(const Duration(seconds: 1));
      expect(monitor.isMonitoring, isTrue);
      native.counter++;
      async.elapse(const Duration(milliseconds: 10));
      expect(events, 1);
      sub.cancel();
      async.elapse(const Duration(seconds: 5));
      expect(native.starts, 5);
    });
  });

  group('health', () {
    test('hooks that are lost stop monitoring; recovery emits once', () {
      fakeAsync((async) {
        final native = FakeNativeActivity();
        final monitor = WindowsLocalActivity(native);
        var events = 0;
        final sub = monitor.activity.listen((_) => events++);
        expect(monitor.isMonitoring, isTrue);
        native.hooksLost = true;
        async.elapse(const Duration(milliseconds: 10));
        expect(monitor.isMonitoring, isFalse);
        expect(events, 0);
        native.hooksLost = false;
        async.elapse(const Duration(milliseconds: 10));
        expect(monitor.isMonitoring, isTrue);
        // Input in the gap went unseen: it counts as local input.
        expect(events, 1);
        async.elapse(const Duration(milliseconds: 100));
        expect(events, 1);
        sub.cancel();
      });
    });

    test('a stale heartbeat (a stuck hook thread) stops monitoring', () {
      fakeAsync((async) {
        final native = FakeNativeActivity();
        final monitor = WindowsLocalActivity(native);
        var events = 0;
        final sub = monitor.activity.listen((_) => events++);
        native.heartbeatAge = 400;
        async.elapse(const Duration(milliseconds: 10));
        expect(monitor.isMonitoring, isTrue);
        native.heartbeatAge = 401;
        async.elapse(const Duration(milliseconds: 10));
        expect(monitor.isMonitoring, isFalse);
        // Counted input still emits while unhealthy.
        native.counter++;
        async.elapse(const Duration(milliseconds: 10));
        expect(events, 1);
        native.heartbeatAge = 20;
        async.elapse(const Duration(milliseconds: 10));
        expect(monitor.isMonitoring, isTrue);
        // Only late, with the hooks in: the native side judges the stall,
        // so recovering alone isn't local input (RIN-39).
        expect(events, 1);
        sub.cancel();
      });
    });

    test('a late heartbeat under load is not local input (RIN-39)', () {
      fakeAsync((async) {
        final native = FakeNativeActivity();
        final monitor = WindowsLocalActivity(native);
        var events = 0;
        final sub = monitor.activity.listen((_) => events++);
        // A full-screen share and a stream of injected events delay the
        // hook thread: its stalls hid nothing.
        for (var i = 0; i < 20; i++) {
          native
            ..heartbeatAge = 450
            ..longestGap = 450;
          async.elapse(const Duration(milliseconds: 20));
          native
            ..countReason(NativeActivityReason.stall)
            ..heartbeatAge = 10;
          async.elapse(const Duration(milliseconds: 20));
        }
        expect(events, 0);
        expect(monitor.isMonitoring, isTrue);
        final counts = monitor.localInputCounts;
        expect(counts.total, 0);
        expect(counts.stalls, 20);
        expect(counts.longestGapMs, 450);
        sub.cancel();
      });
    });

    test('a stall that hid input is local input, by reason', () {
      fakeAsync((async) {
        final native = FakeNativeActivity();
        final monitor = WindowsLocalActivity(native);
        var events = 0;
        final sub = monitor.activity.listen((_) => events++);
        native
          ..countReason(NativeActivityReason.stall)
          ..countReason(NativeActivityReason.missed);
        async.elapse(const Duration(milliseconds: 10));
        expect(events, 1);
        native
          ..countReason(NativeActivityReason.key)
          ..countReason(NativeActivityReason.button)
          ..countReason(NativeActivityReason.move);
        async.elapse(const Duration(milliseconds: 10));
        expect(events, 2);
        final counts = monitor.localInputCounts;
        expect(counts.counted, {
          LocalInputSource.missed: 1,
          LocalInputSource.key: 1,
          LocalInputSource.button: 1,
          LocalInputSource.move: 1,
        });
        expect(counts.stalls, 1);
        expect(counts.details, isEmpty);
        // Where moves came from, for diagnosis: counts and a distance.
        native
          ..moveOrigins[5] = 12
          ..moveOrigins[0] = 1
          ..largestStep = 840;
        expect(monitor.localInputCounts.details, {
          'physicalMove.noTag': 1,
          'injectedMove.ours': 12,
          'largestUntaggedStepPx': 840,
        });
        sub.cancel();
      });
    });

    test('recovering from lost hooks counts as a monitor gap', () {
      fakeAsync((async) {
        final native = FakeNativeActivity();
        final monitor = WindowsLocalActivity(native);
        var events = 0;
        final sub = monitor.activity.listen((_) => events++);
        // Lost, then late too, then back.
        native.hooksLost = true;
        async.elapse(const Duration(milliseconds: 10));
        native
          ..hooksLost = false
          ..heartbeatAge = 450;
        async.elapse(const Duration(milliseconds: 10));
        expect(events, 0);
        native.heartbeatAge = 10;
        async.elapse(const Duration(milliseconds: 10));
        expect(events, 1);
        expect(monitor.localInputCounts.counted, {
          LocalInputSource.monitorGap: 1,
        });
        sub.cancel();
      });
    });

    test('a hook thread that has exited is started again', () {
      fakeAsync((async) {
        final native = FakeNativeActivity();
        final monitor = WindowsLocalActivity(native);
        final sub = monitor.activity.listen((_) {});
        expect(native.starts, 1);
        // The thread left its loop: no heartbeat, no hooks.
        native.running = false;
        async.elapse(const Duration(milliseconds: 10));
        expect(monitor.isMonitoring, isFalse);
        async.elapse(const Duration(milliseconds: 980));
        expect(native.starts, 1);
        async.elapse(const Duration(milliseconds: 10));
        expect(native.starts, 2);
        async.elapse(const Duration(milliseconds: 10));
        expect(monitor.isMonitoring, isTrue);
        // Healthy again: no more starts.
        async.elapse(const Duration(seconds: 3));
        expect(native.starts, 2);
        sub.cancel();
        expect(monitor.isMonitoring, isFalse);
      });
    });

    test('a start that reports no hooks is not monitoring', () {
      fakeAsync((async) {
        final native = FakeNativeActivity()..hooksLost = true;
        final monitor = WindowsLocalActivity(native);
        final sub = monitor.activity.listen((_) {});
        expect(monitor.isMonitoring, isFalse);
        sub.cancel();
      });
    });
  });
}
