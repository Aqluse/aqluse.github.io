part of 'liquid_bubbles.dart';

/// Draw bubbles as SDF metaballs with shaders/metaballs.frag;
/// `--dart-define=PERF_SDF=off` forces the old renderer.
const bool _kUseSdf = String.fromEnvironment('PERF_SDF') != 'off';

double _sdfEnv(String value, double fallback, {double minValue = 0}) =>
    max(minValue, double.tryParse(value) ?? fallback);

// Look tunables (PERF): `--dart-define=NAME=value`; defaults keep the original SDF look.

/// PERF_SDF_K: smooth-min distance (logical px). Shape fusion: bubbles closer than this grow a
/// neck towards each other. Also the culling margin and the color weight cutoff.
final double _kSdfSmoothing = _sdfEnv(
  const String.fromEnvironment('PERF_SDF_K'),
  24,
  minValue: 0.01,
);

/// PERF_SDF_FADE: width (logical px) of the color cross-fade between fusing bubbles (necks;
/// initial value, adjustable at runtime with the overlay slider): weights are
/// exp(-distance / fade).
double _sdfColorFade = _sdfEnv(
  const String.fromEnvironment('PERF_SDF_FADE'),
  24 / 5,
  minValue: 0.01,
);

/// PERF_SDF_EDGE_FADE: width (logical px) of the transition across the top bubble's edge in
/// stacking mode (initial value; adjustable at runtime with the overlay slider).
double _sdfEdgeFade = _sdfEnv(
  const String.fromEnvironment('PERF_SDF_EDGE_FADE'),
  1,
  minValue: 0.01,
);

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
/// weighted blend. `off` = weighted blend everywhere (lower bubbles show through).
const bool _kSdfStacking =
    String.fromEnvironment('PERF_SDF_STACKING', defaultValue: 'on') != 'off';

String _sdfTunablesLine() =>
    'k $_kSdfSmoothing · neck fade ${_sdfColorFade.toStringAsFixed(2)} · edge fade ${_sdfEdgeFade.toStringAsFixed(2)} · '
    'depth $_kSdfDepthClamp · sizeBias $_kSdfSizeBias · aa $_kSdfAaWidth · '
    'stacking ${_kSdfStacking ? 'on' : 'off'}';

/// Top-level tile size (logical px).
const double _kSdfTileSize = 256;

/// How many times an overflowing tile may be split into 4 (256 -> 128 -> 64 -> 32 -> 16).
const int _kSdfMaxSplitDepth = 4;

/// Capacities; must match kMaxBubblePairs * 2 / kMaxSpotGroups * 4 in shaders/metaballs.frag.
const int _kSdfMaxBubbles = 64;
const int _kSdfMaxSpots = 128;

// Float offsets of the uniforms in shaders/metaballs.frag.
const int _kSdfBubblesABase = 8;
const int _kSdfBubblesBBase = _kSdfBubblesABase + _kSdfMaxBubbles ~/ 2 * 4;
const int _kSdfColorsBase = _kSdfBubblesBBase + _kSdfMaxBubbles ~/ 2 * 4;
const int _kSdfSpotsABase = _kSdfColorsBase + _kSdfMaxBubbles ~/ 2 * 4;
const int _kSdfSpotsBBase = _kSdfSpotsABase + _kSdfMaxSpots ~/ 4 * 4;
const int _kSdfSpotsCBase = _kSdfSpotsBBase + _kSdfMaxSpots ~/ 4 * 4;
const int _kSdfParams2Base = _kSdfSpotsCBase + _kSdfMaxSpots ~/ 4 * 4;

/// Once the guaranteed remaining transparency of a tile's mask drops below this, further spots
/// can't change the 8-bit output and are skipped.
const double _kSdfSaturatedKeep = 1 / 512;

/// Draws all bubbles as one smooth union per screen tile: one draw call per non-empty tile.
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
    final bubbleReach = manager.maxBubbleRadius + _kSdfSmoothing;
    final spotReach = manager.maxSpotRadius;

    for (double top = 0; top < h; top += _kSdfTileSize) {
      final bottom = min(top + _kSdfTileSize, h);
      for (double left = 0; left < w; left += _kSdfTileSize) {
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
        if (_kSdfStacking) _rootBubbles.sort(_compareBubbleIndex);
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
        );
      }
    }

    manager
      ..statSdfTiles = _frameTiles
      ..statSdfSplits = _frameSplits
      ..statSdfCulled = _frameCulled;
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

  void _drawTile(
    Canvas canvas,
    double left,
    double top,
    double right,
    double bottom,
    int depth,
    List<_Bubble> sourceBubbles,
    List<_MaskPoint> sourceSpots,
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

    if (tileBubbles.length > _manager.statSdfMaxTileBubbles) {
      _manager.statSdfMaxTileBubbles = tileBubbles.length;
    }
    if (tileSpots.length > _manager.statSdfMaxTileSpots) {
      _manager.statSdfMaxTileSpots = tileSpots.length;
    }

    if (tileSpots.length > _kSdfMaxSpots) {
      _cullSaturatedSpots(tileSpots, left, top, right, bottom);
    }

    final overflow =
        tileBubbles.length > _kSdfMaxBubbles ||
        tileSpots.length > _kSdfMaxSpots;

    if (overflow && depth < _kSdfMaxSplitDepth) {
      _frameSplits++;
      final midX = (left + right) / 2;
      final midY = (top + bottom) / 2;
      final next = depth + 1;
      _drawTile(canvas, left, top, midX, midY, next, tileBubbles, tileSpots);
      _drawTile(canvas, midX, top, right, midY, next, tileBubbles, tileSpots);
      _drawTile(canvas, left, midY, midX, bottom, next, tileBubbles, tileSpots);
      _drawTile(
        canvas,
        midX,
        midY,
        right,
        bottom,
        next,
        tileBubbles,
        tileSpots,
      );
      return;
    }

    if (overflow) {
      // Smallest tile and still too many objects: keep the nearest bubbles and the strongest
      // spots (already sorted by the saturation culling).
      if (tileBubbles.length > _kSdfMaxBubbles) {
        final cx = (left + right) / 2;
        final cy = (top + bottom) / 2;
        for (int k = 0; k < tileBubbles.length; k++) {
          final b = tileBubbles[k];
          final dx = b.position.dx - cx;
          final dy = b.position.dy - cy;
          b.sortKey = sqrt(dx * dx + dy * dy) - b.radius;
        }
        tileBubbles.sort(_compareBubbleKeyAscending);
        _manager.statSdfDropped += tileBubbles.length - _kSdfMaxBubbles;
        tileBubbles.length = _kSdfMaxBubbles;
        if (_kSdfStacking) tileBubbles.sort(_compareBubbleIndex);
      }
      if (tileSpots.length > _kSdfMaxSpots) {
        _manager.statSdfDropped += tileSpots.length - _kSdfMaxSpots;
        tileSpots.length = _kSdfMaxSpots;
      }
    }

    _emitTile(canvas, left, top, right, bottom, tileBubbles, tileSpots);
  }

  static int _compareBubbleIndex(_Bubble a, _Bubble b) =>
      a.index.compareTo(b.index);

  static int _compareBubbleKeyAscending(_Bubble a, _Bubble b) =>
      a.sortKey.compareTo(b.sortKey);

  static int _compareSpotKeyDescending(_MaskPoint a, _MaskPoint b) =>
      b.sortKey.compareTo(a.sortKey);

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
      final t = ((sqrt(dx * dx + dy * dy) / s.radius - 0.05) / 0.95).clamp(
        0.0,
        1.0,
      );
      s.sortKey = 1 - t;
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
  ) {
    final shaderIndex = _shaderIndex++;
    while (_shaders.length <= shaderIndex) {
      _shaders.add(program.fragmentShader());
    }
    final shader = _shaders[shaderIndex];

    final bubbleCount = tileBubbles.length;
    final pairCount = (bubbleCount + 1) ~/ 2;
    final spotCount = tileSpots.length;
    final groupCount = (spotCount + 3) ~/ 4;

    double refRadius = 0;
    for (int k = 0; k < bubbleCount; k++) {
      refRadius = max(refRadius, tileBubbles[k].radius);
    }

    shader
      ..setFloat(0, _kSdfSmoothing)
      ..setFloat(1, _pixelSize * _kSdfAaWidth)
      ..setFloat(2, 1 / _sdfColorFade)
      ..setFloat(3, _kSdfDepthClamp)
      ..setFloat(4, _kSdfSizeBias)
      ..setFloat(5, refRadius)
      ..setFloat(6, pairCount.toDouble())
      ..setFloat(7, groupCount.toDouble())
      ..setFloat(_kSdfParams2Base, _kSdfStacking ? 1 : 0)
      ..setFloat(_kSdfParams2Base + 1, _sdfEdgeFade);

    for (int k = 0; k < pairCount * 2; k++) {
      final pair = k ~/ 2;
      final odd = k.isOdd;
      final base = (odd ? _kSdfBubblesBBase : _kSdfBubblesABase) + pair * 4;
      final colorBase = _kSdfColorsBase + pair * 4 + (odd ? 2 : 0);
      if (k < bubbleCount) {
        final b = tileBubbles[k];
        shader
          ..setFloat(base, b.position.dx)
          ..setFloat(base + 1, b.position.dy)
          ..setFloat(base + 2, b.radius)
          ..setFloat(base + 3, b.opacity)
          ..setFloat(colorBase, _packRgb(b.color))
          ..setFloat(colorBase + 1, _packRgb(b.colorMask));
      } else {
        // Padding: far away, zero radius and opacity, so it adds no shape and no weight.
        shader
          ..setFloat(base, -100000)
          ..setFloat(base + 1, -100000)
          ..setFloat(base + 2, 0)
          ..setFloat(base + 3, 0)
          ..setFloat(colorBase, 0)
          ..setFloat(colorBase + 1, 0);
      }
    }

    for (int k = 0; k < groupCount * 4; k++) {
      final double x, y, r;
      if (k < spotCount) {
        final s = tileSpots[k];
        x = s.position.dx;
        y = s.position.dy;
        r = s.radius;
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
