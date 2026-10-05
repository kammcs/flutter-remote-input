import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
