/// Where the remote picture is inside the capture widget, and the local
/// zoom on top of it (`docs/design.md` §3.1).
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/painting.dart' show Alignment, BoxFit, applyBoxFit;

/// The rect, in a box of [viewport] size, that a picture of [content] size
/// fills when laid out with [fit] and centred: the **content rect**,
/// excluding letterbox or pillarbox bars.
///
/// For fits that crop ([BoxFit.cover], and [BoxFit.none] or the `fit…`
/// values when the picture is larger), the rect is the whole picture's and
/// extends past the viewport, so a visible point maps to where it is in
/// the picture. Without a usable [content] size the whole viewport is the
/// content rect.
Rect contentRectFor(Size viewport, Size? content, BoxFit fit) {
  final whole = Offset.zero & viewport;
  if (content == null || content.isEmpty || viewport.isEmpty) return whole;
  final fitted = applyBoxFit(fit, content, viewport);
  if (fitted.source.isEmpty || fitted.destination.isEmpty) return whole;
  final sx = fitted.destination.width / fitted.source.width;
  final sy = fitted.destination.height / fitted.source.height;
  return Alignment.center.inscribe(
    Size(content.width * sx, content.height * sy),
    whole,
  );
}

/// The local view's zoom: the child is drawn scaled by [scale] about the
/// widget's top-left corner, then moved by [offset]. Never sent to the
/// host.
final class ViewZoom {
  /// Creates a zoom.
  const ViewZoom({this.scale = 1, this.offset = Offset.zero});

  /// No zoom.
  static const ViewZoom identity = ViewZoom();

  /// The scale, at least 1.
  final double scale;

  /// Where the child's top-left corner is drawn, in widget coordinates.
  final Offset offset;

  /// Whether this is [identity].
  bool get isIdentity => scale == 1 && offset == Offset.zero;

  /// Maps a widget point to the child's own (unzoomed) coordinates.
  Offset toChild(Offset widgetPoint) => (widgetPoint - offset) / scale;

  /// Maps a point in the child's coordinates to the widget's.
  Offset toWidget(Offset childPoint) => offset + childPoint * scale;

  /// This zoom with [offset] limited so the child still covers a viewport
  /// of [size].
  ViewZoom clampedTo(Size size) {
    final s = scale < 1 ? 1.0 : scale;
    final minX = size.width - size.width * s;
    final minY = size.height - size.height * s;
    return ViewZoom(
      scale: s,
      offset: Offset(
        offset.dx.clamp(math.min(minX, 0), 0),
        offset.dy.clamp(math.min(minY, 0), 0),
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ViewZoom && other.scale == scale && other.offset == offset;

  @override
  int get hashCode => Object.hash(scale, offset);
}

/// Maps [childPoint] to normalized coordinates across [contentRect]:
/// (0, 0) is its top-left corner and (1, 1) its bottom-right. Not clamped.
Offset normalizeIn(Rect contentRect, Offset childPoint) => Offset(
  contentRect.width == 0
      ? 0
      : (childPoint.dx - contentRect.left) / contentRect.width,
  contentRect.height == 0
      ? 0
      : (childPoint.dy - contentRect.top) / contentRect.height,
);

/// Whether normalized [point] is on the picture.
bool isInsideUnit(Offset point) =>
    point.dx >= 0 && point.dx <= 1 && point.dy >= 0 && point.dy <= 1;

/// Normalized [point] clamped onto the picture.
Offset clampToUnit(Offset point) =>
    Offset(point.dx.clamp(0.0, 1.0), point.dy.clamp(0.0, 1.0));
