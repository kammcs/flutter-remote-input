import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/painting.dart' show EdgeInsets;

/// The part of the host's desktop the viewer controls: a display, a window,
/// or bounds the app supplies (`docs/design.md` §3.2).
///
/// Bounds are in **each OS's own desktop coordinates**, the ones its input
/// APIs take: points in Core Graphics' global display space on macOS, and
/// physical pixels of the virtual screen (per-monitor DPI aware) on
/// Windows. Both put the origin at the primary display's top-left corner,
/// with y growing downwards and negative values left of or above it.
sealed class SharedSurface {
  const SharedSurface({this.contentInsets = EdgeInsets.zero});

  /// A display, by its id in `RemoteInputHost.displays`.
  const factory SharedSurface.display(
    int displayId, {
    EdgeInsets contentInsets,
  }) = DisplaySurface;

  /// One top-level window: an `HWND` on Windows, a `CGWindowID` on macOS.
  ///
  /// The pointer is confined to it, and keys go to it only while it's in
  /// front.
  const factory SharedSurface.window(int handle, {EdgeInsets contentInsets}) =
      WindowSurface;

  /// Bounds the app supplies and keeps up to date with [RectSurface.update],
  /// for example from a screen-share package's geometry stream.
  factory SharedSurface.rect(
    Rect bounds, {
    Size? pixelSize,
    EdgeInsets contentInsets,
  }) = RectSurface;

  /// How far the captured picture's edges are inside the surface's bounds,
  /// in the same units, for a capturer that leaves out a window's title bar
  /// or shadow. The viewer's normalized points map onto the bounds deflated
  /// by these insets (`docs/design.md` §3.3).
  final EdgeInsets contentInsets;
}

/// A display surface. See [SharedSurface.display].
final class DisplaySurface extends SharedSurface {
  /// Creates a [DisplaySurface].
  const DisplaySurface(this.displayId, {super.contentInsets});

  /// The display's id, from `RemoteInputHost.displays`.
  final int displayId;
}

/// A window surface. See [SharedSurface.window].
final class WindowSurface extends SharedSurface {
  /// Creates a [WindowSurface].
  const WindowSurface(this.handle, {super.contentInsets});

  /// The window's handle: an `HWND` on Windows, a `CGWindowID` on macOS.
  final int handle;
}

/// A surface with app-supplied bounds. See [SharedSurface.rect].
final class RectSurface extends SharedSurface {
  /// Creates a [RectSurface] with [bounds].
  ///
  /// [pixelSize] is the surface's size in pixels, which the viewer is told
  /// before the first video frame arrives. It defaults to [bounds]' size.
  RectSurface(Rect bounds, {Size? pixelSize, super.contentInsets})
    : _bounds = bounds,
      _pixelSize = pixelSize; // ignore: prefer_initializing_formals

  Rect _bounds;
  Size? _pixelSize;
  bool _closed = false;

  /// The bounds now.
  Rect get bounds => _bounds;

  /// The size in pixels.
  Size get pixelSize => _pixelSize ?? _bounds.size;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  /// Moves or resizes the surface. Takes effect from the next event.
  void update(Rect bounds, {Size? pixelSize}) {
    _bounds = bounds;
    if (pixelSize != null) _pixelSize = pixelSize;
  }

  /// Says the surface has gone. A session on it stops with
  /// `StopReason.surfaceGone` at its next event.
  void close() => _closed = true;
}

/// A display on the host, from `RemoteInputHost.displays`.
final class DisplayInfo {
  /// Creates a [DisplayInfo].
  const DisplayInfo({
    required this.id,
    required this.bounds,
    required this.scaleFactor,
    required this.isPrimary,
  });

  /// The display's id: a `CGDirectDisplayID` on macOS, an index into the
  /// monitor list on Windows.
  final int id;

  /// Its bounds, in desktop coordinates ([SharedSurface]).
  final Rect bounds;

  /// Physical pixels per desktop unit: 2 for a Retina display on macOS;
  /// always 1 on Windows, whose desktop coordinates are pixels.
  final double scaleFactor;

  /// Whether this is the primary display (its top-left is the origin).
  final bool isPrimary;

  /// The display's size in physical pixels.
  Size get pixelSize => bounds.size * scaleFactor;
}

/// Where a surface is now, from a `SurfaceResolver`.
final class SurfaceGeometry {
  /// Creates a [SurfaceGeometry].
  const SurfaceGeometry({
    required this.bounds,
    required this.pixelSize,
    this.isHidden = false,
  });

  /// Bounds in desktop coordinates, before `contentInsets`.
  final Rect bounds;

  /// The size in pixels.
  final Size pixelSize;

  /// Whether the surface is minimized or hidden: input is blocked until it's
  /// back.
  final bool isHidden;
}

/// Maps a normalized wire value (0–65535) onto [start]..[start]+[extent]:
/// the centre of the value's step (`docs/design.md` §3.2).
double mapNormalized(int v, double start, double extent) =>
    start + (v + 0.5) * extent / 65536;

/// Maps a normalized wire point onto [bounds].
Offset mapNormalizedPoint(int x, int y, Rect bounds) => Offset(
  mapNormalized(x, bounds.left, bounds.width),
  mapNormalized(y, bounds.top, bounds.height),
);
