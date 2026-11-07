import '../models/grid_bot.dart' show GridDirection;
import '../models/trade_direction.dart';
import 'worm10_decision.dart';

/// The only glue between tradingMT5's Hybrid Decision (worm10_decision.dart,
/// copied unchanged) and Pionex grids. tradingMT5 trades one MT5 position
/// per pair in a [TradeDirection]; here the same decision drives one grid
/// bot per pair in a [GridDirection]. Nothing in here decides anything.

GridDirection gridDirectionOf(TradeDirection d) =>
    d == TradeDirection.long ? GridDirection.long : GridDirection.short;

TradeDirection tradeDirectionOf(GridDirection d) =>
    d == GridDirection.long ? TradeDirection.long : TradeDirection.short;

/// The direction an event points to on its own (what an ignited, flat pair
/// opens on), the same mapping [worm10DecisionWithIgnite] uses.
TradeDirection worm10EventDirection(Worm10EventKind kind) =>
    kind == Worm10EventKind.buyOpen1 || kind == Worm10EventKind.zigzagBuy
    ? TradeDirection.long
    : TradeDirection.short;

/// tradingMT5's "survive one full extra candle" wait: an event on the bar
/// opened at [barTimeSec] may be acted on once `barTime + 2 periods` has
/// passed (its own candle plus one more), same as its
/// `pending.barTime + category.candlePeriod.inSeconds * 2` check.
bool worm10WaitIsOver(int barTimeSec, Duration period, DateTime now) =>
    now.toUtc().millisecondsSinceEpoch ~/ 1000 >=
    barTimeSec + period.inSeconds * 2;
