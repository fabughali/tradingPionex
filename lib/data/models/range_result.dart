/// One vertex of the MSB/OB zigzag polyline (a `dwg-lines` segment endpoint),
/// in chart x-order. `x` is whatever x-coordinate unit the source line carries
/// (bar index or time) — only its ordering matters for pivot reconstruction.
class ZigzagPoint {
  const ZigzagPoint(this.x, this.y);

  final double x;
  final double y;
}

/// One raw `dwg-lines` segment as read from the MSB/OB script (see
/// lib/data/tradingview/signals_reader.dart's port of readLines()).
/// `horizontal` segments are flat MSB/OB level lines, not part of the swing.
class ZigzagSegment {
  const ZigzagSegment({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.horizontal,
  });

  final double x1;
  final double y1;
  final double x2;
  final double y2;
  final bool horizontal;
}

/// The Daily MSB/OB zigzag-derived price range (top/bottom) — the sole,
/// non-negotiable range rule of the live technique (PRD §6.2). No label or
/// box fallback: if the zigzag yields nothing, the caller must skip the cycle.
class RangeResult {
  const RangeResult({
    required this.top,
    required this.bottom,
    required this.pivotCount,
  });

  final double top;
  final double bottom;
  final int pivotCount;

  bool get isValid => top.isFinite && bottom.isFinite && top > bottom;

  RangeResult copyWith({double? top, double? bottom}) => RangeResult(
    top: top ?? this.top,
    bottom: bottom ?? this.bottom,
    pivotCount: pivotCount,
  );
}
