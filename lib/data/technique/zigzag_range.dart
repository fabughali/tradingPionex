import '../models/range_result.dart';

/// The live, sole range rule (PRD §6.2): read the Daily MSB/OB script's zigzag
/// polyline (`dwg-lines`), reconstruct swing pivots, take the last
/// [swingCount] of them, top = max pivot, bottom = min pivot. Label/box
/// fallbacks were deliberately removed upstream ("remove 10 keep 20", 2026-08-29)
/// and are NOT ported here — if this returns null, the caller must skip the
/// cycle, never fall back to a different range source.
///
/// Ported 1:1 from lib/technique.js `detectZigzagRange` in the original
/// engine (verified live against BTC/ETH/XRP daily charts).
RangeResult? detectZigzagRange(
  List<ZigzagSegment> lines, {
  int swingCount = 20,
}) {
  final segs = lines.where((l) => !l.horizontal && l.y1 != l.y2).toList();
  if (segs.isEmpty) return null;

  final pts = <ZigzagPoint>[];
  for (final s in segs) {
    pts.add(ZigzagPoint(s.x1, s.y1));
    pts.add(ZigzagPoint(s.x2, s.y2));
  }
  pts.sort((a, b) {
    final byX = a.x.compareTo(b.x);
    return byX != 0 ? byX : a.y.compareTo(b.y);
  });

  final series = <ZigzagPoint>[];
  for (final pt in pts) {
    final last = series.isEmpty ? null : series.last;
    if (last == null || last.x != pt.x || last.y != pt.y) series.add(pt);
  }
  if (series.length < 2) return null;

  // ZigZag pivots: keep local extrema, collapsing same-direction runs into
  // the most extreme point of that run (a proper ZigZag reconstruction).
  final pivots = <ZigzagPoint>[];
  int dir = 0;
  for (var i = 1; i < series.length; i++) {
    final point = series[i];
    final prev = series[i - 1];
    final d = (point.y - prev.y).sign.toInt();
    if (d == 0) continue;
    if (dir == 0) {
      pivots.add(prev);
      pivots.add(point);
      dir = d;
      continue;
    }
    if (d == dir) {
      final lastPivot = pivots.last;
      if ((dir > 0 && point.y > lastPivot.y) ||
          (dir < 0 && point.y < lastPivot.y)) {
        pivots[pivots.length - 1] = point;
      }
    } else {
      pivots.add(prev);
      pivots.add(point);
      dir = d;
    }
  }

  final uniq = <ZigzagPoint>[];
  for (final pt in pivots) {
    final last = uniq.isEmpty ? null : uniq.last;
    if (last == null || last.x != pt.x || last.y != pt.y) uniq.add(pt);
  }
  if (uniq.isEmpty) return null;

  final recent = uniq.length > swingCount
      ? uniq.sublist(uniq.length - swingCount)
      : uniq;
  if (recent.isEmpty) return null;

  final top = recent.map((p) => p.y).reduce((a, b) => a > b ? a : b);
  final bottom = recent.map((p) => p.y).reduce((a, b) => a < b ? a : b);
  if (!(top > bottom)) return null;

  return RangeResult(top: top, bottom: bottom, pivotCount: recent.length);
}
