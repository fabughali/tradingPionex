import 'grid_bot.dart';

/// Result of the 60/40 liquidation-avoidance model (lib/technique/liquidation.dart).
/// Whichever edge (TP or SL) entry hasn't moved too close to (or past) stays
/// fixed at the natural chart-derived bound; the OTHER edge may have been
/// widened (`widenApplied`) so entry lands at exactly 60% of the span away
/// from it. See PRD §4.6 and the original `liquidationLevels()`.
class LiquidationLevels {
  const LiquidationLevels({
    required this.direction,
    required this.takeProfitPrice,
    required this.stopLossPrice,
    required this.stopLossFraction,
    required this.stable,
    required this.widenApplied,
    required this.gridTop,
    required this.gridBottom,
  });

  final GridDirection direction;
  final double takeProfitPrice;
  final double stopLossPrice;
  final double stopLossFraction;

  /// True when entry was already >=60% of the span from the SL edge — no
  /// range change was needed.
  final bool stable;

  /// True when Option 2 (widen the SL side so entry lands at exactly 60%)
  /// was applied. False means either it was already stable, or Option 1
  /// (degenerate widen — keep the original range, just record the SL price).
  final bool widenApplied;

  /// The final grid edges to actually send to Pionex (may differ from the
  /// input top/bottom when widenApplied is true).
  final double gridTop;
  final double gridBottom;
}
