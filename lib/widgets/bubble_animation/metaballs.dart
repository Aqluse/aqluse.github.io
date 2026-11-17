part of 'liquid_bubbles.dart';

/// Draw bubbles as SDF metaballs with shaders/metaballs.frag;
/// `--dart-define=PERF_SDF=off` forces the old renderer.
const bool _kUseSdf = String.fromEnvironment('PERF_SDF') != 'off';

/// Smooth-min distance (logical px): bubbles closer than this fuse.
const double _kSdfSmoothing = 24;

/// Color weight falloff in the shader: exp(-distance * sharpness). The color transition between
/// fused bubbles is about `_kSdfSmoothing / 5` wide.
const double _kSdfColorSharpness = 5 / _kSdfSmoothing;

/// Top-level tile size (logical px).
const double _kSdfTileSize = 256;

/// How many times an overflowing tile may be split into 4 (256 -> 128 -> 64).
const int _kSdfMaxSplitDepth = 2;

/// Capacities; must match kMaxBubbles / kMaxSpots in shaders/metaballs.frag.
const int _kSdfMaxBubbles = 32;
const int _kSdfMaxSpots = 64;

// Float offsets of the uniform arrays in shaders/metaballs.frag.
const int _kSdfBubblesBase = 5;
const int _kSdfColorsBase = _kSdfBubblesBase + _kSdfMaxBubbles * 4;
const int _kSdfMaskColorsBase = _kSdfColorsBase + _kSdfMaxBubbles * 4;
const int _kSdfSpotsBase = _kSdfMaskColorsBase + _kSdfMaxBubbles * 4;

/// Draws all bubbles as one smooth union per screen tile: one draw call per non-empty tile.
class _MetaballRenderer {
  _MetaballRenderer(this.program);

  final ui.FragmentProgram program;

  // One shader instance per drawn tile, reused across frames, so uniforms of different tiles
  // never share an instance within a frame.
  final List<ui.FragmentShader> _shaders = [];
  final Paint _paint = Paint()..isAntiAlias = false;
  int _shaderIndex = 0;

  // Objects of the current frame.
  late _PaintManager _manager;
  double _pixelSize = 1;

  // Indices of objects touching the canvas, then one list per split depth (reused).
  final List<int> _rootBubbles = [];
  final List<int> _rootSpots = [];
  final List<List<int>> _tileBubbles = List.generate(
    _kSdfMaxSplitDepth + 1,
    (_) => <int>[],
  );
  final List<List<int>> _tileSpots = List.generate(
    _kSdfMaxSplitDepth + 1,
    (_) => <int>[],
  );

  // Per-frame stats.
  int _frameTiles = 0;
  int _frameSplits = 0;

  // Center of the tile being trimmed on overflow (used by the sort comparators).
  double _trimCx = 0;
  double _trimCy = 0;

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

    final bubbles = manager.bubbles;
    final spots = manager.maskPoints;
    final w = size.width;
    final h = size.height;

    _rootBubbles.clear();
    for (int i = 0; i < bubbles.length; i++) {
      final b = bubbles[i];
      if (_circleHitsRect(
        b.position.dx,
        b.position.dy,
        b.radius + _kSdfSmoothing,
        0,
        0,
        w,
        h,
      )) {
        _rootBubbles.add(i);
      }
    }

    if (_rootBubbles.isNotEmpty) {
      _rootSpots.clear();
      for (int i = 0; i < spots.length; i++) {
        final s = spots[i];
        if (_circleHitsRect(
          s.position.dx,
          s.position.dy,
          s.radius,
          0,
          0,
          w,
          h,
        )) {
          _rootSpots.add(i);
        }
      }

      for (double top = 0; top < h; top += _kSdfTileSize) {
        final bottom = min(top + _kSdfTileSize, h);
        for (double left = 0; left < w; left += _kSdfTileSize) {
          final right = min(left + _kSdfTileSize, w);
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
    }

    manager
      ..statSdfTiles = _frameTiles
      ..statSdfSplits = _frameSplits;
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
    List<int> sourceBubbles,
    List<int> sourceSpots,
  ) {
    final bubbles = _manager.bubbles;
    final spots = _manager.maskPoints;

    final tileBubbles = _tileBubbles[depth]..clear();
    for (int k = 0; k < sourceBubbles.length; k++) {
      final i = sourceBubbles[k];
      final b = bubbles[i];
      if (_circleHitsRect(
        b.position.dx,
        b.position.dy,
        b.radius + _kSdfSmoothing,
        left,
        top,
        right,
        bottom,
      )) {
        tileBubbles.add(i);
      }
    }
    if (tileBubbles.isEmpty) return;

    final tileSpots = _tileSpots[depth]..clear();
    for (int k = 0; k < sourceSpots.length; k++) {
      final i = sourceSpots[k];
      final s = spots[i];
      if (_circleHitsRect(
        s.position.dx,
        s.position.dy,
        s.radius,
        left,
        top,
        right,
        bottom,
      )) {
        tileSpots.add(i);
      }
    }

    if (tileBubbles.length > _manager.statSdfMaxTileBubbles) {
      _manager.statSdfMaxTileBubbles = tileBubbles.length;
    }
    if (tileSpots.length > _manager.statSdfMaxTileSpots) {
      _manager.statSdfMaxTileSpots = tileSpots.length;
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
      // Smallest tile and still too many objects: keep the nearest ones.
      _trimCx = (left + right) / 2;
      _trimCy = (top + bottom) / 2;
      if (tileBubbles.length > _kSdfMaxBubbles) {
        tileBubbles.sort(_compareBubbleDistance);
        _manager.statSdfDropped += tileBubbles.length - _kSdfMaxBubbles;
        tileBubbles.length = _kSdfMaxBubbles;
      }
      if (tileSpots.length > _kSdfMaxSpots) {
        tileSpots.sort(_compareSpotDistance);
        _manager.statSdfDropped += tileSpots.length - _kSdfMaxSpots;
        tileSpots.length = _kSdfMaxSpots;
      }
    }

    _emitTile(canvas, left, top, right, bottom, tileBubbles, tileSpots);
  }

  int _compareBubbleDistance(int a, int b) {
    final ba = _manager.bubbles[a];
    final bb = _manager.bubbles[b];
    final da = _distanceToTrimCenter(ba.position) - ba.radius;
    final db = _distanceToTrimCenter(bb.position) - bb.radius;
    return da.compareTo(db);
  }

  int _compareSpotDistance(int a, int b) {
    final sa = _manager.maskPoints[a];
    final sb = _manager.maskPoints[b];
    final da = _distanceToTrimCenter(sa.position) - sa.radius;
    final db = _distanceToTrimCenter(sb.position) - sb.radius;
    return da.compareTo(db);
  }

  double _distanceToTrimCenter(Offset p) {
    final dx = p.dx - _trimCx;
    final dy = p.dy - _trimCy;
    return sqrt(dx * dx + dy * dy);
  }

  void _emitTile(
    Canvas canvas,
    double left,
    double top,
    double right,
    double bottom,
    List<int> tileBubbles,
    List<int> tileSpots,
  ) {
    final bubbles = _manager.bubbles;
    final spots = _manager.maskPoints;

    final shaderIndex = _shaderIndex++;
    while (_shaders.length <= shaderIndex) {
      _shaders.add(program.fragmentShader());
    }
    final shader = _shaders[shaderIndex];

    shader
      ..setFloat(0, _kSdfSmoothing)
      ..setFloat(1, _pixelSize)
      ..setFloat(2, _kSdfColorSharpness)
      ..setFloat(3, tileBubbles.length.toDouble())
      ..setFloat(4, tileSpots.length.toDouble());

    for (int k = 0; k < tileBubbles.length; k++) {
      final b = bubbles[tileBubbles[k]];
      final color = b.color;
      final mask = b.colorMask;
      final base = k * 4;
      shader
        ..setFloat(_kSdfBubblesBase + base, b.position.dx)
        ..setFloat(_kSdfBubblesBase + base + 1, b.position.dy)
        ..setFloat(_kSdfBubblesBase + base + 2, b.radius)
        ..setFloat(_kSdfBubblesBase + base + 3, b.opacity)
        ..setFloat(_kSdfColorsBase + base, color.r)
        ..setFloat(_kSdfColorsBase + base + 1, color.g)
        ..setFloat(_kSdfColorsBase + base + 2, color.b)
        ..setFloat(_kSdfMaskColorsBase + base, mask.r)
        ..setFloat(_kSdfMaskColorsBase + base + 1, mask.g)
        ..setFloat(_kSdfMaskColorsBase + base + 2, mask.b);
    }

    for (int k = 0; k < tileSpots.length; k++) {
      final s = spots[tileSpots[k]];
      final base = _kSdfSpotsBase + k * 4;
      shader
        ..setFloat(base, s.position.dx)
        ..setFloat(base + 1, s.position.dy)
        ..setFloat(base + 2, s.radius);
    }

    _frameTiles++;
    _paint.shader = shader;
    canvas.drawRect(Rect.fromLTRB(left, top, right, bottom), _paint);
  }
}
