part of 'liquid_bubbles.dart';

/// Uniform grid over the canvas used to find nearby objects without checking every pair.
///
/// Rebuilt every tick: [reset] then [insert] each object. Positions outside the canvas are
/// clamped to the border cells, so queries may return extra candidates but never miss one;
/// callers still do exact distance checks.
class _SpatialGrid<T> {
  _SpatialGrid(this.cellSize);

  final double cellSize;

  int _cols = 0;
  int _rows = 0;
  final List<List<T>> _cells = [];

  void reset(Size size) {
    _cols = max(1, (size.width / cellSize).ceil());
    _rows = max(1, (size.height / cellSize).ceil());
    final count = _cols * _rows;
    while (_cells.length < count) {
      _cells.add(<T>[]);
    }
    for (int i = 0; i < count; i++) {
      _cells[i].clear();
    }
  }

  int _col(double x) => (x / cellSize).floor().clamp(0, _cols - 1);

  int _row(double y) => (y / cellSize).floor().clamp(0, _rows - 1);

  void insert(T item, Offset position) {
    _cells[_row(position.dy) * _cols + _col(position.dx)].add(item);
  }

  /// Fills [out] with the objects in the cells overlapping [rect] and returns it.
  List<T> queryRect(Rect rect, List<T> out) {
    out.clear();
    if (_cols == 0) return out;

    final c0 = _col(rect.left), c1 = _col(rect.right);
    final r0 = _row(rect.top), r1 = _row(rect.bottom);
    for (int r = r0; r <= r1; r++) {
      final rowStart = r * _cols;
      for (int c = c0; c <= c1; c++) {
        out.addAll(_cells[rowStart + c]);
      }
    }
    return out;
  }

  /// Fills [out] with the objects in the cells overlapping the square of half-size [radius]
  /// around [center] and returns it.
  List<T> query(Offset center, double radius, List<T> out) => queryRect(
    Rect.fromCenter(center: center, width: radius * 2, height: radius * 2),
    out,
  );
}
