enum SignalSide { buy, sell }

/// The four raw tags worm_9_26 itself plots — `New Higher High` (HH),
/// `New Lower Low` (LL), and its own separate `BUY`/`SELL` plotshape pair
/// (2026-09-29, per the user: replaces the old two-indicator HH/LL +
/// RSI-zone confirmation entirely — "remove old decision detection... use
/// this new one" — worm_9_26 alone now drives every decision; spy_9_26
/// still has to be attached for the app to run at all, but its data is no
/// longer read for signal purposes).
enum SignalTag { hh, ll, buy, sell }

SignalTag signalTagFromWire(String s) => switch (s) {
  'HH' => SignalTag.hh,
  'LL' => SignalTag.ll,
  'BUY' => SignalTag.buy,
  'SELL' => SignalTag.sell,
  _ => throw ArgumentError('unknown signal tag: $s'),
};

String signalTagToWire(SignalTag t) => switch (t) {
  SignalTag.hh => 'HH',
  SignalTag.ll => 'LL',
  SignalTag.buy => 'BUY',
  SignalTag.sell => 'SELL',
};

/// One confirmed worm_9_26 tag on one bar (see
/// lib/tradingview/signals_reader.dart, `readSwingOscillatorSignals`).
/// `time` is the bar's open time in epoch seconds — the same value used as
/// the new-candle anchor (`latestBarTime`).
class Signal {
  const Signal({required this.tag, required this.time});

  final SignalTag tag;
  final int time;

  /// Direction this tag implies on its own, per the user's spec: HH and
  /// SELL both mean short/sell; LL and BUY both mean long/buy.
  SignalSide get side =>
      (tag == SignalTag.ll || tag == SignalTag.buy) ? SignalSide.buy : SignalSide.sell;

  factory Signal.fromJson(Map<String, dynamic> json) =>
      Signal(tag: signalTagFromWire(json['tag'] as String), time: (json['time'] as num).toInt());
}

/// Result of reading worm_9_26's HH/LL/BUY/SELL tag history for one pair.
class BuySellCheck {
  const BuySellCheck({
    required this.symbol,
    required this.signals,
    required this.latestBarTime,
  });

  final String symbol;
  final List<Signal> signals;

  /// The newest 1H candle's open time — the anchor bot-grid.js's candle gate
  /// compares against `lastHourlyCandleTs` to detect a freshly-created bar.
  /// Null means the indicator's data window has not populated yet (distinct
  /// from "loaded but genuinely no signal"), which is what the indicator
  /// retry ladder (EngineService) waits out.
  final int? latestBarTime;

  /// The latest (by time) tag of any kind, or null if none yet. Ties
  /// (two tags on the exact same bar) resolve to whichever [signals] lists
  /// first, since [readSwingOscillatorSignals] always pushes a bar's tags
  /// in a fixed HH/LL/BUY/SELL order.
  Signal? get latest {
    if (signals.isEmpty) return null;
    return signals.reduce((a, b) => b.time > a.time ? b : a);
  }
}

/// spy_9_26's five RSI zone plots (2026-10-14, per the third decision
/// technique's own spec) - confirmed live via CDP, exact titles: `RSI <=
/// 20% (Blue)`, `RSI 20-35% (Purple)`, `RSI 35-65% (White)`, `RSI 65-80%
/// (Green)`, `RSI >= 80% (Yellow)`. Blue/purple are the oversold pair (blue
/// stronger), green/yellow the overbought pair (yellow stronger) - matches
/// the user's own wording exactly ("rsi should be purple or blue.. blue is
/// better" / "rsi in yellow or green area .. yellow is better").
enum RsiZone { blue, purple, white, green, yellow }

/// One RSI zone reading on one bar - same per-bar shape as [Signal], just a
/// 5-way zone instead of a 4-way tag (spy_9_26 plots all five as mutually
/// exclusive, so at most one is ever true per bar).
class RsiZoneSample {
  const RsiZoneSample({required this.zone, required this.time});
  final RsiZone zone;
  final int time;
}

/// worm_10_26 + spy_9_26 combined, for the third decision technique
/// (2026-10-14). Deliberately TWO separate [BuySellCheck]s, not one merged
/// list - [zigzag] (HH/LL/BUY/SELL, all-caps, same heritage as worm_9_26)
/// drives the close-signal "case 3" only; [supertrend] (Buy/Sell, mixed
/// case) drives the open-signal "case 1" confluence's "supertrend need to
/// be X" leg only - confirmed directly with the user after an initial
/// wrong guess, see [readWorm10Signals]'s own doc comment. Never confuse
/// the two - same script, four different plots, two different jobs.
class Worm10Check {
  const Worm10Check({
    required this.symbol,
    required this.zigzag,
    required this.supertrend,
    required this.rsiZones,
    required this.latestBarTime,
  });

  final String symbol;
  final BuySellCheck zigzag;
  final BuySellCheck supertrend;
  final List<RsiZoneSample> rsiZones;

  /// The newest 1H candle's open time, same role as [BuySellCheck]'s own
  /// field - null means the indicator's data hasn't populated yet.
  final int? latestBarTime;

  /// The latest (by time) RSI zone, or null if none read yet.
  RsiZone? get latestRsiZone {
    if (rsiZones.isEmpty) return null;
    return rsiZones.reduce((a, b) => b.time > a.time ? b : a).zone;
  }
}
