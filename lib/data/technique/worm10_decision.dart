import '../models/signal.dart';
import '../models/trade_direction.dart';

/// The third decision technique (worm_10_26 + spy_9_26, Heikin Ashi) - pure
/// decision logic, deliberately isolated from [EngineService] so it can be
/// dry-run verified against real historical signal data before ever being
/// wired into a live open/close call. 2026-10-14, per the user, after
/// extensive back-and-forth to pin down the exact spec against real
/// worm_10_26 plot data (see PRD §9.x for the full worked-example trail -
/// multiple earlier guesses were wrong and explicitly corrected).
///
/// The four distinct event kinds checked each cycle. Each implies both a
/// direction and an action class:
///
/// - [buyOpen1]/[sellOpen1] ("case 1", full confluence: HH/LL + RSI +
///   Supertrend, ALL three required - 2026-10-17, per the user's exact
///   spec: step 1 find LL/HH, step 2 Supertrend must agree (LL->sell,
///   HH->buy), step 3 RSI must agree (LL->blue/purple, HH->green/yellow);
///   if any step fails the signal is not a reference at all and is
///   IGNORED completely, not treated as a weaker close trigger - an
///   earlier "weak" [buyClose1]/[sellClose1] variant that fired on
///   HH/LL+RSI alone, without the Supertrend leg, was wrong and has been
///   removed: it caused spurious closes whenever Supertrend hadn't
///   actually flipped, confirmed live against the user's own chart on
///   2026-10-17): opens from flat; RECYCLES (close+reopen) the SAME
///   direction if it's already running ("if current trade is buy and new
///   buy open case 1 appears ... app close this trade and start buy
///   again" - confirmed directly with the user); FLIPS (closes the
///   opposite + opens this one) if the opposite direction is running.
/// - [zigzagBuy]/[zigzagSell] ("case 3", the bare all-caps BUY/SELL plot -
///   same heritage as worm_9_26, confirmed NOT the mixed-case discrete
///   Supertrend plot, and never RSI/Supertrend gated): FLIPS the opposite
///   direction if it's running; is just an Update (log only, no state
///   change) if the SAME direction is already running; no-op from flat (a
///   bare signal alone never opens a fresh trade - only case 1 can).
///
/// "Case 2" (both open and close) is never checked as an independent
/// condition - it's the automatic CONSEQUENCE of a flip above ("a SELL
/// trade closing" IS what opens the BUY, not a separate thing to verify).
enum Worm10EventKind { buyOpen1, sellOpen1, zigzagBuy, zigzagSell }

Worm10EventKind worm10EventKindFromWire(String s) => switch (s) {
  'BUY_OPEN1' => Worm10EventKind.buyOpen1,
  'SELL_OPEN1' => Worm10EventKind.sellOpen1,
  'ZIGZAG_BUY' => Worm10EventKind.zigzagBuy,
  'ZIGZAG_SELL' => Worm10EventKind.zigzagSell,
  _ => throw ArgumentError('unknown worm10 event kind: $s'),
};

String worm10EventKindToWire(Worm10EventKind k) => switch (k) {
  Worm10EventKind.buyOpen1 => 'BUY_OPEN1',
  Worm10EventKind.sellOpen1 => 'SELL_OPEN1',
  Worm10EventKind.zigzagBuy => 'ZIGZAG_BUY',
  Worm10EventKind.zigzagSell => 'ZIGZAG_SELL',
};

/// The 4-way label the GUI actually shows (2026-10-14, per the user: "in
/// open column ... there are 4 options to write.. LL or HH or Buy or
/// Sell, where LL refers to buy signal/long trade, HH refers to sell
/// signal/short trade, sell refers to zigzag sell signal, buy refers to
/// zigzag buy signal") - collapses the 6 internal kinds down to which RAW
/// chart event actually fired, not which internal case/strength it
/// satisfied: [buyOpen1] shows "LL"; [sellOpen1] shows "HH". The wire
/// string itself (persisted/used for decision logic) is unchanged - this
/// is a display-only mapping, applied wherever a worm10 event kind is
/// shown to the user.
String worm10EventKindDisplayLabel(Worm10EventKind k) => switch (k) {
  Worm10EventKind.buyOpen1 => 'LL',
  Worm10EventKind.sellOpen1 => 'HH',
  Worm10EventKind.zigzagBuy => 'Buy',
  Worm10EventKind.zigzagSell => 'Sell',
};

/// Same mapping, but tolerant of a plain string that might not even be a
/// worm10 wire value - e.g. a Signal Flip tag ("HH"/"LL"/"BUY"/"SELL") or
/// null. Returns [wire] unchanged in that case, so a single call site can
/// handle both without knowing which technique wrote it.
String? worm10DisplayLabelOrRaw(String? wire) {
  if (wire == null) return null;
  try {
    return worm10EventKindDisplayLabel(worm10EventKindFromWire(wire));
  } catch (_) {
    return wire;
  }
}

/// One worm_10_26/spy_9_26 derived event on one bar - same per-bar shape as
/// [Signal], six kinds instead of four.
class Worm10Event {
  const Worm10Event({required this.kind, required this.time});
  final Worm10EventKind kind;
  final int time;
}

/// Builds the full chronological event list from one combined
/// [Worm10Check] read - the SINGLE source both the real-time per-cycle
/// check and the retroactive audit derive from, so the two can never
/// disagree with each other.
///
/// A raw HH/LL tag only becomes an event when ALL THREE of the user's
/// steps hold for that bar: (1) the tag itself, (2) Supertrend agrees
/// (LL needs Supertrend=short, HH needs Supertrend=long), (3) RSI agrees
/// (LL needs blue/purple, HH needs green/yellow). If step 2 or 3 fails,
/// the tag is not a reference signal at all and produces NO event.
///
/// 2026-10-17 - the underlying plot/Supertrend/RSI state can all stay
/// true across MANY consecutive bars for one real swing (confirmed:
/// LTCUSDT printed a qualified LL on every bar from 10-07 21:00 through
/// 10-08 17:00, one real swing), so consecutive bars resolving to the
/// exact same kind are collapsed to the last one - one event per real
/// swing, matching what the chart actually shows, not one per bar.
List<Worm10Event> deriveWorm10Events(Worm10Check check) {
  final rsiByTime = {for (final z in check.rsiZones) z.time: z.zone};

  // Supertrend's own latest-known direction as of any bar time - sparse,
  // persists forward until the next discrete signal (2026-10-14, per the
  // user: "supertrend need to be sell" means the STATE the last discrete
  // Supertrend signal established, not a per-bar flag).
  final supertrendSorted = [...check.supertrend.signals]..sort((a, b) => a.time.compareTo(b.time));
  TradeDirection? supertrendDirectionAt(int t) {
    TradeDirection? dir;
    for (final s in supertrendSorted) {
      if (s.time > t) break;
      dir = s.tag == SignalTag.buy ? TradeDirection.long : TradeDirection.short;
    }
    return dir;
  }

  final events = <Worm10Event>[];
  for (final s in check.zigzag.signals) {
    final zone = rsiByTime[s.time];
    switch (s.tag) {
      case SignalTag.hh:
        final rsiOk = zone == RsiZone.yellow || zone == RsiZone.green;
        if (!rsiOk) break;
        if (supertrendDirectionAt(s.time) == TradeDirection.long) {
          events.add(Worm10Event(kind: Worm10EventKind.sellOpen1, time: s.time));
        }
      case SignalTag.ll:
        final rsiOk = zone == RsiZone.blue || zone == RsiZone.purple;
        if (!rsiOk) break;
        if (supertrendDirectionAt(s.time) == TradeDirection.short) {
          events.add(Worm10Event(kind: Worm10EventKind.buyOpen1, time: s.time));
        }
      case SignalTag.buy:
        events.add(Worm10Event(kind: Worm10EventKind.zigzagBuy, time: s.time));
      case SignalTag.sell:
        events.add(Worm10Event(kind: Worm10EventKind.zigzagSell, time: s.time));
    }
  }
  events.sort((a, b) => a.time.compareTo(b.time));

  // zigzagBuy/zigzagSell (the bare BUY/SELL tag pair) mark where the
  // signal FIRST fires, not a swing extreme like HH/LL - keep the first
  // of each run for those two kinds (plain list-adjacency is correct
  // here; they're not RSI/Supertrend-gated).
  //
  // buyOpen1/sellOpen1 are different: two occurrences of the same kind
  // only belong to the same real swing if the qualifying condition
  // (RSI zone + Supertrend direction) holds on EVERY bar in between, not
  // merely "nothing else happened in between" - confirmed live
  // (LTCUSDT): a qualifying LL at 10-13 00:00 and another at 10-14 14:00
  // are 38h apart with RSI genuinely leaving blue/purple (going "white")
  // for ~16h in between - two separate swings, each with its own close.
  // But that 10-14 14:00 LL and a third one at 10-15 02:00, 12h apart,
  // have RSI staying blue on EVERY bar in between with no break - one
  // continuous swing, correctly collapsed to the last (10-15 02:00).
  final allBarTimesSorted = rsiByTime.keys.toList()..sort();

  bool conditionHoldsAt(Worm10EventKind kind, int t) {
    final zone = rsiByTime[t];
    switch (kind) {
      case Worm10EventKind.buyOpen1:
        return (zone == RsiZone.blue || zone == RsiZone.purple) &&
            supertrendDirectionAt(t) == TradeDirection.short;
      case Worm10EventKind.sellOpen1:
        return (zone == RsiZone.yellow || zone == RsiZone.green) &&
            supertrendDirectionAt(t) == TradeDirection.long;
      case Worm10EventKind.zigzagBuy:
      case Worm10EventKind.zigzagSell:
        return false;
    }
  }

  bool sameSwing(Worm10Event a, Worm10Event b) {
    if (a.kind != b.kind) return false;
    for (final t in allBarTimesSorted) {
      if (t <= a.time) continue;
      if (t >= b.time) break;
      if (!conditionHoldsAt(a.kind, t)) return false;
    }
    return true;
  }

  bool keepsFirstOfRun(Worm10EventKind k) =>
      k == Worm10EventKind.zigzagBuy || k == Worm10EventKind.zigzagSell;

  final coalesced = <Worm10Event>[];
  for (var i = 0; i < events.length; i++) {
    final isFirstOfRun = i == 0 ||
        (keepsFirstOfRun(events[i].kind)
            ? events[i - 1].kind != events[i].kind
            : !sameSwing(events[i - 1], events[i]));
    final isLastOfRun = i == events.length - 1 ||
        (keepsFirstOfRun(events[i].kind)
            ? events[i + 1].kind != events[i].kind
            : !sameSwing(events[i], events[i + 1]));
    final keep = keepsFirstOfRun(events[i].kind) ? isFirstOfRun : isLastOfRun;
    if (keep) coalesced.add(events[i]);
  }
  return coalesced;
}

enum Worm10Action { openFresh, recycle, flip, update, none }

class Worm10Decision {
  const Worm10Decision({required this.action, required this.resultDirection});

  final Worm10Action action;

  /// The direction the pair is in AFTER this event resolves - null only
  /// when [action] is [Worm10Action.none] and nothing was running before
  /// either.
  final TradeDirection? resultDirection;
}

/// The one pure state-transition rule, applied to a single event against
/// whatever is currently running ([current] - null means flat/waiting).
/// Used identically by the real-time per-cycle check (against the single
/// latest event) and the retroactive audit (walked forward across every
/// event since the running position's own recorded Start) - see this
/// file's own top-of-file doc comment for the full case-by-case reasoning,
/// confirmed directly with the user across multiple corrected rounds.
Worm10Decision worm10DecisionFor(TradeDirection? current, Worm10EventKind kind) {
  switch (kind) {
    case Worm10EventKind.buyOpen1:
      if (current == null) {
        return const Worm10Decision(action: Worm10Action.openFresh, resultDirection: TradeDirection.long);
      }
      if (current == TradeDirection.long) {
        return const Worm10Decision(action: Worm10Action.recycle, resultDirection: TradeDirection.long);
      }
      return const Worm10Decision(action: Worm10Action.flip, resultDirection: TradeDirection.long);
    case Worm10EventKind.sellOpen1:
      if (current == null) {
        return const Worm10Decision(action: Worm10Action.openFresh, resultDirection: TradeDirection.short);
      }
      if (current == TradeDirection.short) {
        return const Worm10Decision(action: Worm10Action.recycle, resultDirection: TradeDirection.short);
      }
      return const Worm10Decision(action: Worm10Action.flip, resultDirection: TradeDirection.short);
    case Worm10EventKind.zigzagBuy:
      if (current == TradeDirection.short) {
        return const Worm10Decision(action: Worm10Action.flip, resultDirection: TradeDirection.long);
      }
      if (current == TradeDirection.long) {
        return const Worm10Decision(action: Worm10Action.update, resultDirection: TradeDirection.long);
      }
      return const Worm10Decision(action: Worm10Action.none, resultDirection: null);
    case Worm10EventKind.zigzagSell:
      if (current == TradeDirection.long) {
        return const Worm10Decision(action: Worm10Action.flip, resultDirection: TradeDirection.short);
      }
      if (current == TradeDirection.short) {
        return const Worm10Decision(action: Worm10Action.update, resultDirection: TradeDirection.short);
      }
      return const Worm10Decision(action: Worm10Action.none, resultDirection: null);
  }
}

/// Ignite = fill on the CURRENT signal (2026-10-20, per the user: "once
/// pair is ignited, this pair will be filled according to current signal.
/// app will not wait for new signal to occur ... decide what is the signal
/// direction, then make the filling"). Only ever changes the outcome for a
/// FLAT ignited pair whose latest event is a bare zigzag (which
/// [worm10DecisionFor] deliberately never opens on) - it opens in that
/// event's direction instead. Everything else (running trades, OPEN1
/// events, non-ignited pairs) is returned unchanged.
Worm10Decision worm10DecisionWithIgnite(TradeDirection? current, Worm10EventKind kind, {required bool ignited}) {
  final base = worm10DecisionFor(current, kind);
  if (!ignited || current != null || base.action != Worm10Action.none) return base;
  return Worm10Decision(
    action: Worm10Action.openFresh,
    resultDirection: kind == Worm10EventKind.zigzagBuy || kind == Worm10EventKind.buyOpen1
        ? TradeDirection.long
        : TradeDirection.short,
  );
}
