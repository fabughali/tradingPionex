/// Stop Loss Lock rules (2026-11-09, per the user's exact spec). SLL is
/// mandatory for every running Auto bot - no toggle.
///
/// - A trade starts with TP and SL blank.
/// - P&L >= 200%: move money from extra margin into the investment so the
///   actual investment becomes the next whole dollar (0.55 -> 1, 1.2 -> 2,
///   2.00 -> 3), i.e. +1 each time once it is whole; repeated every check
///   while P&L stays >= 200% until extra margin is 0. If extra margin is
///   under $1, the whole extra margin is moved.
/// - P&L >= $50: SL locks profit at P&L - $20 in $10 steps ($50 -> $30,
///   $60 -> $40, ...); it only ever moves up.
library;

/// How much to move from extra margin into the investment, or 0 for none.
double sllTopUpAmount({
  required double actualInvestment,
  required double extraMargin,
}) {
  final extra = _round(extraMargin);
  if (extra <= 0) return 0;
  if (extra < 1) return extra;
  final actual = _round(actualInvestment);
  final need = _round(actual.floorToDouble() + 1 - actual);
  return need < extra ? need : extra;
}

/// The profit (USDT) SL should lock for floating P&L [profit], or null
/// below $50.
double? sllLockUsd(double profit) {
  if (profit < 50) return null;
  return ((profit / 10).floor() * 10 - 20).toDouble();
}

double _round(double v) => (v * 100).round() / 100;
