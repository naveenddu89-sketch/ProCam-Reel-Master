import 'package:flutter/material.dart';

/// Lightweight 3x3 rule-of-thirds grid + center cross.
/// A single CustomPainter draws it once; zero per-frame cost.
class GridOverlay extends StatelessWidget {
  final double opacity;
  const GridOverlay({super.key, this.opacity = 0.28});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _GridPainter(opacity),
      size: Size.infinite,
    );
  }
}

class _GridPainter extends CustomPainter {
  final double opacity;
  _GridPainter(this.opacity);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(opacity)
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;

    for (var i = 1; i <= 2; i++) {
      final x = size.width * i / 3;
      final y = size.height * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }

    final c = Offset(size.width / 2, size.height / 2);
    canvas.drawLine(c - const Offset(9, 0), c + const Offset(9, 0), paint);
    canvas.drawLine(c - const Offset(0, 9), c + const Offset(0, 9), paint);
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) => old.opacity != opacity;
}
