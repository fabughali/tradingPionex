import '../models/grid_bot.dart';

const maxShrinkRetries = 12;

/// One retry's shrunk range, or null once the band would become degenerate.
class ShrunkRange {
  const ShrunkRange({
    required this.top,
    required this.bottom,
    required this.attempt,
  });

  final double top;
  final double bottom;
  final int attempt;
}

/// The liquidation-avoidance shrink retry used when Pionex rejects a create
/// (typically too-low investment for the price band). Always computed from
/// the ORIGINAL (pre-shrink) top/bottom on every attempt, never compounded
/// on an already-shrunk value.
///
/// Bug fixed 2026-09-16, per the user, in two steps:
///
/// First (wrong) attempt: shrank both edges symmetrically toward the
/// center. Corrected immediately, per the user ("why you apply from both
/// side. because you have to keep 40/60 percentage") - the app's mandatory
/// 60/40 liquidation model (PRD §9.5, `computeLiquidationLevels`) keeps
/// stop-loss permanently FIXED at one edge (bottom for a long, top for a
/// short) and only ever moves the take-profit edge - moving both edges
/// here would silently drift the SL edge this retry ladder has no business
/// touching.
///
/// Real root cause of the original bug: the pre-existing (bot-grid.js-
/// ported) formula already only moved the TP edge (`bigCut`, 10%/attempt)
/// while leaving the SL edge nearly fixed (`smallCut`, ~0%/attempt) - that
/// part was correct. Its bug was computing the 10% cut against the raw
/// PRICE level, not the SPAN - for any pair whose range is narrow relative
/// to its price (confirmed live on SOLUSDT: span 9.98 on a ~96 price), a
/// 10%-of-price cut off the TP edge could already exceed the ENTIRE span
/// and cross the fixed SL edge on attempt #1, degenerating immediately
/// with zero real shrink attempts ever tried - indistinguishable in the
/// log from "Pionex rejected it" even though the shrink math never got a
/// chance to run.
///
/// Fixed formula: SL edge (bottom for long, top for short) stays exactly
/// at its original value, every attempt, never moves. TP edge (the other
/// one) pulls in by `10*attempt`% of the ORIGINAL SPAN per attempt - same
/// 10%/attempt pace as the original, just measured against the span
/// instead of the price, so it scales correctly for a narrow-relative-to-
/// price range instead of overshooting on attempt #1.
///
/// Returns null once the cut would consume the whole span (or exceed it)
/// - the resulting band would be degenerate (top <= bottom) - the caller
/// should give up on this cycle at that point, exactly like before.
///
/// Note: values round to the nearest whole unit (`Math.round` in the
/// original), matching its exact behavior rather than preserving decimals.
ShrunkRange? shrinkRangeForRetry({
  required double originalTop,
  required double originalBottom,
  required GridDirection direction,
  required int attempt,
}) {
  final span = originalTop - originalBottom;
  final cutPct = 10 * attempt;
  if (cutPct >= 100) return null;
  final cut = span * (cutPct / 100);

  // LONG: SL fixed at bottom - only top (TP) moves.
  // SHORT: SL fixed at top - only bottom (TP) moves.
  final newTop = direction == GridDirection.long
      ? (originalTop - cut).round().toDouble()
      : originalTop.round().toDouble();
  final newBottom = direction == GridDirection.long
      ? originalBottom.round().toDouble()
      : (originalBottom + cut).round().toDouble();

  if (!(newTop > newBottom)) return null;
  return ShrunkRange(top: newTop, bottom: newBottom, attempt: attempt);
}
