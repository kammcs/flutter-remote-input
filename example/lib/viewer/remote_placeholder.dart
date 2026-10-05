import 'package:flutter/material.dart';

/// Stands in for the shared screen's video, which this example doesn't
/// have (`docs/design.md` §13, question 14): a surface with the host's
/// announced aspect ratio, letterboxed like a video view, with a grid and
/// the remote display's size in pixels.
///
/// The grid maps onto the shared display: a click a quarter of the way
/// across the grid lands a quarter of the way across the host's display.
/// Watch the host's own screen to see where.
class RemotePlaceholder extends StatelessWidget {
  /// Creates a placeholder for a picture of [pixelSize], or a waiting
  /// message while it's `null`.
  const RemotePlaceholder({super.key, required this.pixelSize});

  /// The remote surface's size in pixels, as the host announced it.
  final Size? pixelSize;

  @override
  Widget build(BuildContext context) {
    final size = pixelSize;
    final scheme = Theme.of(context).colorScheme;
    if (size == null || size.isEmpty) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Text(
            "Waiting for the host's screen size…",
            style: TextStyle(color: scheme.inversePrimary),
          ),
        ),
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: CustomPaint(
        painter: _GridPainter(size, scheme),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.picture, this.scheme);

  final Size picture;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final box = Offset.zero & size;
    final r = Alignment.center.inscribe(
      applyBoxFit(BoxFit.contain, picture, size).destination,
      box,
    );
    canvas.drawRect(r, Paint()..color = const Color(0xFF1B2533));
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..strokeWidth = 1;
    final major = Paint()
      ..color = Colors.white.withValues(alpha: 0.3)
      ..strokeWidth = 1;
    for (var i = 1; i < 8; i++) {
      final x = r.left + r.width * i / 8;
      final y = r.top + r.height * i / 8;
      final p = i == 4 ? major : line;
      canvas
        ..drawLine(Offset(x, r.top), Offset(x, r.bottom), p)
        ..drawLine(Offset(r.left, y), Offset(r.right, y), p);
    }
    canvas.drawRect(
      r.deflate(0.5),
      Paint()
        ..color = scheme.primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    final label = TextPainter(
      text: TextSpan(
        text:
            '${picture.width.round()} × ${picture.height.round()} px\n'
            "No video in this example: watch the host's screen.\n"
            'The grid maps onto the shared display.',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.75),
          fontSize: (r.height / 22).clamp(10, 18),
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: r.width * 0.9);
    label.paint(
      canvas,
      r.center - Offset(label.width / 2, label.height / 2 + r.height / 6),
    );
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.picture != picture || old.scheme != scheme;
}
