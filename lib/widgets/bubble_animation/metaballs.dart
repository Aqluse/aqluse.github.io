part of 'liquid_bubbles.dart';

/// Draw bubbles as SDF metaballs with shaders/metaballs.frag;
/// `--dart-define=PERF_SDF=off` forces the old renderer.
const bool _kUseSdf = String.fromEnvironment('PERF_SDF') != 'off';

double _sdfEnv(String value, double fallback, {double minValue = 0}) =>
    max(minValue, double.tryParse(value) ?? fallback);

// Look tunables (PERF): `--dart-define=NAME=value`; defaults keep the original SDF look.

/// PERF_SDF_K: smooth-min distance (logical px; initial value, adjustable at runtime with the
/// overlay slider). Shape fusion: bubbles closer than this grow a
/// neck towards each other. Also the culling margin and the color weight cutoff.
double _sdfSmoothing = _sdfEnv(
  const String.fromEnvironment('PERF_SDF_K'),
  24,
  minValue: 0.01,
);

/// PERF_SDF_FADE: width (logical px) of the color cross-fade between fusing bubbles (necks;
/// initial value, adjustable at runtime with the overlay slider): weights are
/// exp(-distance / fade).
double _sdfColorFade = _sdfEnv(
  const String.fromEnvironment('PERF_SDF_FADE'),
  5, // tuned by eye with the overlay slider
  minValue: 0.01,
);

/// PERF_SDF_EDGE_FADE: width (logical px) of the transition across the top bubble's edge in
/// stacking mode (initial value; adjustable at runtime with the overlay slider).
double _sdfEdgeFade = _sdfEnv(
  const String.fromEnvironment('PERF_SDF_EDGE_FADE'),
  2.75, // tuned by eye with the overlay slider
  minValue: 0.01,
);

// Mask spot look (initial values; adjustable at runtime with the overlay sliders). Defaults give
// the original profile: solid core 0.05 of the radius, then linear fade to the edge.

/// PERF_SPOT_SIZE: spot radius multiplier.
double _sdfSpotSize = _sdfEnv(
  const String.fromEnvironment('PERF_SPOT_SIZE'),
  1,
  minValue: 0.01,
);

/// PERF_SPOT_STRENGTH: spot opacity multiplier (the result is clamped to 1).
double _sdfSpotStrength = _sdfEnv(
  const String.fromEnvironment('PERF_SPOT_STRENGTH'),
  1,
);

/// PERF_SPOT_CORE: fraction of the radius with solid color.
double _sdfSpotCore = _sdfEnv(
  const String.fromEnvironment('PERF_SPOT_CORE'),
  0.05,
);

/// PERF_SPOT_FALLOFF: exponent of the fade from the core to the edge; 1 = linear,
/// > 1 = more concentrated, < 1 = flatter.
double _sdfSpotFalloff = _sdfEnv(
  const String.fromEnvironment('PERF_SPOT_FALLOFF'),
  1,
  minValue: 0.01,
);

/// Spot alpha (before mask opacity) at [distance] from the center of a spot with [radius];
/// must match spotKeep() in shaders/metaballs.frag.
double _spotAlphaAt(double distance, double radius) {
  final t = ((distance / radius - _sdfSpotCore) / max(1 - _sdfSpotCore, 0.001))
      .clamp(0.0, 1.0);
  return min(1, _sdfSpotStrength * pow(1 - t, _sdfSpotFalloff));
}

/// PERF_SDF_DEPTH: how deep inside a bubble (logical px) its weight keeps growing. Small values
/// make every bubble covering a pixel weigh the same, so overlaps are decided by
/// PERF_SDF_SIZE_BIAS instead of by depth.
final double _kSdfDepthClamp = _sdfEnv(
  const String.fromEnvironment('PERF_SDF_DEPTH'),
  72,
);

/// PERF_SDF_SIZE_BIAS: extra weight per logical px of radius (weights * exp(radius * bias)),
/// so bigger bubbles win overlaps like in the old renderer (bigger on top). 0 = off.
final double _kSdfSizeBias = _sdfEnv(
  const String.fromEnvironment('PERF_SDF_SIZE_BIAS'),
  0,
);

/// PERF_SDF_AA: edge anti-aliasing width in physical pixels.
final double _kSdfAaWidth = _sdfEnv(
  const String.fromEnvironment('PERF_SDF_AA'),
  1,
  minValue: 0.01,
);

/// PERF_SDF_STACKING: `on` (default) = inside bubbles only the top bubble (the old renderer's
/// order: later in the sorted list = on top) gives surface, mask and glow, with a soft
/// transition over max(fade, AA width) across its edge; necks outside all bubbles still use the
/// weighted blend. `off` = weighted blend everywhere (lower bubbles show through). The value is
/// the stacking strength from 0 (off) to 1 (on), adjustable at runtime with the overlay slider;
/// values in between let lower bubbles partially show through.
double _sdfStacking =
    const String.fromEnvironment('PERF_SDF_STACKING', defaultValue: 'on') ==
        'off'
    ? 0
    : 0.95; // tuned by eye with the overlay slider: lower bubbles barely show through

String _sdfTunablesLine() =>
    'k $_sdfSmoothing · neck fade ${_sdfColorFade.toStringAsFixed(2)} · edge fade ${_sdfEdgeFade.toStringAsFixed(2)} · '
    'depth $_kSdfDepthClamp · sizeBias $_kSdfSizeBias · aa $_kSdfAaWidth · '
    'stacking ${_sdfStacking.toStringAsFixed(2)}';

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
const int _kSdfParams2Base = _kSdfSpotsCBase + _kSdfMaxSpots ~/ 4 * 4;

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

  // One shader instance per drawn tile, reused across frames, so uniforms of different tiles
  // never share an instance within a frame.
  final List<ui.FragmentShader> _shaders = [];
  final Paint _paint = Paint()..isAntiAlias = false;
  int _shaderIndex = 0;

  late _PaintManager _manager;
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

  // Stacking edge width (same as the shader's) and the neck distance limits (see _SdfPair).
  double _edge = 1;
  double _neckDepth = 0;
  double _neckNear = 0;
  double _neckReach = 0;

  // Stamps for _Bubble.sdfMark (strictly increasing, so stale marks never match).
  int _markStamp = 0;

  // Per-frame stats.
  int _frameTiles = 0;
  int _frameSplits = 0;
  int _frameCulled = 0;
  int _frameOccludedPairs = 0;
  int _frameTileOccludedPairs = 0;
  int _frameTileOccludedBubbles = 0;

  void paint(
    Canvas canvas,
    Size size,
    _PaintManager manager,
    double pixelSize,
  ) {
    _manager = manager;
    _pixelSize = pixelSize;
    _shaderIndex = 0;
    _frameTiles = 0;
    _frameSplits = 0;
    _frameCulled = 0;
    _frameOccludedPairs = 0;
    _frameTileOccludedPairs = 0;
    _frameTileOccludedBubbles = 0;

    final w = size.width;
    final h = size.height;
    final bubbleReach = manager.maxBubbleRadius + _sdfSmoothing;
    final spotReach = manager.maxSpotRadius * _sdfSpotSize;
    final cols = (w / _kSdfTileSize).ceil();
    final rows = (h / _kSdfTileSize).ceil();

    _edge = max(_sdfEdgeFade, pixelSize * _kSdfAaWidth);
    _neckDepth = _edge / 2;
    _neckNear = _sdfSmoothing / 4 + _edge / 2;
    _neckReach = _sdfSmoothing + _edge / 2;
    _buildPairs(manager);
    _binPairs(w, h, cols, rows);

    for (int row = 0; row < rows; row++) {
      final top = row * _kSdfTileSize;
      final bottom = min(top + _kSdfTileSize, h);
      for (int col = 0; col < cols; col++) {
        final left = col * _kSdfTileSize;
        final right = min(left + _kSdfTileSize, w);
        manager.bubbleGrid.queryRect(
          Rect.fromLTRB(
            left - bubbleReach,
            top - bubbleReach,
            right + bubbleReach,
            bottom + bubbleReach,
          ),
          _rootBubbles,
        );
        if (_rootBubbles.isEmpty) continue;
        // Stacking needs bottom-to-top order; sub-tiles keep it while filtering.
        if (_sdfStacking > 0) _rootBubbles.sort(_compareBubbleIndex);
        manager.spotGrid.queryRect(
          Rect.fromLTRB(
            left - spotReach,
            top - spotReach,
            right + spotReach,
            bottom + spotReach,
          ),
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

    manager
      ..statSdfTiles = _frameTiles
      ..statSdfSplits = _frameSplits
      ..statSdfCulled = _frameCulled
      ..statSdfPairs = _framePairs.length
      ..statSdfOccludedPairs = _frameOccludedPairs
      ..statSdfTileOccludedPairs = _frameTileOccludedPairs
      ..statSdfTileOccludedBubbles = _frameTileOccludedBubbles;
  }

  /// Collects every fusing pair (center distance < r1 + r2 + k) with a neck that isn't hidden
  /// by higher bubbles into [_framePairs], ordered by the lower bubble's index.
  void _buildPairs(_PaintManager manager) {
    _framePairs.clear();
    // Without stacking every color is the weighted blend, which already includes the necks.
    if (_sdfStacking <= 0) return;

    final k = _sdfSmoothing;
    final bubbles = manager.bubbles;
    // Enough for the partners and for every bubble that can cover a neck point (within
    // lower radius + k + e/2 of the lower center).
    final reach = manager.maxBubbleRadius + k + _edge;
    int used = 0;
    bool ordered = true;
    int lastLower = -1;
    for (int l = 0; l < bubbles.length; l++) {
      final lower = bubbles[l];
      manager.bubbleGrid.query(
        lower.position,
        lower.radius + reach,
        _nearBubbles,
      );
      for (int n = 0; n < _nearBubbles.length; n++) {
        final upper = _nearBubbles[n];
        if (upper.index <= lower.index) continue;
        final dx = upper.position.dx - lower.position.dx;
        final dy = upper.position.dy - lower.position.dy;
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
        if (pair.boxCount == 0) continue;
        if (_isOccluded(pair)) {
          _frameOccludedPairs++;
          continue;
        }
        used++;
        _framePairs.add(pair);
        if (lower.index < lastLower) ordered = false;
        lastLower = lower.index;
      }
    }
    // Bubble indexes normally equal list positions, so this is a fallback only.
    if (!ordered) _framePairs.sort(_comparePairOrder);
  }

  /// Whether bubbles above the pair's lower bubble (candidates in [_nearBubbles]) fully cover
  /// the neck's bounds so that at most _kSdfOccludedKeep of it could show through.
  bool _isOccluded(_SdfPair q) {
    final keepFactor = 1 - _sdfStacking;
    double keep = 1;
    for (int n = 0; n < _nearBubbles.length; n++) {
      final c = _nearBubbles[n];
      if (c.index <= q.lower.index) continue;
      // Full stacking coverage needs depth >= e/2 inside.
      final inner = c.radius - _edge / 2;
      if (inner <= 0) continue;
      final cx = c.position.dx;
      final cy = c.position.dy;
      if (!_boxInsideCircle(cx, cy, inner, q.ax0, q.ay0, q.ax1, q.ay1)) {
        continue;
      }
      if (q.boxCount == 2 &&
          !_boxInsideCircle(cx, cy, inner, q.bx0, q.by0, q.bx1, q.by1)) {
        continue;
      }
      keep *= keepFactor;
      if (keep < _kSdfOccludedKeep) return true;
    }
    return false;
  }

  static bool _boxInsideCircle(
    double cx,
    double cy,
    double radius,
    double x0,
    double y0,
    double x1,
    double y1,
  ) {
    final fx = max((cx - x0).abs(), (cx - x1).abs());
    final fy = max((cy - y0).abs(), (cy - y1).abs());
    return fx * fx + fy * fy <= radius * radius;
  }

  /// Distributes [_framePairs] to the top-level tiles their necks can touch.
  void _binPairs(double w, double h, int cols, int rows) {
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
      double x0 = q.ax0, y0 = q.ay0, x1 = q.ax1, y1 = q.ay1;
      if (q.boxCount == 2) {
        x0 = min(x0, q.bx0);
        y0 = min(y0, q.by0);
        x1 = max(x1, q.bx1);
        y1 = max(y1, q.by1);
      }
      final c0 = (x0 / _kSdfTileSize).floor().clamp(0, cols - 1);
      final c1 = (x1 / _kSdfTileSize).floor().clamp(0, cols - 1);
      final r0 = (y0 / _kSdfTileSize).floor().clamp(0, rows - 1);
      final r1 = (y1 / _kSdfTileSize).floor().clamp(0, rows - 1);
      for (int row = r0; row <= r1; row++) {
        final top = row * _kSdfTileSize;
        final bottom = min(top + _kSdfTileSize, h);
        for (int col = c0; col <= c1; col++) {
          final left = col * _kSdfTileSize;
          final right = min(left + _kSdfTileSize, w);
          if (_pairHitsRect(q, left, top, right, bottom)) {
            _rootPairs[row * cols + col].add(q);
          }
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
  ) {
    final dx = cx < left ? left - cx : (cx > right ? cx - right : 0.0);
    final dy = cy < top ? top - cy : (cy > bottom ? cy - bottom : 0.0);
    return dx * dx + dy * dy <= radius * radius;
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
    final nx = cx < left ? left - cx : (cx > right ? cx - right : 0.0);
    final ny = cy < top ? top - cy : (cy > bottom ? cy - bottom : 0.0);
    final fx = max((cx - left).abs(), (cx - right).abs());
    final fy = max((cy - top).abs(), (cy - bottom).abs());
    _rangeMin = sqrt(nx * nx + ny * ny) - b.radius;
    _rangeMax = sqrt(fx * fx + fy * fy) - b.radius;
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
    if (!_boxHitsRect(q.ax0, q.ay0, q.ax1, q.ay1, left, top, right, bottom) &&
        !(q.boxCount == 2 &&
            _boxHitsRect(
              q.bx0,
              q.by0,
              q.bx1,
              q.by1,
              left,
              top,
              right,
              bottom,
            ))) {
      return false;
    }
    _distanceRange(q.lower, left, top, right, bottom);
    final l0 = max(_rangeMin, -_neckDepth);
    final l1 = min(_rangeMax, _neckReach);
    if (l0 > l1) return false;
    _distanceRange(q.upper, left, top, right, bottom);
    final u0 = max(_rangeMin, -_neckDepth);
    final u1 = min(_rangeMax, _neckReach);
    if (u0 > u1) return false;
    final k = _sdfSmoothing;
    // The smaller distance is below near and the two differ by less than k.
    final lNear = min(l1, _neckNear);
    if (l0 <= lNear && _gap(l0, lNear, u0, u1) <= k) return true;
    final uNear = min(u1, _neckNear);
    return u0 <= uNear && _gap(l0, l1, u0, uNear) <= k;
  }

  /// Index of the lowest of the bubbles that fully cover the rect from the top down until at
  /// most _kSdfOccludedKeep of what's below them can show through, or -1. [bubbles] are in
  /// layer order.
  int _occlusionThreshold(
    List<_Bubble> bubbles,
    double left,
    double top,
    double right,
    double bottom,
  ) {
    final keepFactor = 1 - _sdfStacking;
    double keep = 1;
    for (int k = bubbles.length - 1; k >= 0; k--) {
      final b = bubbles[k];
      final inner = b.radius - _edge / 2;
      if (inner <= 0) continue;
      if (!_boxInsideCircle(
        b.position.dx,
        b.position.dy,
        inner,
        left,
        top,
        right,
        bottom,
      )) {
        continue;
      }
      keep *= keepFactor;
      if (keep < _kSdfOccludedKeep) return b.index;
    }
    return -1;
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
        b.radius + _sdfSmoothing,
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
        s.radius * _sdfSpotSize,
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
    if (_sdfStacking > 0) {
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
        _frameTileOccludedBubbles += nb;
        int np = 0;
        while (np < tilePairs.length && tilePairs[np].lower.index < threshold) {
          np++;
        }
        tilePairs.removeRange(0, np);
        _frameTileOccludedPairs += np;
      }
    }

    if (tileBubbles.length > _manager.statSdfMaxTileBubbles) {
      _manager.statSdfMaxTileBubbles = tileBubbles.length;
    }
    if (tileSpots.length > _manager.statSdfMaxTileSpots) {
      _manager.statSdfMaxTileSpots = tileSpots.length;
    }
    if (tilePairs.length > _manager.statSdfMaxTilePairs) {
      _manager.statSdfMaxTilePairs = tilePairs.length;
    }

    if (tileSpots.length > _kSdfMaxSpots) {
      _cullSaturatedSpots(tileSpots, left, top, right, bottom);
    }

    final overflow =
        _writeEvents(tileBubbles, tilePairs, null) > _kSdfMaxEvents ||
        tileSpots.length > _kSdfMaxSpots;

    if (overflow && depth < _kSdfMaxSplitDepth) {
      _frameSplits++;
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
        _manager.statSdfDropped += tileBubbles.length - _kSdfMaxEvents;
        tileBubbles.length = _kSdfMaxEvents;
        if (_sdfStacking > 0) tileBubbles.sort(_compareBubbleIndex);
      }
      if (_writeEvents(tileBubbles, tilePairs, null) > _kSdfMaxEvents) {
        _trimPairs(tileBubbles, tilePairs, left, top, right, bottom);
      }
      if (tileSpots.length > _kSdfMaxSpots) {
        _manager.statSdfDropped += tileSpots.length - _kSdfMaxSpots;
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
      double key = _boxDistance(cx, cy, q.ax0, q.ay0, q.ax1, q.ay1);
      if (q.boxCount == 2) {
        key = min(key, _boxDistance(cx, cy, q.bx0, q.by0, q.bx1, q.by1));
      }
      q.sortKey = key;
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
    _manager.statSdfDroppedPairs += pairs.length - kept;
    pairs.length = kept;
    pairs.sort(_comparePairOrder);
  }

  static double _boxDistance(
    double x,
    double y,
    double x0,
    double y0,
    double x1,
    double y1,
  ) {
    final dx = x < x0 ? x0 - x : (x > x1 ? x - x1 : 0.0);
    final dy = y < y0 ? y0 - y : (y > y1 ? y - y1 : 0.0);
    return sqrt(dx * dx + dy * dy);
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
      final base = _kSdfEventsBBase + events ~/ 2 * 4;
      final colorBase = _kSdfEventsCBase + events ~/ 2 * 4 + 2;
      shader
        ..setFloat(base, -100000)
        ..setFloat(base + 1, -100000)
        ..setFloat(base + 2, 0)
        ..setFloat(base + 3, 2)
        ..setFloat(colorBase, 0)
        ..setFloat(colorBase + 1, 0);
    }
    return events;
  }

  /// Event [slot] (see the shader): [b] with [kind] encoded in w with its opacity.
  void _setEvent(ui.FragmentShader? shader, int slot, _Bubble b, int kind) {
    if (shader == null) return;
    final pair = slot ~/ 2;
    final odd = slot.isOdd;
    final base = (odd ? _kSdfEventsBBase : _kSdfEventsABase) + pair * 4;
    final colorBase = _kSdfEventsCBase + pair * 4 + (odd ? 2 : 0);
    final o = max(0.0, b.opacity);
    shader
      ..setFloat(base, b.position.dx)
      ..setFloat(base + 1, b.position.dy)
      ..setFloat(base + 2, b.radius)
      ..setFloat(
        base + 3,
        kind == _kSdfEventDraw
            ? o
            : (kind == _kSdfEventLowerOnly ? -1 - o : 2 + o),
      )
      ..setFloat(colorBase, _packRgb(b.color))
      ..setFloat(colorBase + 1, _packRgb(b.colorMask));
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
      final dx = max(
        (s.position.dx - left).abs(),
        (s.position.dx - right).abs(),
      );
      final dy = max(
        (s.position.dy - top).abs(),
        (s.position.dy - bottom).abs(),
      );
      s.sortKey = _spotAlphaAt(
        sqrt(dx * dx + dy * dy),
        s.radius * _sdfSpotSize,
      );
    }
    spots.sort(_compareSpotKeyDescending);

    double keep = 1;
    for (int k = 0; k < spots.length; k++) {
      keep *= 1 - spots[k].sortKey;
      if (keep < _kSdfSaturatedKeep) {
        _frameCulled += spots.length - (k + 1);
        spots.length = k + 1;
        return;
      }
    }
  }

  static double _packRgb(Color c) =>
      (((c.r * 255).round() << 16) |
              ((c.g * 255).round() << 8) |
              (c.b * 255).round())
          .toDouble();

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
      _shaders.add(program.fragmentShader());
    }
    final shader = _shaders[shaderIndex];

    final eventCount = _writeEvents(tileBubbles, tilePairs, shader);
    final spotCount = tileSpots.length;
    final groupCount = (spotCount + 3) ~/ 4;

    // Only normalizes the color weights; covers the necks' bubbles too.
    double refRadius = 0;
    for (int k = 0; k < tileBubbles.length; k++) {
      refRadius = max(refRadius, tileBubbles[k].radius);
    }
    for (int k = 0; k < tilePairs.length; k++) {
      refRadius = max(refRadius, tilePairs[k].lower.radius);
      refRadius = max(refRadius, tilePairs[k].upper.radius);
    }

    shader
      ..setFloat(0, _sdfSmoothing)
      ..setFloat(1, _pixelSize * _kSdfAaWidth)
      ..setFloat(2, 1 / _sdfColorFade)
      ..setFloat(3, _kSdfDepthClamp)
      ..setFloat(4, _kSdfSizeBias)
      ..setFloat(5, refRadius)
      ..setFloat(6, ((eventCount + 1) ~/ 2).toDouble())
      ..setFloat(7, groupCount.toDouble())
      ..setFloat(_kSdfParams2Base, _sdfStacking)
      ..setFloat(_kSdfParams2Base + 1, _sdfEdgeFade)
      ..setFloat(_kSdfParams2Base + 2, _sdfSpotStrength)
      ..setFloat(_kSdfParams2Base + 3, _sdfSpotCore)
      ..setFloat(_kSdfParams2Base + 4, _sdfSpotFalloff);

    for (int k = 0; k < groupCount * 4; k++) {
      final double x, y, r;
      if (k < spotCount) {
        final s = tileSpots[k];
        x = s.position.dx;
        y = s.position.dy;
        r = s.radius * _sdfSpotSize;
      } else {
        // Padding: far away, so its alpha is 0.
        x = -100000;
        y = -100000;
        r = 1;
      }
      // Spot k of group g occupies floats 3k..3k+2 of the group's 12 floats in A, B, C.
      final group = k ~/ 4;
      final first = (k % 4) * 3;
      for (int c = 0; c < 3; c++) {
        final slot = first + c;
        final arrayBase = slot < 4
            ? _kSdfSpotsABase
            : (slot < 8 ? _kSdfSpotsBBase : _kSdfSpotsCBase);
        shader.setFloat(
          arrayBase + group * 4 + slot % 4,
          c == 0 ? x : (c == 1 ? y : r),
        );
      }
    }

    _frameTiles++;
    _paint.shader = shader;
    canvas.drawRect(Rect.fromLTRB(left, top, right, bottom), _paint);
  }
}
