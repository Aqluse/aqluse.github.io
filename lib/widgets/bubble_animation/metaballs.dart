part of 'liquid_bubbles.dart';

/// Smooth-min distance (logical px). Shape fusion: bubbles closer than this grow a neck towards
/// each other. Also the culling margin and the color weight cutoff.
const double _kSdfSmoothing = 24;

/// Width (logical px) of the color cross-fade between fusing bubbles (necks): weights are
/// exp(-distance / fade).
const double _kSdfColorFade = 5;

/// Width (logical px) of the color transition across the top bubble's edge.
const double _kSdfEdgeFade = 2.75;

/// How deep inside a bubble (logical px) its color weight keeps growing.
const double _kSdfDepthClamp = 72;

/// Edge anti-aliasing width in physical pixels.
const double _kSdfAaWidth = 1;

/// Stacking strength: inside bubbles the top bubble (the old renderer's order: later in the
/// sorted list = on top) gives surface, mask and glow, with a soft transition across its edge;
/// lower bubbles show through by 1 - strength. Necks outside all bubbles use the weighted
/// blend.
const double _kSdfStacking = 0.95;

/// Spot alpha (before mask opacity) at [distance] from the center of a spot with [radius]: the
/// original gradient, solid up to 5% of the radius, then a linear fade. Must match spotKeep()
/// in shaders/metaballs.frag.
double _spotAlphaAt(double distance, double radius) =>
    1 - ((distance / radius - 0.05) / 0.95).clamp(0.0, 1.0);

/// Top-level tile size (logical px).
const double _kSdfTileSize = 256;

/// How many times an overflowing tile may be split into 4 (256 -> 128 -> 64 -> 32 -> 16).
const int _kSdfMaxSplitDepth = 4;

/// Capacities; must match kMaxEventPairs * 2 / kMaxSpotGroups * 4 in shaders/metaballs.frag.
///
/// An event is one bubble: drawn, or only made the current lower bubble (for necks whose lower
/// bubble isn't in the tile), or a neck partner of the current lower bubble (see the shader).
/// A tile needs one event per bubble, one per neck and one per lower bubble of a neck that
/// isn't in the tile.
const int _kSdfMaxEvents = 80;
const int _kSdfMaxSpots = 128;

// Float offsets of the uniforms in shaders/metaballs.frag.
const int _kSdfEventsABase = 8;
const int _kSdfEventsBBase = _kSdfEventsABase + _kSdfMaxEvents ~/ 2 * 4;
const int _kSdfEventsCBase = _kSdfEventsBBase + _kSdfMaxEvents ~/ 2 * 4;
const int _kSdfSpotsABase = _kSdfEventsCBase + _kSdfMaxEvents ~/ 2 * 4;
const int _kSdfSpotsBBase = _kSdfSpotsABase + _kSdfMaxSpots ~/ 4 * 4;
const int _kSdfSpotsCBase = _kSdfSpotsBBase + _kSdfMaxSpots ~/ 4 * 4;

// Event kinds, encoded in the event's w with the bubble's opacity o (see the shader).
const int _kSdfEventDraw = 0; // w = o
const int _kSdfEventLowerOnly = 1; // w = -1 - o
const int _kSdfEventNeck = 2; // w = 2 + o

/// Once the guaranteed remaining transparency of a tile's mask drops below this, further spots
/// can't change the 8-bit output and are skipped.
const double _kSdfSaturatedKeep = 1 / 512;

/// Once bubbles stacked above something leave at most this much of it visible (stacking
/// strength < 1 lets lower layers show through), it can't change the 8-bit output and is
/// skipped (hidden necks and bubbles).
const double _kSdfOccludedKeep = 1 / 1024;

/// Squared distance from (x, y) to the nearest point of the rect.
double _rectDistSq(
  double x,
  double y,
  double left,
  double top,
  double right,
  double bottom,
) {
  final dx = x < left ? left - x : (x > right ? x - right : 0.0);
  final dy = y < top ? top - y : (y > bottom ? y - bottom : 0.0);
  return dx * dx + dy * dy;
}

/// Squared distance from (x, y) to the farthest corner of the rect.
double _farRectDistSq(
  double x,
  double y,
  double left,
  double top,
  double right,
  double bottom,
) {
  final dx = max((x - left).abs(), (x - right).abs());
  final dy = max((y - top).abs(), (y - bottom).abs());
  return dx * dx + dy * dy;
}

/// Two fusing bubbles (center distance < r1 + r2 + k): the area their smooth union adds to the
/// two shapes (the neck) is drawn at the lower bubble's layer. Reused across frames.
///
/// Where the neck can be: with edge width e, its coverage is
/// cov(smin(d1, d2)) - cov(min(d1, d2)) > 0 only if both distances are in (-e/2, k + e/2),
/// the smaller one is below k/4 + e/2, and |d1 - d2| < k. Its bounds are one or two
/// axis-aligned boxes (two when the region splits into the parts near the two circle
/// crossings, on both sides of the line through the centers).
class _SdfPair {
  late _Bubble lower;
  late _Bubble upper;

  /// Position in the frame's pair list when created (tie-breaker of the layer order).
  int order = 0;

  /// Number of valid boxes (0 = no neck at all).
  int boxCount = 0;
  double ax0 = 0, ay0 = 0, ax1 = 0, ay1 = 0;
  double bx0 = 0, by0 = 0, bx1 = 0, by1 = 0;

  /// Scratch sort key for overflow handling.
  double sortKey = 0;

  // Scratch result of _part: x range along the axis, |y| range off it (local frame).
  double _x0 = 0, _x1 = 0, _y0 = 0, _y1 = 0;

  // Bounds of all boxes.
  double get minX => boxCount == 2 ? min(ax0, bx0) : ax0;
  double get minY => boxCount == 2 ? min(ay0, by0) : ay0;
  double get maxX => boxCount == 2 ? max(ax1, bx1) : ax1;
  double get maxY => boxCount == 2 ? max(ay1, by1) : ay1;

  /// Whether a box overlaps the rect.
  bool hitsRect(double left, double top, double right, double bottom) =>
      _boxHitsRect(ax0, ay0, ax1, ay1, left, top, right, bottom) ||
      (boxCount == 2 &&
          _boxHitsRect(bx0, by0, bx1, by1, left, top, right, bottom));

  /// Whether every box lies inside the circle.
  bool insideCircle(double x, double y, double radius) =>
      _farRectDistSq(x, y, ax0, ay0, ax1, ay1) <= radius * radius &&
      (boxCount != 2 ||
          _farRectDistSq(x, y, bx0, by0, bx1, by1) <= radius * radius);

  /// Distance from (x, y) to the nearest box.
  double distanceTo(double x, double y) {
    final a = _rectDistSq(x, y, ax0, ay0, ax1, ay1);
    return sqrt(
      boxCount == 2 ? min(a, _rectDistSq(x, y, bx0, by0, bx1, by1)) : a,
    );
  }

  static bool _boxHitsRect(
    double x0,
    double y0,
    double x1,
    double y1,
    double left,
    double top,
    double right,
    double bottom,
  ) => x0 <= right && x1 >= left && y0 <= bottom && y1 >= top;

  /// Computes the bounds; [depth] = e/2, [near] = k/4 + e/2, [reach] = k + e/2.
  void set(
    _Bubble lower,
    _Bubble upper,
    int order,
    double depth,
    double near,
    double reach,
  ) {
    this.lower = lower;
    this.upper = upper;
    this.order = order;
    final ox = lower.position.dx;
    final oy = lower.position.dy;
    final dx = upper.position.dx - ox;
    final dy = upper.position.dy - oy;
    final dist = sqrt(dx * dx + dy * dy);
    final lMin = max(lower.radius - depth, 0.0);
    final lMax = lower.radius + reach;
    final uMin = max(upper.radius - depth, 0.0);
    final uMax = upper.radius + reach;
    if (dist < 0.5) {
      // (Nearly) concentric: no useful frame; the lower bubble's outer circle bounds it.
      boxCount = 1;
      ax0 = ox - lMax;
      ay0 = oy - lMax;
      ax1 = ox + lMax;
      ay1 = oy + lMax;
      return;
    }

    // Two parts: near the lower circle (d1 < near) and near the upper one (d2 < near).
    double x0 = double.infinity, x1 = -double.infinity;
    double y0 = double.infinity, y1 = -double.infinity;
    bool any = false;
    bool split = true;
    for (int part = 0; part < 2; part++) {
      final ok = part == 0
          ? _part(dist, lMin, lower.radius + near, uMin, uMax)
          : _part(dist, lMin, lMax, uMin, upper.radius + near);
      if (!ok) continue;
      any = true;
      x0 = min(x0, _x0);
      x1 = max(x1, _x1);
      y0 = min(y0, _y0);
      y1 = max(y1, _y1);
      if (_y0 <= 0) split = false;
    }
    if (!any) {
      boxCount = 0;
      return;
    }

    // Local frame: x along lower -> upper, y to the left of it.
    final ex = dx / dist;
    final ey = dy / dist;
    if (split) {
      boxCount = 2;
      _toWorld(ox, oy, ex, ey, x0, x1, y0, y1);
      ax0 = _x0;
      ay0 = _y0;
      ax1 = _x1;
      ay1 = _y1;
      _toWorld(ox, oy, ex, ey, x0, x1, -y1, -y0);
      bx0 = _x0;
      by0 = _y0;
      bx1 = _x1;
      by1 = _y1;
    } else {
      boxCount = 1;
      _toWorld(ox, oy, ex, ey, x0, x1, -y1, y1);
      ax0 = _x0;
      ay0 = _y0;
      ax1 = _x1;
      ay1 = _y1;
    }
  }

  /// World AABB (into _x0, _y0, _x1, _y1) of the local box [x0, x1] x [y0, y1].
  void _toWorld(
    double ox,
    double oy,
    double ex,
    double ey,
    double x0,
    double x1,
    double y0,
    double y1,
  ) {
    final xm = (x0 + x1) / 2;
    final ym = (y0 + y1) / 2;
    final hx = (x1 - x0) / 2;
    final hy = (y1 - y0) / 2;
    // Local y axis is (-ey, ex).
    final cx = ox + ex * xm - ey * ym;
    final cy = oy + ey * xm + ex * ym;
    final wx = ex.abs() * hx + ey.abs() * hy;
    final wy = ey.abs() * hx + ex.abs() * hy;
    _x0 = cx - wx;
    _x1 = cx + wx;
    _y0 = cy - wy;
    _y1 = cy + wy;
  }

  /// Local bounds of the points whose distance from the lower center is in [l0, l1] and from
  /// the upper center in [u0, u1], centers [dist] apart. With s, t the squared distances,
  /// x = (dist^2 + s - t) / (2 dist) is linear and y^2 = g(s, t) / (4 dist^2) with g concave, so
  /// x and the smallest |y| are found at the corners of the (s, t) rectangle and the largest
  /// |y| at the corners or the one stationary point. Returns false if no such point exists.
  bool _part(double dist, double l0, double l1, double u0, double u1) {
    final d2 = dist * dist;
    final inv = 1 / (2 * dist);
    final s0 = l0 * l0, s1 = l1 * l1, t0 = u0 * u0, t1 = u1 * u1;
    _x0 = max((d2 + s0 - t1) * inv, max(-l1, dist - u1));
    _x1 = min((d2 + s1 - t0) * inv, min(l1, dist + u1));
    final gMin = min(
      min(_g(d2, s0, t0), _g(d2, s0, t1)),
      min(_g(d2, s1, t0), _g(d2, s1, t1)),
    );
    final gMax = max(
      max(_gBest(d2, s0, t0, t1), _gBest(d2, s1, t0, t1)),
      _gBest(d2, (t1 + d2).clamp(s0, s1), t0, t1),
    );
    if (gMax <= 0 || _x0 > _x1) return false;
    _y0 = gMin > 0 ? sqrt(gMin) * inv : 0;
    _y1 = min(sqrt(gMax) * inv, min(l1, u1));
    return true;
  }

  static double _g(double d2, double s, double t) {
    final m = d2 + s - t;
    return 4 * d2 * s - m * m;
  }

  /// max of g over t in [t0, t1] for this s.
  static double _gBest(double d2, double s, double t0, double t1) =>
      _g(d2, s, (d2 + s).clamp(t0, t1));
}

/// Draws all bubbles as one smooth union per screen tile: one draw call per non-empty tile.
///
/// Layered necks: the shader stacks bubbles bottom to top, and the neck of each fusing pair is
/// stacked right above the pair's lower bubble, so it stays visible over every bubble below
/// both, while bubbles above the lower one (including the upper one) cover it. Per tile the
/// bubbles and pairs are merged into one bottom-to-top event list (see shaders/metaballs.frag).
class _MetaballRenderer {
  _MetaballRenderer(this.program);

  final ui.FragmentProgram program;

  /// How many bubbles fully covering something hide it: after that many, at most
  /// _kSdfOccludedKeep of it can show through.
  static final int _coversToHide = () {
    int covers = 0;
    double keep = 1;
    while (keep >= _kSdfOccludedKeep && covers < 64) {
      keep *= 1 - _kSdfStacking;
      covers++;
    }
    return covers;
  }();

  // One shader instance per drawn tile, reused across frames, so uniforms of different tiles
  // never share an instance within a frame.
  final List<ui.FragmentShader> _shaders = [];
  final Paint _paint = Paint()..isAntiAlias = false;
  int _shaderIndex = 0;

  double _pixelSize = 1;

  // Grid candidates of a top-level tile, then one list per split depth (reused).
  final List<_Bubble> _rootBubbles = [];
  final List<_MaskPoint> _rootSpots = [];
  final List<List<_Bubble>> _tileBubbles = List.generate(
    _kSdfMaxSplitDepth + 1,
    (_) => <_Bubble>[],
  );
  final List<List<_MaskPoint>> _tileSpots = List.generate(
    _kSdfMaxSplitDepth + 1,
    (_) => <_MaskPoint>[],
  );

  // Fusing pairs of the frame ordered by the lower bubble's index (objects from the pool),
  // binned per top-level tile, then one list per split depth (all reused).
  final List<_SdfPair> _pairPool = [];
  final List<_SdfPair> _framePairs = [];
  final List<_Bubble> _nearBubbles = [];
  final List<List<_SdfPair>> _rootPairs = [];
  final List<List<_SdfPair>> _tilePairs = List.generate(
    _kSdfMaxSplitDepth + 1,
    (_) => <_SdfPair>[],
  );

  // Floats of one spot group (4 spots as x, y, radius), see _emitTile.
  final List<double> _spotGroup = List.filled(12, 0);

  // Stacking edge width (same as the shader's) and the neck distance limits (see _SdfPair).
  double _edge = 1;
  double _neckDepth = 0;
  double _neckNear = 0;
  double _neckReach = 0;

  // Stamps for _Bubble.sdfMark (strictly increasing, so stale marks never match).
  int _markStamp = 0;

  void paint(
    Canvas canvas,
    Size size,
    _PaintManager manager,
    double pixelSize,
  ) {
    _pixelSize = pixelSize;
    _shaderIndex = 0;

    final w = size.width;
    final h = size.height;
    final bubbleReach = manager.maxBubbleRadius + _kSdfSmoothing;
    final spotReach = manager.maxSpotRadius;
    final cols = (w / _kSdfTileSize).ceil();
    final rows = (h / _kSdfTileSize).ceil();

    _edge = max(_kSdfEdgeFade, pixelSize * _kSdfAaWidth);
    _neckDepth = _edge / 2;
    _neckNear = _kSdfSmoothing / 4 + _edge / 2;
    _neckReach = _kSdfSmoothing + _edge / 2;
    _buildPairs(manager);
    _binPairs(cols, rows);

    for (int row = 0; row < rows; row++) {
      final top = row * _kSdfTileSize;
      final bottom = min(top + _kSdfTileSize, h);
      for (int col = 0; col < cols; col++) {
        final left = col * _kSdfTileSize;
        final right = min(left + _kSdfTileSize, w);
        manager.bubbleGrid.queryBounds(
          left - bubbleReach,
          top - bubbleReach,
          right + bubbleReach,
          bottom + bubbleReach,
          _rootBubbles,
        );
        if (_rootBubbles.isEmpty) continue;
        // Stacking needs bottom-to-top order; sub-tiles keep it while filtering.
        _rootBubbles.sort(_compareBubbleIndex);
        manager.spotGrid.queryBounds(
          left - spotReach,
          top - spotReach,
          right + spotReach,
          bottom + spotReach,
          _rootSpots,
        );
        _drawTile(
          canvas,
          left,
          top,
          right,
          bottom,
          0,
          _rootBubbles,
          _rootSpots,
          _rootPairs[row * cols + col],
        );
      }
    }
  }

  /// Collects every fusing pair (center distance < r1 + r2 + k) with a neck that isn't hidden
  /// by higher bubbles into [_framePairs], ordered by the lower bubble's index.
  void _buildPairs(_PaintManager manager) {
    _framePairs.clear();

    final k = _kSdfSmoothing;
    final bubbles = manager.bubbles;
    // Enough for the partners and for every bubble that can cover a neck point (within
    // lower radius + k + e/2 of the lower center).
    final reach = manager.maxBubbleRadius + k + _edge;
    int used = 0;
    bool ordered = true;
    int lastLower = -1;
    for (int l = 0; l < bubbles.length; l++) {
      final lower = bubbles[l];
      final lx = lower.position.dx;
      final ly = lower.position.dy;
      final queryRadius = lower.radius + reach;
      manager.bubbleGrid.queryBounds(
        lx - queryRadius,
        ly - queryRadius,
        lx + queryRadius,
        ly + queryRadius,
        _nearBubbles,
      );
      for (int n = 0; n < _nearBubbles.length; n++) {
        final upper = _nearBubbles[n];
        if (upper.index <= lower.index) continue;
        final dx = upper.position.dx - lx;
        final dy = upper.position.dy - ly;
        final fuse = upper.radius + lower.radius + k;
        if (dx * dx + dy * dy >= fuse * fuse) continue;

        if (used == _pairPool.length) _pairPool.add(_SdfPair());
        final pair = _pairPool[used]
          ..set(
            lower,
            upper,
            _framePairs.length,
            _neckDepth,
            _neckNear,
            _neckReach,
          );
        if (pair.boxCount == 0 || _isOccluded(pair)) continue;
        used++;
        _framePairs.add(pair);
        if (lower.index < lastLower) ordered = false;
        lastLower = lower.index;
      }
    }
    // Bubble indexes normally equal list positions, so this is a fallback only.
    if (!ordered) _framePairs.sort(_comparePairOrder);
  }

  /// Radius of the circle inside [b] where it covers fully (its stacking edge is e/2 wide
  /// inside), or <= 0.
  double _coverRadius(_Bubble b) => b.radius - _edge / 2;

  /// Whether enough bubbles above the pair's lower bubble (candidates in [_nearBubbles]) each
  /// fully cover the neck's bounds to hide it (see _coversToHide).
  bool _isOccluded(_SdfPair q) {
    int covers = 0;
    for (int n = 0; n < _nearBubbles.length; n++) {
      final c = _nearBubbles[n];
      if (c.index <= q.lower.index) continue;
      final inner = _coverRadius(c);
      if (inner <= 0 || !q.insideCircle(c.position.dx, c.position.dy, inner)) {
        continue;
      }
      if (++covers >= _coversToHide) return true;
    }
    return false;
  }

  /// Index of the lowest of the bubbles that fully cover the rect from the top down until they
  /// hide what's below them (see _coversToHide), or -1. [bubbles] are in layer order.
  int _occlusionThreshold(
    List<_Bubble> bubbles,
    double left,
    double top,
    double right,
    double bottom,
  ) {
    int covers = 0;
    for (int k = bubbles.length - 1; k >= 0; k--) {
      final b = bubbles[k];
      final inner = _coverRadius(b);
      if (inner <= 0 ||
          _farRectDistSq(
                b.position.dx,
                b.position.dy,
                left,
                top,
                right,
                bottom,
              ) >
              inner * inner) {
        continue;
      }
      if (++covers >= _coversToHide) return b.index;
    }
    return -1;
  }

  /// Distributes [_framePairs] to the top-level tiles their bounds overlap; _drawTile then
  /// filters them exactly.
  void _binPairs(int cols, int rows) {
    final tileCount = cols * rows;
    while (_rootPairs.length < tileCount) {
      _rootPairs.add(<_SdfPair>[]);
    }
    for (int t = 0; t < tileCount; t++) {
      _rootPairs[t].clear();
    }
    if (tileCount == 0) return;

    for (int n = 0; n < _framePairs.length; n++) {
      final q = _framePairs[n];
      final c0 = (q.minX / _kSdfTileSize).floor().clamp(0, cols - 1);
      final c1 = (q.maxX / _kSdfTileSize).floor().clamp(0, cols - 1);
      final r0 = (q.minY / _kSdfTileSize).floor().clamp(0, rows - 1);
      final r1 = (q.maxY / _kSdfTileSize).floor().clamp(0, rows - 1);
      for (int row = r0; row <= r1; row++) {
        for (int col = c0; col <= c1; col++) {
          _rootPairs[row * cols + col].add(q);
        }
      }
    }
  }

  static bool _circleHitsRect(
    double cx,
    double cy,
    double radius,
    double left,
    double top,
    double right,
    double bottom,
  ) => _rectDistSq(cx, cy, left, top, right, bottom) <= radius * radius;

  // Scratch result of _distanceRange.
  double _rangeMin = 0;
  double _rangeMax = 0;

  /// Range of signed distances from [b]'s circle over the rect (into _rangeMin, _rangeMax).
  void _distanceRange(
    _Bubble b,
    double left,
    double top,
    double right,
    double bottom,
  ) {
    final cx = b.position.dx;
    final cy = b.position.dy;
    _rangeMin = sqrt(_rectDistSq(cx, cy, left, top, right, bottom)) - b.radius;
    _rangeMax =
        sqrt(_farRectDistSq(cx, cy, left, top, right, bottom)) - b.radius;
  }

  static double _gap(double a0, double a1, double b0, double b1) =>
      max(0.0, max(a0 - b1, b0 - a1));

  /// Conservative test whether the neck of [q] can touch the rect: its bounds hit the rect,
  /// and the distance ranges of the rect allow a neck point (see _SdfPair).
  bool _pairHitsRect(
    _SdfPair q,
    double left,
    double top,
    double right,
    double bottom,
  ) {
    if (!q.hitsRect(left, top, right, bottom)) return false;
    _distanceRange(q.lower, left, top, right, bottom);
    final l0 = max(_rangeMin, -_neckDepth);
    final l1 = min(_rangeMax, _neckReach);
    if (l0 > l1) return false;
    _distanceRange(q.upper, left, top, right, bottom);
    final u0 = max(_rangeMin, -_neckDepth);
    final u1 = min(_rangeMax, _neckReach);
    if (u0 > u1) return false;
    final k = _kSdfSmoothing;
    // The smaller distance is below near and the two differ by less than k.
    final lNear = min(l1, _neckNear);
    if (l0 <= lNear && _gap(l0, lNear, u0, u1) <= k) return true;
    final uNear = min(u1, _neckNear);
    return u0 <= uNear && _gap(l0, l1, u0, uNear) <= k;
  }

  void _drawTile(
    Canvas canvas,
    double left,
    double top,
    double right,
    double bottom,
    int depth,
    List<_Bubble> sourceBubbles,
    List<_MaskPoint> sourceSpots,
    List<_SdfPair> sourcePairs,
  ) {
    final tileBubbles = _tileBubbles[depth]..clear();
    for (int k = 0; k < sourceBubbles.length; k++) {
      final b = sourceBubbles[k];
      if (_circleHitsRect(
        b.position.dx,
        b.position.dy,
        b.radius + _kSdfSmoothing,
        left,
        top,
        right,
        bottom,
      )) {
        tileBubbles.add(b);
      }
    }
    if (tileBubbles.isEmpty) return;

    final tileSpots = _tileSpots[depth]..clear();
    for (int k = 0; k < sourceSpots.length; k++) {
      final s = sourceSpots[k];
      if (_circleHitsRect(
        s.position.dx,
        s.position.dy,
        s.radius,
        left,
        top,
        right,
        bottom,
      )) {
        tileSpots.add(s);
      }
    }

    // Filtering keeps the layer order of the pairs.
    final tilePairs = _tilePairs[depth]..clear();
    for (int k = 0; k < sourcePairs.length; k++) {
      final q = sourcePairs[k];
      if (_pairHitsRect(q, left, top, right, bottom)) tilePairs.add(q);
    }

    // Bubbles fully covering the tile hide everything below them: drop those bubbles and the
    // necks stacked under them (both lists are in layer order, so these are prefixes). The
    // silhouette is unaffected: the covering bubbles keep the whole tile inside it.
    final threshold = _occlusionThreshold(
      tileBubbles,
      left,
      top,
      right,
      bottom,
    );
    if (threshold >= 0) {
      int nb = 0;
      while (nb < tileBubbles.length && tileBubbles[nb].index < threshold) {
        nb++;
      }
      tileBubbles.removeRange(0, nb);
      int np = 0;
      while (np < tilePairs.length && tilePairs[np].lower.index < threshold) {
        np++;
      }
      tilePairs.removeRange(0, np);
    }

    if (tileSpots.length > _kSdfMaxSpots) {
      _cullSaturatedSpots(tileSpots, left, top, right, bottom);
    }

    final overflow =
        _writeEvents(tileBubbles, tilePairs, null) > _kSdfMaxEvents ||
        tileSpots.length > _kSdfMaxSpots;

    if (overflow && depth < _kSdfMaxSplitDepth) {
      final midX = (left + right) / 2;
      final midY = (top + bottom) / 2;
      final next = depth + 1;
      _drawTile(
        canvas,
        left,
        top,
        midX,
        midY,
        next,
        tileBubbles,
        tileSpots,
        tilePairs,
      );
      _drawTile(
        canvas,
        midX,
        top,
        right,
        midY,
        next,
        tileBubbles,
        tileSpots,
        tilePairs,
      );
      _drawTile(
        canvas,
        left,
        midY,
        midX,
        bottom,
        next,
        tileBubbles,
        tileSpots,
        tilePairs,
      );
      _drawTile(
        canvas,
        midX,
        midY,
        right,
        bottom,
        next,
        tileBubbles,
        tileSpots,
        tilePairs,
      );
      return;
    }

    if (overflow) {
      // Smallest tile and still too many objects: keep the nearest bubbles, then the nearest
      // necks that still fit, and the strongest spots (already sorted by the saturation
      // culling).
      if (tileBubbles.length > _kSdfMaxEvents) {
        final cx = (left + right) / 2;
        final cy = (top + bottom) / 2;
        for (int k = 0; k < tileBubbles.length; k++) {
          final b = tileBubbles[k];
          final dx = b.position.dx - cx;
          final dy = b.position.dy - cy;
          b.sortKey = sqrt(dx * dx + dy * dy) - b.radius;
        }
        tileBubbles.sort(_compareBubbleKeyAscending);
        tileBubbles.length = _kSdfMaxEvents;
        tileBubbles.sort(_compareBubbleIndex);
      }
      if (_writeEvents(tileBubbles, tilePairs, null) > _kSdfMaxEvents) {
        _trimPairs(tileBubbles, tilePairs, left, top, right, bottom);
      }
      if (tileSpots.length > _kSdfMaxSpots) {
        tileSpots.length = _kSdfMaxSpots;
      }
    }

    _emitTile(
      canvas,
      left,
      top,
      right,
      bottom,
      tileBubbles,
      tileSpots,
      tilePairs,
    );
  }

  static int _compareBubbleIndex(_Bubble a, _Bubble b) =>
      a.index.compareTo(b.index);

  static int _compareBubbleKeyAscending(_Bubble a, _Bubble b) =>
      a.sortKey.compareTo(b.sortKey);

  static int _compareSpotKeyDescending(_MaskPoint a, _MaskPoint b) =>
      b.sortKey.compareTo(a.sortKey);

  static int _comparePairKeyAscending(_SdfPair a, _SdfPair b) =>
      a.sortKey.compareTo(b.sortKey);

  /// Layer order of the necks: by the lower bubble, then by creation.
  static int _comparePairOrder(_SdfPair a, _SdfPair b) {
    final byLower = a.lower.index.compareTo(b.lower.index);
    return byLower != 0 ? byLower : a.order.compareTo(b.order);
  }

  /// Keeps the necks nearest to the tile center that fit into the event capacity next to
  /// [bubbles] (at most _kSdfMaxEvents of them), in layer order.
  void _trimPairs(
    List<_Bubble> bubbles,
    List<_SdfPair> pairs,
    double left,
    double top,
    double right,
    double bottom,
  ) {
    final cx = (left + right) / 2;
    final cy = (top + bottom) / 2;
    for (int k = 0; k < pairs.length; k++) {
      final q = pairs[k];
      q.sortKey = q.distanceTo(cx, cy);
    }
    pairs.sort(_comparePairKeyAscending);

    // A neck costs one event, plus one for its lower bubble if that isn't in the tile and no
    // kept neck has paid for it yet.
    final inTile = ++_markStamp;
    final paid = ++_markStamp;
    for (int k = 0; k < bubbles.length; k++) {
      bubbles[k].sdfMark = inTile;
    }
    int events = bubbles.length;
    int kept = 0;
    for (int k = 0; k < pairs.length; k++) {
      final q = pairs[k];
      final mark = q.lower.sdfMark;
      final lowerCost = mark == inTile || mark == paid ? 0 : 1;
      if (events + 1 + lowerCost > _kSdfMaxEvents) continue;
      events += 1 + lowerCost;
      if (lowerCost == 1) q.lower.sdfMark = paid;
      pairs[kept++] = q;
    }
    pairs.length = kept;
    pairs.sort(_comparePairOrder);
  }

  /// Merges [bubbles] and [pairs] (both in layer order) into the bottom-to-top event list:
  /// each bubble is drawn, then followed by its necks to higher bubbles; necks whose lower
  /// bubble isn't in the tile are preceded by that bubble as an undrawn current lower bubble.
  /// Writes the events into [shader] if given (padded to an even count); returns their count.
  int _writeEvents(
    List<_Bubble> bubbles,
    List<_SdfPair> pairs,
    ui.FragmentShader? shader,
  ) {
    int events = 0;
    int p = 0;
    _Bubble? current;
    for (int k = 0; k <= bubbles.length; k++) {
      final b = k < bubbles.length ? bubbles[k] : null;
      // Necks of lower bubbles not in the tile (all remaining ones after the last bubble).
      while (p < pairs.length &&
          (b == null || pairs[p].lower.index < b.index)) {
        final q = pairs[p++];
        if (!identical(current, q.lower)) {
          current = q.lower;
          _setEvent(shader, events++, current, _kSdfEventLowerOnly);
        }
        _setEvent(shader, events++, q.upper, _kSdfEventNeck);
      }
      if (b == null) break;
      current = b;
      _setEvent(shader, events++, b, _kSdfEventDraw);
      while (p < pairs.length && identical(pairs[p].lower, b)) {
        _setEvent(shader, events++, pairs[p++].upper, _kSdfEventNeck);
      }
    }
    if (shader != null && events.isOdd) {
      // Padding: a neck with a far away, zero radius bubble adds nothing.
      _writeEvent(shader, events, -100000, -100000, 0, 2, 0, 0);
    }
    return events;
  }

  /// Event [slot] (see the shader): [b] with [kind] encoded in w with its opacity.
  void _setEvent(ui.FragmentShader? shader, int slot, _Bubble b, int kind) {
    if (shader == null) return;
    final o = max(0.0, b.opacity);
    _writeEvent(
      shader,
      slot,
      b.position.dx,
      b.position.dy,
      b.radius,
      kind == _kSdfEventDraw
          ? o
          : (kind == _kSdfEventLowerOnly ? -1 - o : 2 + o),
      _packRgb(b.color),
      _packRgb(b.colorMask),
    );
  }

  /// Writes the floats of event [slot]: events go in pairs (A, B) with their colors in C.
  static void _writeEvent(
    ui.FragmentShader shader,
    int slot,
    double x,
    double y,
    double radius,
    double w,
    double surface,
    double mask,
  ) {
    final pair = slot ~/ 2;
    final odd = slot.isOdd;
    final base = (odd ? _kSdfEventsBBase : _kSdfEventsABase) + pair * 4;
    final colorBase = _kSdfEventsCBase + pair * 4 + (odd ? 2 : 0);
    shader
      ..setFloat(base, x)
      ..setFloat(base + 1, y)
      ..setFloat(base + 2, radius)
      ..setFloat(base + 3, w)
      ..setFloat(colorBase, surface)
      ..setFloat(colorBase + 1, mask);
  }

  /// Sorts [spots] by the alpha each one is guaranteed to have everywhere in the tile
  /// (strongest first) and drops the tail once the strongest ones already make the mask opaque
  /// in the whole tile: the dropped spots can't change the 8-bit result.
  void _cullSaturatedSpots(
    List<_MaskPoint> spots,
    double left,
    double top,
    double right,
    double bottom,
  ) {
    for (int k = 0; k < spots.length; k++) {
      final s = spots[k];
      // Farthest tile point from the spot center.
      s.sortKey = _spotAlphaAt(
        sqrt(
          _farRectDistSq(
            s.position.dx,
            s.position.dy,
            left,
            top,
            right,
            bottom,
          ),
        ),
        s.radius,
      );
    }
    spots.sort(_compareSpotKeyDescending);

    double keep = 1;
    for (int k = 0; k < spots.length; k++) {
      keep *= 1 - spots[k].sortKey;
      if (keep < _kSdfSaturatedKeep) {
        spots.length = k + 1;
        return;
      }
    }
  }

  static double _packRgb(Color c) => (c.toARGB32() & 0xFFFFFF).toDouble();

  /// A new shader instance with the uniforms that never change already set.
  ui.FragmentShader _newShader() => program.fragmentShader()
    ..setFloat(0, _kSdfSmoothing)
    ..setFloat(2, 1 / _kSdfColorFade)
    ..setFloat(3, _kSdfDepthClamp)
    ..setFloat(4, _kSdfStacking);

  void _emitTile(
    Canvas canvas,
    double left,
    double top,
    double right,
    double bottom,
    List<_Bubble> tileBubbles,
    List<_MaskPoint> tileSpots,
    List<_SdfPair> tilePairs,
  ) {
    final shaderIndex = _shaderIndex++;
    while (_shaders.length <= shaderIndex) {
      _shaders.add(_newShader());
    }
    final shader = _shaders[shaderIndex];

    final eventCount = _writeEvents(tileBubbles, tilePairs, shader);
    final spotCount = tileSpots.length;
    final groupCount = (spotCount + 3) ~/ 4;

    shader
      ..setFloat(1, _pixelSize * _kSdfAaWidth)
      ..setFloat(5, _edge)
      ..setFloat(6, ((eventCount + 1) ~/ 2).toDouble())
      ..setFloat(7, groupCount.toDouble());

    // Spots 4g..4g+3 as 4 x (x, y, radius), spread over A, B, C of group g; padding spots are
    // far away, so their alpha is 0.
    final group = _spotGroup;
    for (int g = 0; g < groupCount; g++) {
      for (int j = 0; j < 4; j++) {
        final k = g * 4 + j;
        if (k < spotCount) {
          final s = tileSpots[k];
          group[j * 3] = s.position.dx;
          group[j * 3 + 1] = s.position.dy;
          group[j * 3 + 2] = s.radius;
        } else {
          group[j * 3] = -100000;
          group[j * 3 + 1] = -100000;
          group[j * 3 + 2] = 1;
        }
      }
      final a = _kSdfSpotsABase + g * 4;
      final b = _kSdfSpotsBBase + g * 4;
      final c = _kSdfSpotsCBase + g * 4;
      shader
        ..setFloat(a, group[0])
        ..setFloat(a + 1, group[1])
        ..setFloat(a + 2, group[2])
        ..setFloat(a + 3, group[3])
        ..setFloat(b, group[4])
        ..setFloat(b + 1, group[5])
        ..setFloat(b + 2, group[6])
        ..setFloat(b + 3, group[7])
        ..setFloat(c, group[8])
        ..setFloat(c + 1, group[9])
        ..setFloat(c + 2, group[10])
        ..setFloat(c + 3, group[11]);
    }

    _paint.shader = shader;
    canvas.drawRect(Rect.fromLTRB(left, top, right, bottom), _paint);
  }
}
