part of 'liquid_bubbles.dart';

class _PaintManager extends ChangeNotifier {
  _PaintManager();

  final Random _random = Random();

  Size? _canvasSizeRaw;

  Size get _canvasSize => _canvasSizeRaw!;
  bool _canvasSizeUpdated = false;

  /// PERF: metaball renderer stats (filled by _MetaballRenderer). Tiles, splits and culled
  /// (saturated, invisible) spots are per frame; max values and dropped objects accumulate
  /// (reset when a measuring phase starts).
  int statSdfTiles = 0;
  int statSdfSplits = 0;
  int statSdfCulled = 0;
  int statSdfMaxTileBubbles = 0;
  int statSdfMaxTileSpots = 0;
  int statSdfDropped = 0;

  /// Fusing bubble pairs (necks) per frame, max per drawn tile and dropped on overflow.
  int statSdfPairs = 0;
  int statSdfMaxTilePairs = 0;
  int statSdfDroppedPairs = 0;

  /// Per frame: pairs skipped because higher bubbles hide the whole neck, and pairs and
  /// bubbles skipped in tiles fully covered by higher bubbles (summed over tiles).
  int statSdfOccludedPairs = 0;
  int statSdfTileOccludedPairs = 0;
  int statSdfTileOccludedBubbles = 0;

  void resetSdfStats() {
    statSdfMaxTileBubbles = 0;
    statSdfMaxTileSpots = 0;
    statSdfDropped = 0;
    statSdfMaxTilePairs = 0;
    statSdfDroppedPairs = 0;
  }

  final _SortedBubbleList bubbles = _SortedBubbleList();

  /// Bridges keyed by [_pairKey]; insertion-ordered like the former Set.
  final Map<int, _BubbleBridge> bridges = {};
  List<_MaskPoint> maskPoints = [];

  // Spatial grids rebuilt every tick; also used by the painter (positions don't change between
  // a tick and the following paint).
  final _SpatialGrid<_Bubble> bubbleGrid = _SpatialGrid(_kGridCellSize);
  final _SpatialGrid<_MaskPoint> spotGrid = _SpatialGrid(_kGridCellSize);
  double maxBubbleRadius = 0;
  double maxSpotRadius = 0;
  final List<_Bubble> _nearBubbles = [];

  static const double _kGridCellSize = 120;

  static int _pairKey(_Bubble a, _Bubble b) {
    // 2^26 ids per side keeps the key exact on the web (doubles, 53-bit integers).
    const shift = 1 << 26;
    return a.id < b.id ? a.id * shift + b.id : b.id * shift + a.id;
  }

  void init() {
    if (bubbles.isNotEmpty) return;

    updateSize(_canvasSize);
  }

  Size? _startChangeSize;

  void updateSize(Size size) {
    bool addBubblesForArea(Size sizeOld, Size size) {
      bool positionedInAddedArea(Offset p, Size oldSize, Size newSize) {
        final withinOldArea = p.dx <= oldSize.width && p.dy <= oldSize.height;
        if (withinOldArea) return false;

        final beyondAddedArea = p.dx > newSize.width || p.dy > newSize.height;
        if (beyondAddedArea) return false;

        return true;
      }

      void addMask(Offset offset) {
        maskPoints.add(_MaskPoint(offset, random: _random));
      }

      final dw = size.width - sizeOld.width;
      final dh = size.height - sizeOld.height;
      final rightArea = dw > 0 ? dw * size.height : 0;
      final bottomArea = dh > 0 ? dh * sizeOld.width : 0;
      final addedArea = rightArea + bottomArea;

      if (addedArea < _kPixelsPerOneBubble) {
        return false;
      }

      if (bubbles.any(
        (b) => positionedInAddedArea(b.position, sizeOld, size),
      )) {
        return true;
      }

      final bubbleCount = (addedArea / _kPixelsPerOneBubble).round();
      final newBubbles = <_Bubble>[];
      for (int i = 0; i < bubbleCount; i++) {
        double x, y;
        if (_random.nextDouble() * addedArea < rightArea) {
          x = sizeOld.width + _random.nextDouble() * dw;
          y = _random.nextDouble() * size.height;
        } else {
          x = _random.nextDouble() * sizeOld.width;
          y = sizeOld.height + _random.nextDouble() * dh;
        }
        newBubbles.add(_Bubble(random: _random, position: Offset(x, y)));
      }
      bubbles.addAll(newBubbles);

      if (maskPoints.any(
        (m) => positionedInAddedArea(m.position, sizeOld, size),
      )) {
        return true;
      }

      final maskPointCount = bubbleCount * 2;

      if (maskPointCount > 0) {
        if (sizeOld == Size.zero) {
          final portionSize = maskPointCount / 4;

          for (int i = 0; i < maskPointCount; i++) {
            final Offset offset;
            if (i < portionSize) {
              offset = Offset.zero;
            } else if (i < portionSize * 2) {
              offset = Offset(size.width, 0);
            } else if (i < portionSize * 3) {
              offset = Offset(0, size.height);
            } else {
              offset = Offset(size.width, size.height);
            }

            addMask(offset);
          }
        } else {
          final bottomAreaCount =
              maskPointCount * (bottomArea / (rightArea + bottomArea));
          final rightAreaCount =
              maskPointCount * (rightArea / (rightArea + bottomArea));

          final bottomLeftCornerCount = (bottomAreaCount / 2).round();
          final topRightCornerCount = (rightAreaCount / 2).round();
          final bottomRightCornerCount =
              maskPointCount - topRightCornerCount - bottomLeftCornerCount;

          void addMasksForOffset(Offset offset, int count) {
            for (int i = 0; i < count; i++) {
              addMask(offset);
            }
          }

          addMasksForOffset(Offset(size.width, 0), topRightCornerCount);
          addMasksForOffset(Offset(0, size.height), bottomLeftCornerCount);
          addMasksForOffset(
            Offset(size.width, size.height),
            bottomRightCornerCount,
          );
        }
      }

      return true;
    }

    // On the fly: if enough area accumulated, add bubbles and shift origin point
    if (addBubblesForArea(_startChangeSize ?? Size.zero, size)) {
      _startChangeSize = size;
    }

    if (_canvasSizeRaw != size) {
      _canvasSizeRaw = size;
      _canvasSizeUpdated = true;
    }
  }

  void onTick(double timeDelta) {
    bool isBubbleCoveredByLaterBubble(_Bubble b, _Bubble later) {
      if (later.radius <= b.radius) return false;

      final radDiff = later.radius - b.radius;
      final dx = (later.position.dx - b.position.dx).abs();
      if (dx > radDiff) return false;

      final dy = (later.position.dy - b.position.dy).abs();
      if (dy > radDiff) return false;

      return (b.position - later.position).distanceSquared <= radDiff * radDiff;
    }

    bool isGlowCoveredByLaterBubble(
      Offset glowCenter,
      double glowRadius,
      _Bubble later,
    ) {
      if (later.radius <= glowRadius) return false;

      final radDiff = later.radius - glowRadius;
      final dx = (later.position.dx - glowCenter.dx).abs();
      if (dx > radDiff) return false;

      final dy = (later.position.dy - glowCenter.dy).abs();
      if (dy > radDiff) return false;

      return (glowCenter - later.position).distanceSquared <= radDiff * radDiff;
    }

    /*bool isSpotCoveredByLaterBubble(_MaskPoint spot, _Bubble later) {
      if (later.radius <= spot.radius) return false;

      final radDiff = later.radius - spot.radius;
      final dx = (later.position.dx - spot.position.dx).abs();
      if (dx > radDiff) return false;

      final dy = (later.position.dy - spot.position.dy).abs();
      if (dy > radDiff) return false;

      return (spot.position - later.position).distanceSquared <=
          radDiff * radDiff;
    }

    bool isMaskOnBubbleCoveredByBubble(
      _Bubble b,
      _MaskPoint spot,
      _Bubble later,
    ) {
      final dSq = (spot.position - b.position).distanceSquared;
      if (dSq == 0) return false;

      final d = sqrt(dSq);
      final radiiDiff = (b.radius - spot.radius).abs();
      if (d >= b.radius + spot.radius || d <= radiiDiff) return false;

      // Calculate 2 key intersection points I1 and I2 of the lens
      final a =
          (b.radius * b.radius - spot.radius * spot.radius + dSq) / (2 * d);
      final hSq = b.radius * b.radius - a * a;

      final h = sqrt(hSq);

      final invD = 1.0 / d;
      final px = b.position.dx + a * (spot.position.dx - b.position.dx) * invD;
      final py = b.position.dy + a * (spot.position.dy - b.position.dy) * invD;

      final nx = -(spot.position.dy - b.position.dy) * invD;
      final ny = (spot.position.dx - b.position.dx) * invD;

      final i1 = Offset(px + h * nx, py + h * ny);
      late final i2 = Offset(px - h * nx, py - h * ny);

      final laterRadiusSq = later.radius * later.radius;

      // Check if both key points of the visible lens AND dome apex lie inside later bubble
      late final dirX = (spot.position.dx - b.position.dx) * invD;
      late final dirY = (spot.position.dy - b.position.dy) * invD;

      late final outerPoint = Offset(
        b.position.dx + dirX * b.radius,
        b.position.dy + dirY * b.radius,
      );

      return (i1 - later.position).distanceSquared <= laterRadiusSq &&
          (i2 - later.position).distanceSquared <= laterRadiusSq &&
          (outerPoint - later.position).distanceSquared <= laterRadiusSq;
    }

    bool isMaskCoveredByMask(
      Offset maskCenter,
      double maskRadius,
      _MaskPoint otherSpot,
    ) {
      if (!otherSpot.visible) return false;
      if (otherSpot.radius <= maskRadius) return false;

      final radDiff = otherSpot.radius - maskRadius;
      final dx = (otherSpot.position.dx - maskCenter.dx).abs();
      if (dx > radDiff) return false;

      final dy = (otherSpot.position.dy - maskCenter.dy).abs();
      if (dy > radDiff) return false;

      return (maskCenter - otherSpot.position).distanceSquared <=
          radDiff * radDiff;
    }*/

    final speedFactor = timeDelta * 150;

    double maxSpot = 0;
    spotGrid.reset(_canvasSize);
    for (int i = 0; i < maskPoints.length; i++) {
      final m = maskPoints[i];
      m.index = i;
      if (_canvasSizeUpdated || m.visible) {
        m.updateVisibility(_canvasSize);
      }
      if (m.visible) {
        m.update(_canvasSize, speedFactor);
        // Only visible spots are ever drawn.
        spotGrid.insert(m, m.position);
        maxSpot = max(maxSpot, m.radius);
      }
    }
    maxSpotRadius = maxSpot;

    // Visibility before movement, as before.
    for (int i = 0; i < bubbles.length; i++) {
      final b = bubbles[i];
      b.index = i;
      b.hasVisibleNeighbor = false;
      if (_canvasSizeUpdated || b.visible) {
        b.updateVisibility(_canvasSize);
      }
    }

    // One pass over bridges instead of scanning all bridges for every bubble.
    for (final br in bridges.values) {
      if (br.bubble2.visible) br.bubble1.hasVisibleNeighbor = true;
      if (br.bubble1.visible) br.bubble2.hasVisibleNeighbor = true;
    }

    for (int i = bubbles.length - 1; i >= 0; i--) {
      final b = bubbles[i];

      // Move bubble if it is visible OR connected via bridge to another VISIBLE bubble
      if (b.visible || b.hasVisibleNeighbor) {
        b.update(
          _canvasSize,
          speedFactor,
          forceMovement: !b.visible && b.hasVisibleNeighbor,
        );
      }
    }

    double maxBubble = 0;
    bubbleGrid.reset(_canvasSize);
    for (final b in bubbles) {
      bubbleGrid.insert(b, b.position);
      maxBubble = max(maxBubble, b.radius);
    }
    maxBubbleRadius = maxBubble;

    // Descending, so `later.needsDraw` already reflects this tick's coverage.
    for (int i = bubbles.length - 1; i >= 0; i--) {
      final b = bubbles[i];
      if (!b.visible) continue;

      // TODO: дублирование с paint
      final offset = b.radius * 0.2;
      final glowCenter = b.position - Offset(offset, offset);
      final glowRadius = b.radius * 0.8;

      // Same result as scanning later bubbles from the last one and stopping at the first that
      // covers the bubble or its glow: track the highest index for each condition.
      int coverIndex = -1;
      int glowIndex = -1;
      final near = bubbleGrid.query(
        b.position,
        maxBubble + offset * 1.5,
        _nearBubbles,
      );
      for (final later in near) {
        final j = later.index;
        if (j <= i || !later.needsDraw) continue;

        if (j > coverIndex && isBubbleCoveredByLaterBubble(b, later)) {
          coverIndex = j;
        }
        if (j > glowIndex &&
            isGlowCoveredByLaterBubble(glowCenter, glowRadius, later)) {
          glowIndex = j;
        }
      }

      final covered = coverIndex >= 0 && coverIndex >= glowIndex;
      final glowCovered = glowIndex > coverIndex;
      b.updateCovered(
        covered: covered ? true : null,
        glowCovered: glowCovered ? true : null,
      );
    }

    // TODO: Not effective enough for now, awaits for implementation of sections for objects, then maybe...
    /*for (int bubbleIdx = bubbles.length - 1; bubbleIdx >= 0; bubbleIdx--) {
      final b = bubbles[bubbleIdx];
      if (!b.needsDraw) continue;

      for (int maskIdx = maskPoints.length - 1; maskIdx >= 0; maskIdx--) {
        final m = maskPoints[maskIdx];
        if (!m.visible) continue;

        for (
          int laterBubbleIdx = bubbles.length - 1;
          laterBubbleIdx > bubbleIdx;
          laterBubbleIdx--
        ) {
          final laterB = bubbles[laterBubbleIdx];
          if (!laterB.needsDraw) continue;

          if (isMaskOnBubbleCoveredByBubble(b, m, laterB)) {
            m.coveredWithinBubble.add(b);
            break;
          }
        }

        if (m.covered(b)) continue;

        for (
          int laterMaskIdx = maskPoints.length - 1;
          laterMaskIdx > maskIdx;
          laterMaskIdx--
        ) {
          final otherSpot = maskPoints[laterMaskIdx];
          if (!otherSpot.visible) continue;

          if (isMaskCoveredByMask(m.position, m.radius, otherSpot)) {
            m.coveredWithinBubble.add(b);
            break;
          }
        }

        if (m.covered(b)) continue;
      }*/

    _updateBridges(maxBubble);

    notifyListeners();
    _canvasSizeUpdated = false;
  }

  void handleTap(Offset tapPos) {
    for (int i = bubbles.length - 1; i >= 0; i--) {
      final b = bubbles[i];
      if ((b.position - tapPos).distanceSquared <= b.radius * b.radius) {
        _split(b, tapPos);
        break;
      }
    }
  }

  /// Connects touching visible bubbles and disconnects stretched-out bridges.
  ///
  /// Same rules as checking every pair, but new bridges are searched only among grid neighbors
  /// (touching bubbles are at most `2 * maxRadius` apart) and existing ones are checked directly,
  /// with no temporary objects.
  void _updateBridges(double maxRadius) {
    double getDisconnectBridgeLength(_Bubble b1, _Bubble b2) {
      // TODO: The scientific formula is there, but the drawing of the bridge is not perfect using it yet.
      //(2 * b1.radius * b2.radius) / (b1.radius + b2.radius);
      return (b1.radius * b2.radius) / (b1.radius + b2.radius) / 3;
    }

    bridges.removeWhere((_, bridge) {
      final b1 = bridge.bubble1;
      final b2 = bridge.bubble2;
      if (!b1.visible || !b2.visible) return false;

      final distSquared = (b1.position - b2.position).distanceSquared;
      final effectiveDisconnectBridgeLength =
          b1.radius + b2.radius + getDisconnectBridgeLength(b1, b2);
      return distSquared >
          effectiveDisconnectBridgeLength * effectiveDisconnectBridgeLength;
    });

    for (final b1 in bubbles) {
      if (!b1.visible) continue;

      final near = bubbleGrid.query(
        b1.position,
        b1.radius + maxRadius,
        _nearBubbles,
      );
      for (final b2 in near) {
        // Each pair once, with bubble1 being the earlier one (as with the pairwise loop).
        if (b2.index <= b1.index || !b2.visible) continue;

        final distSquared = (b1.position - b2.position).distanceSquared;
        final radiiSum = b1.radius + b2.radius;
        if (distSquared < radiiSum * radiiSum) {
          final key = _pairKey(b1, b2);
          if (!bridges.containsKey(key)) {
            bridges[key] = _BubbleBridge(bubble1: b1, bubble2: b2);
          }
        }
      }
    }
  }

  void _split(_Bubble parent, Offset tapPoint) {
    // New radius (preserves half of the original area)
    final newRad = parent.targetRadius * 0.7;

    _removeBubble(parent);

    if (newRad >= 15) {
      // Add two bubbles at click position:
      // one moves along velocity direction, the other in opposite direction
      bubbles.addAll([
        _Bubble(
          random: _random,
          position: tapPoint,
          velocity: parent.velocity,
          targetRadius: newRad,
        ),
        _Bubble(
          random: _random,
          position: tapPoint,
          velocity: -parent.velocity,
          targetRadius: newRad,
        ),
      ]);
    }
  }

  void _removeBubble(_Bubble bubble) {
    bubbles.remove(bubble);
    bridges.removeWhere(
      (_, bridge) => bridge.bubble1 == bubble || bridge.bubble2 == bubble,
    );
  }
}

class _SortedBubbleList with ListMixin<_Bubble> {
  final List<_Bubble> _inner = [];

  @override
  int get length => _inner.length;

  @override
  set length(int newLength) {
    _inner.length = newLength;
    _sort();
  }

  @override
  _Bubble operator [](int index) => _inner[index];

  @override
  void operator []=(int index, _Bubble value) {
    _inner[index] = value;
    _sort();
  }

  @override
  void add(_Bubble element) {
    _inner.add(element);
    _sort();
  }

  @override
  void addAll(Iterable<_Bubble> iterable) {
    _inner.addAll(iterable);
    _sort();
  }

  @override
  void insert(int index, _Bubble element) {
    _inner.insert(index, element);
    _sort();
  }

  void _sort() {
    _inner.sort((a, b) => a.targetRadius.compareTo(b.targetRadius));
  }
}
