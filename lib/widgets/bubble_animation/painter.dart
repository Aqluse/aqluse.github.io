part of 'liquid_bubbles.dart';

class _Painter extends CustomPainter {
  _Painter({required this.manager}) : super(repaint: manager);

  final _PaintManager manager;

  final Paint _bubbleSurfacePaint = Paint();
  final Paint _bubbleGlowPaint = Paint();
  final Paint _bubbleMaskPaint = Paint();

  final Path _bridgePath = Path();
  final Paint _bridgePaint = Paint();
  final Paint _bridgeMaskPaint = Paint();

  final Color _transparentWhite = Colors.white.withValues(alpha: 0);

  @override
  void paint(Canvas canvas, Size size) {
    if (!_kDebugModeDrawBridgeOnTop) {
      for (final bridge in manager.bridges) {
        _drawBridge(canvas: canvas, bridge: bridge);
      }
    }

    // TODO: Эксперимент, в таком виде дает прирост +10-15 фпс, как ты хочешь конечно будет похуже
    /*_bubbleSurfacePaint
      ..color = _kPalette.first
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 50 * 2;
    canvas.drawPoints(
      .points,
      manager.bubbles.map((e) => e.position).toList(growable: false),
      _bubbleSurfacePaint,
    );*/

    for (int i = 0; i < manager.bubbles.length; i++) {
      final b = manager.bubbles[i];

      if (!b.needsDraw) continue;

      // Basic bubble.
      _bubbleSurfacePaint.color = b.color;
      canvas.drawCircle(b.position, b.radius, _bubbleSurfacePaint);

      // Mask spots within bubble.
      for (final spot in manager.maskPoints) {
        if (!spot.needsDraw(b)) continue;

        final dx = b.position.dx - spot.position.dx;
        final dy = b.position.dy - spot.position.dy;
        final maxDist = b.radius + spot.radius;

        if (dx * dx + dy * dy <= maxDist * maxDist) {
          _bubbleMaskPaint.shader = ui.Gradient.radial(
            spot.position,
            spot.radius,
            [b.colorMask, b.colorMaskWithAlpha0],
            const [0.05, 1.0],
          );

          canvas.drawCircle(b.position, b.radius, _bubbleMaskPaint);
        }

        if (_kDebugModeHighlightMaskPoints) {
          canvas.drawCircle(spot.position, 20, Paint()..color = Colors.red);
        }
      }

      // Bubble's inner glow (for deepness).
      if (!b.glowCovered) {
        final offset = b.radius * 0.2;
        final glowCenter = b.position - Offset(offset, offset);
        // TODO: Возможно учитывая радиус будет эффективно не делать отдельную проверку на перекрытие glow
        final glowRadius = b.radius * 0.8;

        _bubbleGlowPaint.shader = ui.Gradient.radial(glowCenter, glowRadius, [
          Colors.white.withValues(alpha: 0.3 * b.opacity),
          _transparentWhite,
        ]);
        canvas.drawCircle(b.position, b.radius, _bubbleGlowPaint);
      }
    }

    if (_kDebugModeDrawBridgeOnTop) {
      for (final bridge in manager.bridges) {
        _drawBridge(canvas: canvas, bridge: bridge);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;

  // TODO: Needs refactoring (moving calculations to onTick) after proper bridge figure paint is done.
  void _drawBridge({required Canvas canvas, required _BubbleBridge bridge}) {
    bool isBridgeCovered(
      _Bubble laterB,
      _Bubble b1,
      _Bubble b2,
      double maxBridgeRadius,
      Offset midBetweenCenters,
      Offset p1,
      Offset p2,
      Offset p3,
      Offset p4,
    ) {
      if (laterB == b1 || laterB == b2) return false;
      if (!laterB.needsDraw) return false;
      // Can bridge be covered by bubble of given radius.
      if (laterB.radius < maxBridgeRadius) return false;

      final dx = (laterB.position.dx - midBetweenCenters.dx).abs();
      if (dx > laterB.radius) return false;

      final dy = (laterB.position.dy - midBetweenCenters.dy).abs();
      if (dy > laterB.radius) return false;

      final rSq = laterB.radius * laterB.radius;
      // Diagonally (for performance) checks if bubble covers all 4 points of bridge.
      if ((p1 - laterB.position).distanceSquared > rSq ||
          (p4 - laterB.position).distanceSquared > rSq ||
          (p2 - laterB.position).distanceSquared > rSq ||
          (p3 - laterB.position).distanceSquared > rSq) {
        return false;
      }

      return true;
    }

    final b1 = bridge.bubble1;
    final b2 = bridge.bubble2;

    if (!b1.visible && !b2.visible) return;

    final distSquared = (b1.position - b2.position).distanceSquared;

    // When one bubble is fully inside another bubble, then bridge is not visible.
    final radiusDiff = b1.radius - b2.radius;
    if (distSquared <= radiusDiff * radiusDiff) {
      return;
    }

    final angle = (b2.position - b1.position).direction;
    final v = pi / 2;

    // 4 pivotal points of bridge on connected bubbles.
    final p1 = b1.position + Offset.fromDirection(angle + v, b1.radius);
    final p2 = b1.position + Offset.fromDirection(angle - v, b1.radius);
    final p3 = b2.position + Offset.fromDirection(angle + pi - v, b2.radius);
    final p4 = b2.position + Offset.fromDirection(angle + pi + v, b2.radius);

    // TODO: May be useful for implementing proper bridge visualiation later.
    /*
    double _distanceToLine(Offset p, Offset l1, Offset l2) {
      final double num =
          ((l2.dy - l1.dy) * p.dx -
                  (l2.dx - l1.dx) * p.dy +
                  l2.dx * l1.dy -
                  l2.dy * l1.dx)
              .abs();
      final double den =
          (l1 - l2).distance; // Использует встроенный гипотенузу (sqrt)

      if (den == 0)
        return 0.0; // Защита от деления на ноль, если точки линии совпали
      return num / den;
    }

    // Это дистанции от центра до линии между двух точек на окружности
    final dist1 = _distanceToLine(b1.position, p1, p2);
    final dist2 = _distanceToLine(b2.position, p3, p4);

    */

    final midBetweenCenters = (b1.position + b2.position) / 2;
    final maxBridgeRadius = max(b1.radius, b2.radius);

    for (int i = manager.bubbles.length - 1; i >= 0; i--) {
      final bubble = manager.bubbles[i];
      if (isBridgeCovered(
        bubble,
        b1,
        b2,
        maxBridgeRadius,
        midBetweenCenters,
        p1,
        p2,
        p3,
        p4,
      )) {
        bridge.covered = true;
        return;
      }
    }
    bridge.covered = false;

    final dist = sqrt(distSquared);
    final double stretch =
        ((dist - max(b1.radius, b2.radius)) / min(b1.radius, b2.radius)).clamp(
          0,
          1,
        );
    final mid1 = Offset.lerp((p1 + p3) / 2, midBetweenCenters, stretch)!;
    final mid2 = Offset.lerp((p2 + p4) / 2, midBetweenCenters, stretch)!;

    final double weight = (5 * stretch).clamp(0.1, 5);

    _bridgePath.reset();
    _bridgePath
      ..moveTo(p1.dx, p1.dy)
      ..conicTo(mid1.dx, mid1.dy, p3.dx, p3.dy, weight)
      ..lineTo(p4.dx, p4.dy)
      ..conicTo(mid2.dx, mid2.dy, p2.dx, p2.dy, weight)
      ..close();

    // Radius relation used to calculate stops of gradient.
    double s1 = (b1.radius / dist).clamp(0, 1);
    double s2 = (1 - b2.radius / dist).clamp(0, 1);

    // In case of bubbles intersected.
    if (s1 > s2) {
      final ratio = b1.radius / (b1.radius + b2.radius);
      s1 = s2 = ratio;
    }

    if (b1.color == b2.color) {
      _bridgePaint.shader = null;
      _bridgePaint.color = b1.color;
    } else {
      _bridgePaint.shader = ui.Gradient.linear(
        b1.position,
        b2.position,
        [b1.color, b1.color, b2.color, b2.color],
        [0, s1, s2, 1],
      );
    }

    canvas.drawPath(_bridgePath, _bridgePaint);

    for (final spot in manager.maskPoints) {
      // Path masks severely degrade performance;
      // skip drawing masks if the visible part of the bridge is stretched.
      if (stretch > 0.3) break;

      if (!spot.visible) continue;

      final rel = spot.position - b1.position;
      final vec = b2.position - b1.position;
      final l2 = vec.dx * vec.dx + vec.dy * vec.dy;

      // Project mask spot center onto bridge axis for color interpolation
      final double t = ((rel.dx * vec.dx + rel.dy * vec.dy) / l2).clamp(0, 1);

      // How far is the mask spot from the bridge.
      final projection = b1.position + vec * t;
      final maxDist = spot.radius + max(b1.radius, b2.radius);
      if ((spot.position - projection).distanceSquared > maxDist * maxDist) {
        continue;
      }

      // TODO: Not effective enough for now, awaits for implementation of sections for objects, then maybe...
      /* ⚡ 2. Эффективный радиус пятна на самом мостике
      final bridgeMaxRadius = max(b1.radius, b2.radius);
      final effectiveRadius = min(spot.radius, bridgeMaxRadius);

      // ⚡ 3. ПРОВЕРКА: Накрыта ли эта зона мостика сторонним шариком ИЛИ другой маской?
      bool maskCovered = false;
      for (int i = manager.bubbles.length - 1; i >= 0; i--) {
        final bubble = manager.bubbles[i];
        if (bubble == b1 || bubble == b2) continue; // Пропускаем хозяев мостика

        if (_isMaskCoveredByBubble(projection, effectiveRadius, bubble)) {
          maskCovered = true;
          break; // Зона маски на мостике 100% накрыта шариком!
        }
      }

      if (!maskCovered) {
        for (final otherSpot in manager.maskPoints) {
          if (otherSpot == spot) continue;
          if (_isMaskCoveredByMask(projection, effectiveRadius, otherSpot)) {
            maskCovered = true;
            break; // Зона маски на мостике 100% накрыта другой маской!
          }
        }
      }

      // Если зона маски на мостике накрыта сторонним шаром или другой маской — пропускаем отрисовку!
      if (maskCovered) continue;*/

      // TODO: Not effective enough for now, awaits for implementation of sections for objects, then maybe...
      // ⚡ Новая проверка: перекрытие РЕАЛЬНОЙ зоны пересечения _bridgePath и маски spot
      /*if (_isBridgeMaskRegionCoveredByBubbles(_bridgePath, spot, b1, b2)) {
        continue; // Реальная перекрестная область на мосту 100% накрыта!
      }*/

      final spotColor = Color.lerp(b1.colorMask, b2.colorMask, t)!;
      _bridgeMaskPaint.shader = ui.Gradient.radial(
        spot.position,
        spot.radius,
        [spotColor, spotColor.withAlpha(0)],
        const [0.05, 1.0],
      );

      canvas.drawPath(_bridgePath, _bridgeMaskPaint);
    }

    // TODO: Control points for drawing a curved line (for debug)
    //canvas.drawCircle(mid1, 5, Paint()..color = Colors.red);
    //canvas.drawCircle(mid2, 5, Paint()..color = Colors.red);
  }

  /*bool _isBridgeMaskRegionCoveredByBubbles(
    Path bridgePath,
    _MaskPoint spot,
    _Bubble b1,
    _Bubble b2,
  ) {
    final spotPath = Path()
      ..addOval(Rect.fromCircle(center: spot.position, radius: spot.radius));
    final maskRegionWithinBubble = Path.combine(
      PathOperation.intersect,
      bridgePath,
      spotPath,
    );

    final maskBounds = maskRegionWithinBubble.getBounds();
    if (maskBounds.isEmpty) return true;

    for (int i = manager.bubbles.length - 1; i >= 0; i--) {
      final later = manager.bubbles[i];
      if (later == b1 || later == b2) continue;
      if (!later.needsDraw) continue;

      final rSq = later.radius * later.radius;

      if ((maskBounds.topLeft - later.position).distanceSquared <= rSq &&
          (maskBounds.topRight - later.position).distanceSquared <= rSq &&
          (maskBounds.bottomLeft - later.position).distanceSquared <= rSq &&
          (maskBounds.bottomRight - later.position).distanceSquared <= rSq) {
        return true;
      }
    }

    return false;
  }*/
}
