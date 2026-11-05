import '../models/grid_bot.dart';
import '../models/liquidation_levels.dart';

const stableLiquidationFraction = 0.60;

/// New 60/40 model (2026-09-14), per the user's explicit spec, replacing
/// [computeLiquidationLevels] for the real-open decision path only (that
/// function's other, preview-only call site is untouched - out of scope of
/// what was asked). Two things changed from the old model:
///
/// 1. The safety check is against Pionex's REAL liquidation price (fetched
///    live via a `checkFuturesGrid` probe - see `_resolveQuotePrecision`'s
///    2026-09-14 update in engine_service.dart, which now returns it from
///    the SAME row=minGrids call it already made, no extra Pionex round
///    trip), not the chart's own natural top/bottom edge. The user, live,
///    walked through the exact numbers: range 20-80 (span=60), entry=30,
///    Pionex-reported liquidation=20 - distance(30,20)=10 < 0.6*60=36, so
///    the range is unsafe and must shift.
/// 2. The adjustment is a PARALLEL SHIFT (both edges move together, span
///    stays fixed) placing entry at exactly 60% of the ORIGINAL span above
///    (long) / below (short) the new near edge - not the old model's
///    single-edge stretch (which changed the total span and, per its own
///    2026-09-11 fix history, was never actually anchored to a real
///    liquidation price at all). Verified against the user's own worked
///    example: span=60, new SL=10 -> entry sits at 10+0.6*60=46 above it,
///    new far edge = 10+60=70, matching "10 to 70" exactly.
///
/// If [liquidationPrice] is unavailable (the preliminary probe failed),
/// this fails OPEN - proceeds with the natural, unshifted range - rather
/// than refusing to open at all: that matches the OLD model's baseline
/// behavior (which never had real liquidation data either), so this is
/// strictly an improvement when the probe succeeds, never a new risk when
/// it doesn't.
///
/// A degenerate result (shifted near edge at or below zero) also fails
/// open to the natural range, same "Plan B" principle
/// [computeLiquidationLevels] already used for its own degenerate cases.
LiquidationLevels computeLiquidationShift({
  required double top,
  required double bottom,
  required double entry,
  required double? liquidationPrice,
  required GridDirection direction,
}) {
  final span = top - bottom;
  if (!span.isFinite || span <= 0) {
    throw ArgumentError('degenerate range: top ($top) <= bottom ($bottom)');
  }

  LiquidationLevels natural() {
    final nearEdge = direction == GridDirection.long ? bottom : top;
    return LiquidationLevels(
      direction: direction,
      takeProfitPrice: direction == GridDirection.long ? top : bottom,
      stopLossPrice: nearEdge,
      stopLossFraction: (entry - nearEdge).abs() / span,
      stable: true,
      widenApplied: false,
      gridTop: top,
      gridBottom: bottom,
    );
  }

  if (liquidationPrice == null) return natural();

  final distance = (entry - liquidationPrice).abs();
  if (distance >= stableLiquidationFraction * span) return natural();

  if (direction == GridDirection.long) {
    final newBottom = entry - stableLiquidationFraction * span;
    final newTop = newBottom + span;
    // Bug fixed 2026-09-20, live (GALAUSDT ignite: "bottom must greater
    // than 0" from Pionex, confirmed real - not the harmless precision-
    // probe retry every other pair hits). A plain `<= 0` guard let
    // through a mathematically-positive but vanishingly small result
    // (2.0e-7 for GALA, entry=0.001934) - Pionex's own coarser-precision
    // rounding (`_resolveQuotePrecision` in engine_service.dart, tried
    // separately for the widened range) then collapsed that to exactly
    // 0.0 and rejected it outright, failing the whole open. Requiring
    // `newBottom` to be a meaningful fraction of the span (not just
    // "technically positive") catches this before it ever reaches
    // Pionex, falling back to the natural (unshifted) range exactly like
    // a truly negative result already did.
    if (newBottom <= 0 || newBottom < span * 1e-4) return natural();
    return LiquidationLevels(
      direction: direction,
      takeProfitPrice: newTop,
      stopLossPrice: newBottom,
      stopLossFraction: stableLiquidationFraction,
      stable: false,
      widenApplied: true,
      gridTop: newTop,
      gridBottom: newBottom,
    );
  } else {
    final newTop = entry + stableLiquidationFraction * span;
    final newBottom = newTop - span;
    // Same fix as the long branch above - see its comment for the full
    // live incident (GALAUSDT).
    if (newBottom <= 0 || newBottom < span * 1e-4) return natural();
    return LiquidationLevels(
      direction: direction,
      takeProfitPrice: newBottom,
      stopLossPrice: newTop,
      stopLossFraction: stableLiquidationFraction,
      stable: false,
      widenApplied: true,
      gridTop: newTop,
      gridBottom: newBottom,
    );
  }
}

/// The 60/40 model. Corrected 2026-09-11, per the user: a live bot
/// (ADAUSDT) had its take-profit edge narrowed so far inward by the
/// original version of this rule that ordinary same-day price movement
/// pushed straight through it — investigated and confirmed the original
/// rule never actually increased the real price distance from entry to
/// the stop-loss edge at all (the stop-loss edge never moved, so that
/// distance was unchanged); it only shrank the take-profit edge, which
/// made the grid worse at containing price without buying any real
/// liquidation safety. Reversed on the user's explicit instruction: the
/// **take-profit edge stays fixed at the full natural (chart-derived)
/// bound whenever possible**. When entry isn't >=60% of the span away
/// from the stop-loss edge, the **stop-loss edge itself moves further
/// away** from entry so that, measured against the fixed take-profit
/// edge, entry sits at exactly 60%/40% - this genuinely increases the
/// real price distance between entry and stop-loss, which is what
/// actually matters for staying away from liquidation.
///
/// Second correction, same day: a live pair (ETHUSDT, NEARUSDT) opened
/// with entry already ABOVE the natural top (a long) - the original
/// stability check only verified entry was far enough from the SL edge,
/// never that entry was actually inside [bottom, top] in the first
/// place. Since a live breakout can push price past the last *confirmed*
/// pivot before the pivot itself updates (that's inherent to any
/// zigzag/MSB swing indicator - a pivot only confirms once price
/// reverses), entry landing above the natural top is a real, recurring
/// condition, not a one-off fluke. Per the user's explicit instruction:
/// "expand the range so entry price is inside the price range... keeping
/// in mind 40/60... shift the range to be 40/60 according to current
/// entry price" - when entry is already past the TP-side edge entirely,
/// that edge (not the SL edge) is the one that now moves further away,
/// while the SL-side edge stays fixed at the natural bound, so entry
/// still ends up sitting at exactly 60%/40%. This is the mirror of the
/// first correction: whichever edge entry has actually moved too close
/// to (or past) is the one that gives way; the OTHER edge - the one that
/// naturally still has room - stays put.
///
/// LONG:  entry > top (past the TP side entirely): TP (top) moves
///        further up so entry sits at exactly 60% up from the fixed SL
///        (bottom). Otherwise, TP = top (fixed); if entry is <60% of the
///        span above bottom, SL (bottom) moves further down so entry
///        sits at exactly 60% up from it, TP still fixed.
/// SHORT: entry < bottom (past the TP side entirely): TP (bottom) moves
///        further down so entry sits at exactly 60% down from the fixed
///        SL (top). Otherwise, TP = bottom (fixed); if entry is <60% of
///        the span below top, SL (top) moves further up so entry sits at
///        exactly 60% down from it, TP still fixed.
///
/// Third correction, same day: a live pair (PIPPINUSDT) had its widened SL
/// solve to a NEGATIVE price - entry sat very close to a tiny bottom
/// (0.00004) while top was disproportionately far away (0.8, a ~20000x
/// span from a thin/low-liquidity pair's zigzag pivots), so pushing bottom
/// down far enough to restore exactly 60% overshot past zero. Pionex
/// rejected the resulting grid outright ("bottom must greater than 0"),
/// the whole pair silently dropped out of every report it should have
/// appeared in with no trace beyond a caught exception. "Plan B" (leave
/// the range unmodified) already existed for the case where the solved
/// edge lands on the wrong side of entry - extended to also cover the
/// solved edge landing at/below zero, an equally nonsensical result for a
/// real price.
///
/// If the solved edge would land on the wrong side of entry/the fixed
/// edge, or at/below zero (a degenerate input), the range is left
/// unmodified (`stable: false, widenApplied: false`) rather than
/// producing a nonsensical grid.
LiquidationLevels computeLiquidationLevels({
  required double top,
  required double bottom,
  required double entry,
  required GridDirection direction,
}) {
  final span = top - bottom;
  if (!span.isFinite || span <= 0) {
    throw ArgumentError('degenerate range: top ($top) <= bottom ($bottom)');
  }

  if (direction == GridDirection.long) {
    if (entry > top) {
      // Entry is already past the TP side entirely - the SL edge
      // (bottom) is the one with room, so it stays fixed at the natural
      // bound; TP (top) is what moves, further up, so entry lands at
      // exactly 60% up from the fixed bottom. Always solvable here:
      // entry > top > bottom guarantees entry > bottom, so the solved
      // top is always > entry (see the module doc comment's math).
      final adjustedTop =
          bottom + (entry - bottom) / stableLiquidationFraction;
      return LiquidationLevels(
        direction: direction,
        takeProfitPrice: adjustedTop,
        stopLossPrice: bottom,
        stopLossFraction: (entry - bottom) / (adjustedTop - bottom),
        stable: false,
        widenApplied: true,
        gridTop: adjustedTop,
        gridBottom: bottom,
      );
    }
    final fraction = (entry - bottom) / span;
    final stable = fraction >= stableLiquidationFraction;
    if (stable) {
      return LiquidationLevels(
        direction: direction,
        takeProfitPrice: top,
        stopLossPrice: bottom,
        stopLossFraction: fraction,
        stable: true,
        widenApplied: false,
        gridTop: top,
        gridBottom: bottom,
      );
    }
    // Solve for a new bottom (B') — TP edge (top) fixed — such that
    // (entry - B') / (top - B') == 0.6, i.e. entry sits at 60% up from
    // the new, lower B'. B' < bottom always, when unstable (the stop-loss
    // price moves further away from entry, never closer).
    final adjustedBottom =
        (entry - stableLiquidationFraction * top) /
        (1 - stableLiquidationFraction);
    final possible =
        adjustedBottom < entry && adjustedBottom < top && adjustedBottom > 0;
    if (possible) {
      return LiquidationLevels(
        direction: direction,
        takeProfitPrice: top,
        stopLossPrice: adjustedBottom,
        stopLossFraction: (entry - adjustedBottom) / (top - adjustedBottom),
        stable: false,
        widenApplied: true,
        gridTop: top,
        gridBottom: adjustedBottom,
      );
    }
    return LiquidationLevels(
      direction: direction,
      takeProfitPrice: top,
      stopLossPrice: bottom,
      stopLossFraction: fraction,
      stable: false,
      widenApplied: false,
      gridTop: top,
      gridBottom: bottom,
    );
  }

  // SHORT — mirror image: TP = bottom, SL = top, unless entry is already
  // past the TP side (below bottom) entirely.
  if (entry < bottom) {
    // SL edge (top) has room, stays fixed; TP (bottom) moves further
    // down so entry lands at exactly 60% down from the fixed top.
    // Mirrors the LONG case above, including its same failure mode - a
    // disproportionately large top relative to a tiny/near-zero entry can
    // solve to a negative price, invalid for a real short's TP too.
    final adjustedBottom = top - (top - entry) / stableLiquidationFraction;
    final possible = adjustedBottom < entry && adjustedBottom > 0;
    if (possible) {
      return LiquidationLevels(
        direction: direction,
        takeProfitPrice: adjustedBottom,
        stopLossPrice: top,
        stopLossFraction: (top - entry) / (top - adjustedBottom),
        stable: false,
        widenApplied: true,
        gridTop: top,
        gridBottom: adjustedBottom,
      );
    }
    return LiquidationLevels(
      direction: direction,
      takeProfitPrice: bottom,
      stopLossPrice: top,
      stopLossFraction: (top - entry) / span,
      stable: false,
      widenApplied: false,
      gridTop: top,
      gridBottom: bottom,
    );
  }
  final fraction = (top - entry) / span;
  final stable = fraction >= stableLiquidationFraction;
  if (stable) {
    return LiquidationLevels(
      direction: direction,
      takeProfitPrice: bottom,
      stopLossPrice: top,
      stopLossFraction: fraction,
      stable: true,
      widenApplied: false,
      gridTop: top,
      gridBottom: bottom,
    );
  }
  // Solve for a new top (T') — TP edge (bottom) fixed — such that
  // (T' - entry) / (T' - bottom) == 0.6, i.e. entry sits at 60% down from
  // the new, higher T'. T' > top always, when unstable.
  final adjustedTop =
      (entry - stableLiquidationFraction * bottom) /
      (1 - stableLiquidationFraction);
  final possible = adjustedTop > entry && adjustedTop > bottom;
  if (possible) {
    return LiquidationLevels(
      direction: direction,
      takeProfitPrice: bottom,
      stopLossPrice: adjustedTop,
      stopLossFraction: (adjustedTop - entry) / (adjustedTop - bottom),
      stable: false,
      widenApplied: true,
      gridTop: adjustedTop,
      gridBottom: bottom,
    );
  }
  return LiquidationLevels(
    direction: direction,
    takeProfitPrice: bottom,
    stopLossPrice: top,
    stopLossFraction: fraction,
    stable: false,
    widenApplied: false,
    gridTop: top,
    gridBottom: bottom,
  );
}
