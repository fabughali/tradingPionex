import 'package:flutter_test/flutter_test.dart';
import 'package:trading_pionex/data/technique/worm10_decision.dart';
import 'package:trading_pionex/data/models/signal.dart';
import 'package:trading_pionex/data/models/trade_direction.dart';

Worm10Check checkWith({
  List<Signal> zigzag = const [],
  List<Signal> supertrend = const [],
  List<RsiZoneSample> rsi = const [],
}) {
  return Worm10Check(
    symbol: 'TESTUSD',
    zigzag: BuySellCheck(symbol: 'TESTUSD', signals: zigzag, latestBarTime: null),
    supertrend: BuySellCheck(symbol: 'TESTUSD', signals: supertrend, latestBarTime: null),
    rsiZones: rsi,
    latestBarTime: null,
  );
}

void main() {
  group('worm10EventKindFromWire / toWire round-trip', () {
    test('every kind survives a wire round-trip unchanged', () {
      for (final kind in Worm10EventKind.values) {
        final wire = worm10EventKindToWire(kind);
        expect(worm10EventKindFromWire(wire), kind);
      }
    });

    test('an unknown wire string throws rather than silently defaulting', () {
      expect(() => worm10EventKindFromWire('SELL_CLOSE1'), throwsArgumentError);
    });

    test('worm10DisplayLabelOrRaw tolerates a non-worm10 wire value (e.g. Signal Flip\'s own tags)', () {
      expect(worm10DisplayLabelOrRaw('HH'), 'HH');
      expect(worm10DisplayLabelOrRaw(null), isNull);
      expect(worm10DisplayLabelOrRaw('BUY_OPEN1'), 'LL');
    });
  });

  group('deriveWorm10Events - "case 1" confluence gating (HH/LL + RSI + Supertrend)', () {
    test('LL qualifies into buyOpen1 only when RSI is blue/purple AND Supertrend is short', () {
      final check = checkWith(
        zigzag: [const Signal(tag: SignalTag.ll, time: 200)],
        supertrend: [const Signal(tag: SignalTag.sell, time: 50)],
        rsi: [const RsiZoneSample(zone: RsiZone.blue, time: 200)],
      );
      final events = deriveWorm10Events(check);
      expect(events, hasLength(1));
      expect(events.single.kind, Worm10EventKind.buyOpen1);
      expect(events.single.time, 200);
    });

    test('LL with the wrong RSI zone (white) produces no event at all', () {
      final check = checkWith(
        zigzag: [const Signal(tag: SignalTag.ll, time: 200)],
        supertrend: [const Signal(tag: SignalTag.sell, time: 50)],
        rsi: [const RsiZoneSample(zone: RsiZone.white, time: 200)],
      );
      expect(deriveWorm10Events(check), isEmpty);
    });

    test('LL with correct RSI but Supertrend still long (not yet flipped short) produces no event', () {
      final check = checkWith(
        zigzag: [const Signal(tag: SignalTag.ll, time: 200)],
        supertrend: [const Signal(tag: SignalTag.buy, time: 50)],
        rsi: [const RsiZoneSample(zone: RsiZone.purple, time: 200)],
      );
      expect(deriveWorm10Events(check), isEmpty);
    });

    test('LL with no Supertrend signal at all yet (null direction) produces no event', () {
      final check = checkWith(
        zigzag: [const Signal(tag: SignalTag.ll, time: 200)],
        supertrend: const [],
        rsi: [const RsiZoneSample(zone: RsiZone.blue, time: 200)],
      );
      expect(deriveWorm10Events(check), isEmpty);
    });

    test('HH qualifies into sellOpen1 only when RSI is green/yellow AND Supertrend is long', () {
      final check = checkWith(
        zigzag: [const Signal(tag: SignalTag.hh, time: 300)],
        supertrend: [const Signal(tag: SignalTag.buy, time: 50)],
        rsi: [const RsiZoneSample(zone: RsiZone.green, time: 300)],
      );
      final events = deriveWorm10Events(check);
      expect(events, hasLength(1));
      expect(events.single.kind, Worm10EventKind.sellOpen1);
    });

    test('Supertrend direction is sparse and persists forward until the next discrete signal', () {
      // Supertrend flips short at t=50, nothing else ever updates it - an
      // LL at t=9999 must still see "short" from that one old signal.
      final check = checkWith(
        zigzag: [const Signal(tag: SignalTag.ll, time: 9999)],
        supertrend: [const Signal(tag: SignalTag.sell, time: 50)],
        rsi: [const RsiZoneSample(zone: RsiZone.blue, time: 9999)],
      );
      expect(deriveWorm10Events(check).single.kind, Worm10EventKind.buyOpen1);
    });
  });

  group('deriveWorm10Events - "case 3" bare BUY/SELL (never gated)', () {
    test('a bare BUY tag always produces a zigzagBuy event, RSI/Supertrend irrelevant', () {
      final check = checkWith(
        zigzag: [const Signal(tag: SignalTag.buy, time: 100)],
        supertrend: const [],
        rsi: const [],
      );
      final events = deriveWorm10Events(check);
      expect(events, hasLength(1));
      expect(events.single.kind, Worm10EventKind.zigzagBuy);
    });

    test('a bare SELL tag always produces a zigzagSell event', () {
      final check = checkWith(zigzag: [const Signal(tag: SignalTag.sell, time: 100)]);
      expect(deriveWorm10Events(check).single.kind, Worm10EventKind.zigzagSell);
    });
  });

  group('deriveWorm10Events - coalescing consecutive same-kind bars into one real swing', () {
    test('buyOpen1 qualifying on every bar across a continuous run collapses to the LAST bar', () {
      final rsi = [
        for (final t in [100, 200, 300, 400]) RsiZoneSample(zone: RsiZone.blue, time: t),
      ];
      final check = checkWith(
        zigzag: [const Signal(tag: SignalTag.ll, time: 200), const Signal(tag: SignalTag.ll, time: 400)],
        supertrend: [const Signal(tag: SignalTag.sell, time: 50)],
        rsi: rsi,
      );
      final events = deriveWorm10Events(check);
      expect(events, hasLength(1), reason: 'the 200 and 400 LLs qualify on every bar in between, so they are one real swing');
      expect(events.single.time, 400);
    });

    test('a break in the qualifying condition between two LLs makes them two separate swings', () {
      final rsi = [
        const RsiZoneSample(zone: RsiZone.blue, time: 200),
        const RsiZoneSample(zone: RsiZone.white, time: 300), // breaks continuity
        const RsiZoneSample(zone: RsiZone.purple, time: 400),
      ];
      final check = checkWith(
        zigzag: [const Signal(tag: SignalTag.ll, time: 200), const Signal(tag: SignalTag.ll, time: 400)],
        supertrend: [const Signal(tag: SignalTag.sell, time: 50)],
        rsi: rsi,
      );
      final events = deriveWorm10Events(check);
      expect(events, hasLength(2), reason: 'RSI left blue/purple at t=300, so these are two distinct swings, not one');
      expect(events.map((e) => e.time).toList(), [200, 400]);
    });

    test('zigzagBuy keeps the FIRST of a consecutive run, the opposite of buyOpen1/sellOpen1', () {
      final check = checkWith(
        zigzag: [const Signal(tag: SignalTag.buy, time: 1000), const Signal(tag: SignalTag.buy, time: 1100)],
      );
      final events = deriveWorm10Events(check);
      expect(events, hasLength(1));
      expect(events.single.time, 1000, reason: 'zigzagBuy/zigzagSell mark where the signal FIRST fires, not a swing extreme');
    });
  });

  group('worm10DecisionFor - the one pure state-transition rule', () {
    test('buyOpen1 from flat opens fresh long', () {
      final d = worm10DecisionFor(null, Worm10EventKind.buyOpen1);
      expect(d.action, Worm10Action.openFresh);
      expect(d.resultDirection, TradeDirection.long);
    });

    test('buyOpen1 while already long recycles (close + reopen) the same direction', () {
      final d = worm10DecisionFor(TradeDirection.long, Worm10EventKind.buyOpen1);
      expect(d.action, Worm10Action.recycle);
      expect(d.resultDirection, TradeDirection.long);
    });

    test('buyOpen1 while short flips to long', () {
      final d = worm10DecisionFor(TradeDirection.short, Worm10EventKind.buyOpen1);
      expect(d.action, Worm10Action.flip);
      expect(d.resultDirection, TradeDirection.long);
    });

    test('sellOpen1 mirrors buyOpen1 exactly for the short side', () {
      expect(worm10DecisionFor(null, Worm10EventKind.sellOpen1).action, Worm10Action.openFresh);
      expect(worm10DecisionFor(TradeDirection.short, Worm10EventKind.sellOpen1).action, Worm10Action.recycle);
      expect(worm10DecisionFor(TradeDirection.long, Worm10EventKind.sellOpen1).action, Worm10Action.flip);
    });

    test('zigzagBuy while short flips; while long is just an Update; from flat is a no-op', () {
      expect(worm10DecisionFor(TradeDirection.short, Worm10EventKind.zigzagBuy).action, Worm10Action.flip);
      final whileLong = worm10DecisionFor(TradeDirection.long, Worm10EventKind.zigzagBuy);
      expect(whileLong.action, Worm10Action.update);
      expect(whileLong.resultDirection, TradeDirection.long);
      final fromFlat = worm10DecisionFor(null, Worm10EventKind.zigzagBuy);
      expect(fromFlat.action, Worm10Action.none);
      expect(fromFlat.resultDirection, isNull);
    });

    test('zigzagSell mirrors zigzagBuy exactly for the short side', () {
      expect(worm10DecisionFor(TradeDirection.long, Worm10EventKind.zigzagSell).action, Worm10Action.flip);
      expect(worm10DecisionFor(TradeDirection.short, Worm10EventKind.zigzagSell).action, Worm10Action.update);
      expect(worm10DecisionFor(null, Worm10EventKind.zigzagSell).action, Worm10Action.none);
    });
  });
}
