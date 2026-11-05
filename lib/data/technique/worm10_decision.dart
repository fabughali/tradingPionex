/// Worm10 Hybrid Decision technique (2026-10-25, per the user) — pure,
/// zero-I/O event derivation from raw per-bar worm_10_26/spy_9_26 data.
/// Implemented natively against this codebase (not ported) from the
/// user's own plain-language spec, confirmed live via CDP against the
/// real chart before any of this was written — see
/// `lib/data/tradingview/signals_reader.dart`'s `readWorm10Bars` for the
/// CDP-reading half this feeds from. Replaces the worm_9_26 technique
/// entirely, per the user: "and remove any old technique from code and
/// from prd."

/// One raw bar's worth of worm_10_26/spy_9_26 plot data. `rsiZone` is one
/// of 'blue'/'purple'/'white'/'green'/'yellow', or null if spy_9_26 had no
/// reading for this bar time.
class Worm10Bar {
  const Worm10Bar({
    required this.time,
    required this.hh,
    required this.ll,
    required this.zigzagBuy,
    required this.zigzagSell,
    required this.stBuy,
    required this.stSell,
    required this.rsiZone,
  });

  final int time;
  final bool hh;
  final bool ll;
  final bool zigzagBuy;
  final bool zigzagSell;
  final bool stBuy;
  final bool stSell;
  final String? rsiZone;
}

enum Worm10EventType { buyOpen1, sellOpen1, zigzagBuy, zigzagSell }

class Worm10Event {
  const Worm10Event({required this.type, required this.time});
  final Worm10EventType type;
  final int time;

  @override
  bool operator ==(Object other) =>
      other is Worm10Event && other.type == type && other.time == time;

  @override
  int get hashCode => Object.hash(type, time);

  @override
  String toString() => '${type.name}@$time';
}

/// Derives the full event stream from raw bars, per the user's exact spec:
///
/// - OPEN1 confluence (§3a): SELL_OPEN1 requires HH on that bar AND the
///   Supertrend state is `buy` AND the RSI zone is green/yellow;
///   BUY_OPEN1 is the mirror (LL, state `sell`, zone blue/purple). Any HH/LL
///   where the other two conditions don't hold is "ignored completely" -
///   never even considered, not treated as a weaker signal.
/// - Supertrend *state* (not just the discrete tick): the most recent
///   `stBuy`/`stSell` at or before each bar, carried forward - a same-bar
///   tick counts for that same bar's own confluence check.
/// - Swing dedup (§3, "removing duplicates"): two neighbouring OPEN1 events
///   of the same kind are one swing if the confluence held on every bar
///   between them - only the LAST survives. If the confluence breaks (RSI
///   leaves the zone, or Supertrend flips), or a different event falls
///   between them, they stay separate.
/// - Zigzag (§3b): bare `BUY`/`SELL`, no RSI/Supertrend check at all - only
///   the first of neighbouring same-kind events is kept, even across a gap,
///   since nothing else happened in between.
///
/// Bars are sorted by time first; the input order doesn't matter. The
/// returned list is sorted by time ascending.
List<Worm10Event> deriveWorm10Events(List<Worm10Bar> bars) {
  final sorted = [...bars]..sort((a, b) => a.time.compareTo(b.time));

  // Supertrend's state as of each bar: the latest discrete tick at or before
  // it, carried forward. Recorded per bar so the swing check below can look
  // back at any bar in between two events.
  final stIsBuyAt = <int, bool?>{};
  bool? stIsBuy;
  for (final bar in sorted) {
    if (bar.stBuy) stIsBuy = true;
    if (bar.stSell) stIsBuy = false;
    stIsBuyAt[bar.time] = stIsBuy;
  }

  bool buyHolds(Worm10Bar bar) =>
      stIsBuyAt[bar.time] == false &&
      (bar.rsiZone == 'blue' || bar.rsiZone == 'purple');
  bool sellHolds(Worm10Bar bar) =>
      stIsBuyAt[bar.time] == true &&
      (bar.rsiZone == 'green' || bar.rsiZone == 'yellow');

  final events = <Worm10Event>[];
  var inZigzagBuyRun = false;
  var inZigzagSellRun = false;
  for (final bar in sorted) {
    if (bar.hh && sellHolds(bar)) {
      events.add(Worm10Event(type: Worm10EventType.sellOpen1, time: bar.time));
    }
    if (bar.ll && buyHolds(bar)) {
      events.add(Worm10Event(type: Worm10EventType.buyOpen1, time: bar.time));
    }
    if (bar.zigzagBuy && !inZigzagBuyRun) {
      events.add(Worm10Event(type: Worm10EventType.zigzagBuy, time: bar.time));
    }
    if (bar.zigzagSell && !inZigzagSellRun) {
      events.add(Worm10Event(type: Worm10EventType.zigzagSell, time: bar.time));
    }
    inZigzagBuyRun = bar.zigzagBuy;
    inZigzagSellRun = bar.zigzagSell;
  }

  // Neighbouring events of one OPEN1 kind are one swing only if the condition
  // held on every bar between them. A bar with no RSI reading says nothing
  // either way, so it's skipped rather than treated as a break.
  bool sameSwing(Worm10Event a, Worm10Event b) {
    if (a.type != b.type) return false;
    for (final bar in sorted) {
      if (bar.rsiZone == null || bar.time <= a.time) continue;
      if (bar.time >= b.time) break;
      final holds = a.type == Worm10EventType.buyOpen1
          ? buyHolds(bar)
          : sellHolds(bar);
      if (!holds) return false;
    }
    return true;
  }

  bool isZigzag(Worm10EventType t) =>
      t == Worm10EventType.zigzagBuy || t == Worm10EventType.zigzagSell;

  final kept = <Worm10Event>[];
  for (var i = 0; i < events.length; i++) {
    final e = events[i];
    if (isZigzag(e.type)) {
      // A zigzag marks where the signal FIRST fires: keep the first of
      // neighbouring same-kind events.
      if (i == 0 || events[i - 1].type != e.type) kept.add(e);
    } else {
      // HH/LL print on every fresh extreme of a swing: keep the last.
      if (i == events.length - 1 || !sameSwing(e, events[i + 1])) kept.add(e);
    }
  }
  return kept;
}

/// Whether the candle opened at [barTimeSec] has closed. A bar's time is its
/// OPEN time, so it closes one [period] later.
bool isCandleClosed(int barTimeSec, Duration period, DateTime now) =>
    now.toUtc().millisecondsSinceEpoch >=
    (barTimeSec + period.inSeconds) * 1000;

/// Whether the signal on the bar opened at [barTimeSec] has waited out its
/// own candle plus one more full candle: bar time + 2 periods (+2 hours on
/// 1H), §5 of the user's spec.
bool worm10WaitIsOver(int barTimeSec, Duration period, DateTime now) =>
    now.toUtc().millisecondsSinceEpoch >=
    (barTimeSec + period.inSeconds * 2) * 1000;

enum Worm10Direction { buy, sell }

/// Which side a bare event type represents, independent of any running
/// state - used wherever code needs "which way does this event point"
/// without going through the full decision table (voice announcements,
/// display-only previews). buyOpen1/zigzagBuy -> buy; sellOpen1/zigzagSell
/// -> sell.
Worm10Direction worm10EventDirection(Worm10EventType type) =>
    switch (type) {
      Worm10EventType.buyOpen1 || Worm10EventType.zigzagBuy => Worm10Direction.buy,
      Worm10EventType.sellOpen1 || Worm10EventType.zigzagSell => Worm10Direction.sell,
    };

/// Current running state for one pair/category, as the decision table
/// (§4 of the spec) understands it.
enum Worm10Running { none, buy, sell }

enum Worm10Action { open, recycle, flip, updateOnly, none }

class Worm10Decision {
  const Worm10Decision({
    required this.action,
    this.direction,
  });
  final Worm10Action action;
  final Worm10Direction? direction;
}

/// The decision table itself (§4), pure and total - every (running, event)
/// combination the spec defines, nothing inferred. `event` is the single
/// most recent qualifying event as of the moment this fires (already
/// triple-read-confirmed and past the survive-one-candle wait by the
/// caller - this function has no notion of timing at all).
Worm10Decision worm10DecisionFor(
  Worm10Running running,
  Worm10EventType event,
) {
  switch (running) {
    case Worm10Running.none:
      switch (event) {
        case Worm10EventType.buyOpen1:
          return const Worm10Decision(
            action: Worm10Action.open,
            direction: Worm10Direction.buy,
          );
        case Worm10EventType.sellOpen1:
          return const Worm10Decision(
            action: Worm10Action.open,
            direction: Worm10Direction.sell,
          );
        case Worm10EventType.zigzagBuy:
        case Worm10EventType.zigzagSell:
          return const Worm10Decision(action: Worm10Action.none);
      }
    case Worm10Running.buy:
      switch (event) {
        case Worm10EventType.buyOpen1:
          return const Worm10Decision(
            action: Worm10Action.recycle,
            direction: Worm10Direction.buy,
          );
        case Worm10EventType.sellOpen1:
        case Worm10EventType.zigzagSell:
          return const Worm10Decision(
            action: Worm10Action.flip,
            direction: Worm10Direction.sell,
          );
        case Worm10EventType.zigzagBuy:
          return const Worm10Decision(action: Worm10Action.updateOnly);
      }
    case Worm10Running.sell:
      switch (event) {
        case Worm10EventType.sellOpen1:
          return const Worm10Decision(
            action: Worm10Action.recycle,
            direction: Worm10Direction.sell,
          );
        case Worm10EventType.buyOpen1:
        case Worm10EventType.zigzagBuy:
          return const Worm10Decision(
            action: Worm10Action.flip,
            direction: Worm10Direction.buy,
          );
        case Worm10EventType.zigzagSell:
          return const Worm10Decision(action: Worm10Action.updateOnly);
      }
  }
}
