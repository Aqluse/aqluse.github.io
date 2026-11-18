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

/// Capacities; must match kMaxEvents / kMaxSpotGroups * 4 in shaders/metaballs.frag.
///
/// An event is a bubble, a neck, or a neck followed by its upper bubble (see the shader), so a
/// tile needs one event per bubble without necks to lower bubbles plus one per neck.
const int _kSdfMaxEvents = 40;
const int _kSdfMaxSpots = 128;

// Float offsets of the uniforms in shaders/metaballs.frag.
const int _kSdfEventsABase = 8;
const int _kSdfEventsBBase = _kSdfEventsABase + _kSdfMaxEvents * 4;
const int _kSdfEventsCBase = _kSdfEventsBBase + _kSdfMaxEvents * 4;
const int _kSdfSpotsABase = _kSdfEventsCBase + _kSdfMaxEvents * 4;
const int _kSdfSpotsBBase = _kSdfSpotsABase + _kSdfMaxSpots ~/ 4 * 4;
const int _kSdfSpotsCBase = _kSdfSpotsBBase + _kSdfMaxSpots ~/ 4 * 4;
const int _kSdfParams2Base = _kSdfSpotsCBase + _kSdfMaxSpots ~/ 4 * 4;

/// Once the guaranteed remaining transparency of a tile's mask drops below this, further spots
/// can't change the 8-bit output and are skipped.
const double _kSdfSaturatedKeep = 1 / 512;

/// Two fusing bubbles (center distance < r1 + r2 + k): the area their smooth union adds to the
/// two shapes (the neck) is drawn at the upper bubble's layer. Reused across frames.
class _SdfPair {
  late _Bubble lower;
  late _Bubble upper;

  /// Position in the frame's pair list when created (tie-breaker of the layer order).
  int order = 0;

  /// Circle containing the neck region: the lens where both bubbles are closer than
  /// radius + outer slack.
  double cx = 0;
  double cy = 0;
  double radius = 0;

  /// Scratch sort key for overflow handling.
  double sortKey = 0;

  void set(_Bubble lower, _Bubble upper, int order, double outerSlack) {
    this.lower = lower;
    this.upper = upper;
    this.order = order;
    final x1 = lower.position.dx;
    final y1 = lower.position.dy;
    final r1 = lower.radius + outerSlack;
    final r2 = upper.radius + outerSlack;
    final dx = upper.position.dx - x1;
    final dy = upper.position.dy - y1;
    final dist = sqrt(dx * dx + dy * dy);
    if (dist > 1e-6) {
      // Chord of the two circles at distance a from the lower center. While the chord lies
      // between the centers, the lens is inside the circle having the chord as its diameter.
      final a = (dist * dist + r1 * r1 - r2 * r2) / (2 * dist);
      if (a >= 0 && a <= dist) {
        cx = x1 + dx * a / dist;
        cy = y1 + dy * a / dist;
        radius = sqrt(max(r1 * r1 - a * a, 0.0));
        return;
      }
    }
    // One circle (nearly) contains the other: the lens is inside the smaller one.
    if (r1 <= r2) {
      cx = x1;
      cy = y1;
      radius = r1;
    } else {
      cx = upper.position.dx;
      cy = upper.position.dy;
      radius = r2;
    }
  }
}

/// Draws all bubbles as one smooth union per screen tile: one draw call per non-empty tile.
///
/// Layered necks: the shader stacks bubbles bottom to top, and the neck of each fusing pair is
/// stacked right under the pair's upper bubble, so it stays visible over every bubble below
/// both and is hidden only by higher bubbles (and their necks). Per tile the bubbles and pairs
/// are merged into one bottom-to-top event list (see shaders/metaballs.frag).
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

  // Fusing pairs of the frame ordered by the upper bubble's index (objects from the pool),
  // binned per top-level tile, then one list per split depth (all reused).
  final List<_SdfPair> _pairPool = [];
  final List<_SdfPair> _framePairs = [];
  final List<_Bubble> _nearBubbles = [];
  final List<List<_SdfPair>> _rootPairs = [];
  final List<List<_SdfPair>> _tilePairs = List.generate(
    _kSdfMaxSplitDepth + 1,
    (_) => <_SdfPair>[],
  );

  // A neck can only be where both bubbles' distances are within (-inner, k + edge): deeper
  // inside a bubble its own coverage is full, farther out the smooth union adds nothing
  // (polynomial smooth min: it differs from min only while |d1 - d2| < k).
  double _neckInner = 0;
  double _neckOuter = 0;

  // Stamps for _Bubble.sdfMark (strictly increasing, so stale marks never match).
  int _markStamp = 0;

  // Per-frame stats.
  int _frameTiles = 0;
  int _frameSplits = 0;
  int _frameCulled = 0;

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

    final w = size.width;
    final h = size.height;
    final bubbleReach = manager.maxBubbleRadius + _sdfSmoothing;
    final spotReach = manager.maxSpotRadius * _sdfSpotSize;
    final cols = (w / _kSdfTileSize).ceil();
    final rows = (h / _kSdfTileSize).ceil();

    // Same width as the shader's stacking edge.
    final edge = max(_sdfEdgeFade, pixelSize * _kSdfAaWidth);
    _neckInner = edge / 2;
    _neckOuter = _sdfSmoothing + edge;
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
      ..statSdfPairs = _framePairs.length;
  }

  /// Collects every fusing pair (center distance < r1 + r2 + k) into [_framePairs], ordered by
  /// the upper bubble's index.
  void _buildPairs(_PaintManager manager) {
    _framePairs.clear();
    // Without stacking every color is the weighted blend, which already includes the necks.
    if (_sdfStacking <= 0) return;

    final k = _sdfSmoothing;
    final bubbles = manager.bubbles;
    final reach = manager.maxBubbleRadius + k;
    int used = 0;
    bool ordered = true;
    int lastUpper = -1;
    for (int u = 0; u < bubbles.length; u++) {
      final upper = bubbles[u];
      manager.bubbleGrid.query(
        upper.position,
        upper.radius + reach,
        _nearBubbles,
      );
      for (int n = 0; n < _nearBubbles.length; n++) {
        final lower = _nearBubbles[n];
        if (lower.index >= upper.index) continue;
        final dx = upper.position.dx - lower.position.dx;
        final dy = upper.position.dy - lower.position.dy;
        final fuse = upper.radius + lower.radius + k;
        if (dx * dx + dy * dy >= fuse * fuse) continue;

        if (used == _pairPool.length) _pairPool.add(_SdfPair());
        final pair = _pairPool[used++]
          ..set(lower, upper, _framePairs.length, _neckOuter);
        _framePairs.add(pair);
        if (upper.index < lastUpper) ordered = false;
        lastUpper = upper.index;
      }
    }
    // Bubble indexes normally equal list positions, so this is a fallback only.
    if (!ordered) _framePairs.sort(_comparePairOrder);
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
      final c0 = ((q.cx - q.radius) / _kSdfTileSize).floor().clamp(0, cols - 1);
      final c1 = ((q.cx + q.radius) / _kSdfTileSize).floor().clamp(0, cols - 1);
      final r0 = ((q.cy - q.radius) / _kSdfTileSize).floor().clamp(0, rows - 1);
      final r1 = ((q.cy + q.radius) / _kSdfTileSize).floor().clamp(0, rows - 1);
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

  /// Whether the rect has points at distances from [b]'s center within
  /// (radius - _neckInner, radius + _neckOuter).
  bool _neckBandHitsRect(
    _Bubble b,
    double left,
    double top,
    double right,
    double bottom,
  ) {
    final cx = b.position.dx;
    final cy = b.position.dy;
    if (!_circleHitsRect(
      cx,
      cy,
      b.radius + _neckOuter,
      left,
      top,
      right,
      bottom,
    )) {
      return false;
    }
    final inner = b.radius - _neckInner;
    if (inner <= 0) return true;
    // Farthest rect point from the center must be outside the inner circle.
    final fx = max((cx - left).abs(), (cx - right).abs());
    final fy = max((cy - top).abs(), (cy - bottom).abs());
    return fx * fx + fy * fy > inner * inner;
  }

  /// Conservative test whether the neck of [q] can touch the rect.
  bool _pairHitsRect(
    _SdfPair q,
    double left,
    double top,
    double right,
    double bottom,
  ) =>
      _circleHitsRect(q.cx, q.cy, q.radius, left, top, right, bottom) &&
      _neckBandHitsRect(q.lower, left, top, right, bottom) &&
      _neckBandHitsRect(q.upper, left, top, right, bottom);

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

  /// Layer order of the necks: by the upper bubble, then by creation.
  static int _comparePairOrder(_SdfPair a, _SdfPair b) {
    final byUpper = a.upper.index.compareTo(b.upper.index);
    return byUpper != 0 ? byUpper : a.order.compareTo(b.order);
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
      final dx = q.cx - cx;
      final dy = q.cy - cy;
      q.sortKey = sqrt(dx * dx + dy * dy) - q.radius;
    }
    pairs.sort(_comparePairKeyAscending);

    // The first neck of a bubble in the tile shares the bubble's event; any other costs one.
    final inTile = ++_markStamp;
    final shared = ++_markStamp;
    for (int k = 0; k < bubbles.length; k++) {
      bubbles[k].sdfMark = inTile;
    }
    int events = bubbles.length;
    int kept = 0;
    for (int k = 0; k < pairs.length; k++) {
      final q = pairs[k];
      final free = q.upper.sdfMark == inTile;
      if (!free && events >= _kSdfMaxEvents) continue;
      if (free) {
        q.upper.sdfMark = shared;
      } else {
        events++;
      }
      pairs[kept++] = q;
    }
    _manager.statSdfDroppedPairs += pairs.length - kept;
    pairs.length = kept;
    pairs.sort(_comparePairOrder);
  }

  /// Merges [bubbles] and [pairs] (both in layer order) into the bottom-to-top event list:
  /// a bubble's necks to lower bubbles go right before it, the last of them also drawing the
  /// bubble; necks whose upper bubble isn't in the tile go alone. Writes the events into
  /// [shader] if given; returns their count.
  int _writeEvents(
    List<_Bubble> bubbles,
    List<_SdfPair> pairs,
    ui.FragmentShader? shader,
  ) {
    int events = 0;
    int p = 0;
    for (int k = 0; k < bubbles.length; k++) {
      final b = bubbles[k];
      while (p < pairs.length && pairs[p].upper.index < b.index) {
        if (shader != null) {
          _setEvent(shader, events, pairs[p].lower, pairs[p].upper, false);
        }
        events++;
        p++;
      }
      bool hasNecks = false;
      while (p < pairs.length && identical(pairs[p].upper, b)) {
        final last = p + 1 == pairs.length || !identical(pairs[p + 1].upper, b);
        if (shader != null) {
          _setEvent(shader, events, pairs[p].lower, b, last);
        }
        events++;
        p++;
        hasNecks = true;
      }
      if (!hasNecks) {
        if (shader != null) _setEvent(shader, events, null, b, true);
        events++;
      }
    }
    while (p < pairs.length) {
      if (shader != null) {
        _setEvent(shader, events, pairs[p].lower, pairs[p].upper, false);
      }
      events++;
      p++;
    }
    return events;
  }

  /// Event [slot]: the neck between [lower] and [upper] (none if [lower] is null), then
  /// [upper] itself if [drawUpper] (flagged by storing its opacity o as -1 - o otherwise).
  void _setEvent(
    ui.FragmentShader shader,
    int slot,
    _Bubble? lower,
    _Bubble upper,
    bool drawUpper,
  ) {
    final a = _kSdfEventsABase + slot * 4;
    final b = _kSdfEventsBBase + slot * 4;
    final c = _kSdfEventsCBase + slot * 4;
    if (lower != null) {
      shader
        ..setFloat(a, lower.position.dx)
        ..setFloat(a + 1, lower.position.dy)
        ..setFloat(a + 2, lower.radius)
        ..setFloat(a + 3, lower.opacity)
        ..setFloat(c, _packRgb(lower.color))
        ..setFloat(c + 1, _packRgb(lower.colorMask));
    } else {
      // No neck: far away and zero radius, so the smooth union adds nothing.
      shader
        ..setFloat(a, -100000)
        ..setFloat(a + 1, -100000)
        ..setFloat(a + 2, 0)
        ..setFloat(a + 3, 0)
        ..setFloat(c, 0)
        ..setFloat(c + 1, 0);
    }
    final opacity = max(0.0, upper.opacity);
    shader
      ..setFloat(b, upper.position.dx)
      ..setFloat(b + 1, upper.position.dy)
      ..setFloat(b + 2, upper.radius)
      ..setFloat(b + 3, drawUpper ? opacity : -1 - opacity)
      ..setFloat(c + 2, _packRgb(upper.color))
      ..setFloat(c + 3, _packRgb(upper.colorMask));
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

    // Only normalizes the color weights; covers the necks' lower bubbles too.
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
      ..setFloat(6, eventCount.toDouble())
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
