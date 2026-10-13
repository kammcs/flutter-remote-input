// RIN-51: a point never lands outside the shared surface, not even one
// pixel past its right or bottom edge, and negative content insets are
// refused.
import 'dart:ui';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_input/remote_input.dart';
import 'package:remote_input/src/host/windows/input_records.dart'
    show desktopPixel;
import 'package:remote_input/src/surface.dart' show clampToSurface, lastInside;
import 'package:remote_input/testing.dart';

import 'session_test.dart' show Rig;

/// The wire values of the four corners, the four edge midpoints and the
/// centre.
const List<(int, int)> _edges = [
  (0, 0),
  (65535, 0),
  (0, 65535),
  (65535, 65535),
  (32768, 0),
  (32768, 65535),
  (0, 32768),
  (65535, 32768),
  (32768, 32768),
];

const List<EdgeInsets> _insets = [
  EdgeInsets.zero,
  EdgeInsets.fromLTRB(4, 30, 4, 4),
  EdgeInsets.fromLTRB(0, 0, 7, 9),
  EdgeInsets.only(left: 1279, top: 799),
];

/// Whether [p] is inside [bounds], whose right and bottom edges are
/// outside it, and its pixel (floored, as Windows injects it) too.
void _expectInside(Offset p, Rect bounds) {
  expect(p.dx, greaterThanOrEqualTo(bounds.left));
  expect(p.dx, lessThan(bounds.right));
  expect(p.dy, greaterThanOrEqualTo(bounds.top));
  expect(p.dy, lessThan(bounds.bottom));
  expect(desktopPixel(p.dx), lessThanOrEqualTo(bounds.right.ceil() - 1));
  expect(desktopPixel(p.dy), lessThanOrEqualTo(bounds.bottom.ceil() - 1));
  expect(desktopPixel(p.dx), greaterThanOrEqualTo(bounds.left.floor()));
  expect(desktopPixel(p.dy), greaterThanOrEqualTo(bounds.top.floor()));
}

void main() {
  tearDown(RemoteInputHost.stopAll);

  group('clampToSurface', () {
    const bounds = Rect.fromLTWH(-1920, -200, 1920, 1080);

    test('keeps the right and bottom edges outside', () {
      final p = clampToSurface(const Offset(1e9, 1e9), bounds);
      expect(p.dx, lessThan(bounds.right));
      expect(p.dy, lessThan(bounds.bottom));
      // The last pixel inside, as Windows floors it.
      expect(desktopPixel(p.dx), -1);
      expect(desktopPixel(p.dy), 879);
    });

    test('an edge exactly is pulled inside', () {
      final p = clampToSurface(bounds.bottomRight, bounds);
      expect(desktopPixel(p.dx), -1);
      expect(desktopPixel(p.dy), 879);
      expect(clampToSurface(bounds.topLeft, bounds), bounds.topLeft);
    });

    test('every corner and edge of several layouts', () {
      for (final b in const [
        Rect.fromLTWH(0, 0, 1920, 1080),
        Rect.fromLTWH(-3840, -2160, 3840, 2160),
        Rect.fromLTWH(1920, -500, 1, 1),
        Rect.fromLTWH(-640, 200, 640, 480),
        Rect.fromLTWH(0, 0, 23040, 4320), // 3×8K
        Rect.fromLTWH(100.5, 50.25, 0.75, 33.3), // app-supplied, fractional
      ]) {
        for (final o in [
          b.topLeft,
          b.topRight,
          b.bottomLeft,
          b.bottomRight,
          b.center,
          b.topLeft - const Offset(5, 5),
          b.bottomRight + const Offset(5, 5),
          Offset(b.right, b.center.dy),
          Offset(b.center.dx, b.bottom),
        ]) {
          _expectInside(clampToSurface(o, b), b);
        }
      }
    });

    test('lastInside is where the last wire value lands', () {
      // Half a wire step short of the edge: the same as mapping 65535.
      expect(lastInside(0, 1920), 1920 - 1920 / 131072);
      expect(lastInside(0, 1920), lessThan(1920));
      // A step too small to subtract falls back to the start.
      expect(lastInside(1e15, 1e15 + 1e-6), 1e15);
    });
  });

  group('points at every edge and corner land inside the surface', () {
    for (final insets in _insets) {
      test('display, insets $insets', () {
        fakeAsync((async) {
          final platform = FakeHostPlatform();
          const bounds = Rect.fromLTWH(-1920, -200, 1920, 1080);
          platform.surfaces.displayList.add(
            const DisplayInfo(
              id: 3,
              bounds: bounds,
              scaleFactor: 1,
              isPrimary: false,
            ),
          );
          final rig = Rig(
            async,
            platform: platform,
            surface: SharedSurface.display(3, contentInsets: insets),
          );
          _sendEverywhere(rig);
          _expectAllInside(rig, bounds, insets);
        });
      });

      test('window, insets $insets', () {
        fakeAsync((async) {
          final platform = FakeHostPlatform();
          const bounds = Rect.fromLTWH(300, 120, 1280, 800);
          platform.surfaces.windows[7] = const SurfaceGeometry(
            bounds: bounds,
            pixelSize: Size(1280, 800),
          );
          final rig = Rig(
            async,
            platform: platform,
            surface: SharedSurface.window(7, contentInsets: insets),
          );
          _sendEverywhere(rig);
          _expectAllInside(rig, bounds, insets);
        });
      });

      test('rect, insets $insets', () {
        fakeAsync((async) {
          const bounds = Rect.fromLTWH(-640, 200, 2560, 1440);
          final rig = Rig(
            async,
            surface: SharedSurface.rect(bounds, contentInsets: insets),
          );
          _sendEverywhere(rig);
          _expectAllInside(rig, bounds, insets);
        });
      });
    }
  });

  group('negative content insets are refused', () {
    for (final insets in const [
      EdgeInsets.only(left: -50),
      EdgeInsets.only(top: -1),
      EdgeInsets.only(right: -0.5),
      EdgeInsets.only(bottom: -1920),
      EdgeInsets.only(left: double.nan),
      EdgeInsets.only(right: double.infinity),
    ]) {
      test('by enable: $insets', () {
        final link = MemoryInputLink.pair().host;
        final host = RemoteInputHost(platform: FakeHostPlatform());
        for (final surface in [
          SharedSurface.display(1, contentInsets: insets),
          SharedSurface.window(7, contentInsets: insets),
          SharedSurface.rect(
            const Rect.fromLTWH(0, 0, 100, 100),
            contentInsets: insets,
          ),
        ]) {
          expect(
            () => host.enable(link: link, surface: surface),
            throwsArgumentError,
          );
          expect(RemoteInputHost.activeSession, isNull);
        }
      });

      test('by changeSurface: $insets', () {
        fakeAsync((async) {
          final rig = Rig(async);
          expect(
            () => rig.session.changeSurface(
              SharedSurface.display(1, contentInsets: insets),
            ),
            throwsArgumentError,
          );
          // Nothing changed: same surface, same epoch, still active.
          expect(rig.session.surfaceEpoch, 0);
          expect(rig.session.state, const SessionActive());
        });
      });
    }

    test('zero and positive insets are fine', () {
      fakeAsync((async) {
        final rig = Rig(
          async,
          surface: const SharedSurface.display(
            1,
            contentInsets: EdgeInsets.fromLTRB(0, 28, 0, 0),
          ),
        );
        rig.session.changeSurface(
          const SharedSurface.display(1, contentInsets: EdgeInsets.all(3)),
        );
        expect(rig.session.surfaceEpoch, 1);
      });
    });
  });
}

/// Clicks, moves and scrolls at every corner and edge midpoint.
void _sendEverywhere(Rig rig) {
  for (final (x, y) in _edges) {
    rig.viewer.move(x, y);
    rig.flush();
    rig.elapse(const Duration(milliseconds: 5));
    rig.viewer
      ..button(x, y, PointerButton.left, down: true)
      ..button(x, y, PointerButton.left, down: false)
      ..wheel(x, y, dy: 1);
    rig.flush();
    rig.elapse(const Duration(milliseconds: 100));
  }
}

void _expectAllInside(Rig rig, Rect bounds, EdgeInsets insets) {
  final points = [
    for (final e in rig.events)
      switch (e) {
        InjectedMove(:final point) ||
        InjectedButton(:final point) ||
        InjectedWheel(:final point) => point,
        _ => null,
      },
  ].nonNulls.toList();
  // A move, two buttons and a wheel at each point.
  expect(points, hasLength(_edges.length * 4));
  final content = insets.deflateRect(bounds);
  for (final p in points) {
    _expectInside(p, bounds);
    _expectInside(p, content);
  }
  // The far corner is the content's last pixel, not one past it.
  final far = points[3 * 4];
  expect(desktopPixel(far.dx), content.right.ceil() - 1);
  expect(desktopPixel(far.dy), content.bottom.ceil() - 1);
}
