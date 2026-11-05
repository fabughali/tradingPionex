/// Dollar TP/SL ladder (2026-10-25, per the user's exact spec): replaces the old percentage-based ratchet entirely (not
/// alongside it - per the user: "remove any old technique from code and
/// from prd"). Profit-only: below $0 floating P&L, this ladder does
/// nothing at all (the bot's existing -50% baseline SL, set once at open
/// by `_applyTpSlBaseline`, is a separate, untouched mechanism). TP is
/// never touched here either, same as the old ladder.
library;

/// Returns the highest $5-multiple threshold [profitAmount] (floating
/// P&L in USDT) has reached, or null below +$5 (no ladder protection yet
/// - the bot's baseline -50% SL is what's covering it, unchanged).
int? highestDollarThresholdCrossed(double profitAmount) {
  final t = (profitAmount / 5).floor() * 5;
  return t >= 5 ? t : null;
}

/// The dollar amount to lock in once [thresholdDollars] has been crossed:
/// +$5 locks $2 (the one special case, mirroring the old ladder's +10%->5%
/// exception); every rung from +$10 up simply follows $5 behind the
/// threshold ($10->$5, $15->$10, $20->$15, ...), continuing indefinitely.
double dollarLockFor(int thresholdDollars) =>
    (thresholdDollars == 5 ? 2 : thresholdDollars - 5).toDouble();
