import 'package:flutter_test/flutter_test.dart';
import 'package:trading_pionex/data/technique/worm10_decision.dart';

Worm10Bar _bar({
  required int t,
  bool hh = false,
  bool ll = false,
  bool zb = false,
  bool zs = false,
  bool stBuy = false,
  bool stSell = false,
  String? zone,
}) => Worm10Bar(
  time: t,
  hh: hh,
  ll: ll,
  zigzagBuy: zb,
  zigzagSell: zs,
  stBuy: stBuy,
  stSell: stSell,
  rsiZone: zone,
);

void main() {
  group('deriveWorm10Events', () {
    test('HH without Supertrend-buy state is ignored completely', () {
      final events = deriveWorm10Events([
        _bar(t: 1, stSell: true, zone: 'green'),
        _bar(t: 2, hh: true, zone: 'green'), // state is sell, not buy -> ignored
      ]);
      expect(events, isEmpty);
    });

    test('HH without the right RSI zone is ignored completely', () {
      final events = deriveWorm10Events([
        _bar(t: 1, stBuy: true, zone: 'white'),
        _bar(t: 2, hh: true, zone: 'white'), // state buy, but zone not green/yellow
      ]);
      expect(events, isEmpty);
    });

    test('full confluence on one bar fires SELL_OPEN1', () {
      final events = deriveWorm10Events([
        _bar(t: 1, stBuy: true, zone: 'green'),
        _bar(t: 2, hh: true, zone: 'green'),
      ]);
      expect(events, [const Worm10Event(type: Worm10EventType.sellOpen1, time: 2)]);
    });

    test('HH repeats across several bars with confluence held throughout -> one swing, last bar kept', () {
      final events = deriveWorm10Events([
        _bar(t: 1, stBuy: true, zone: 'green'),
        _bar(t: 2, hh: true, zone: 'green'),
        _bar(t: 3, zone: 'green'), // no HH this bar, confluence still holds
        _bar(t: 4, hh: true, zone: 'yellow'), // HH again, zone moved but still valid
        _bar(t: 5, zone: 'yellow'),
      ]);
      expect(events, [const Worm10Event(type: Worm10EventType.sellOpen1, time: 4)]);
    });

    test('RSI leaving the zone in between splits into two separate swings', () {
      final events = deriveWorm10Events([
        _bar(t: 1, stBuy: true, zone: 'green'),
        _bar(t: 2, hh: true, zone: 'green'),
        _bar(t: 3, zone: 'white'), // confluence breaks here
        _bar(t: 4, zone: 'green'), // confluence resumes, but this is a NEW run
        _bar(t: 5, hh: true, zone: 'green'),
      ]);
      expect(events, [
        const Worm10Event(type: Worm10EventType.sellOpen1, time: 2),
        const Worm10Event(type: Worm10EventType.sellOpen1, time: 5),
      ]);
    });

    test('Supertrend flip in between also splits into two swings', () {
      final events = deriveWorm10Events([
        _bar(t: 1, stBuy: true, zone: 'green'),
        _bar(t: 2, hh: true, zone: 'green'),
        _bar(t: 3, stSell: true, zone: 'green'), // state flips to sell mid-run
        _bar(t: 4, stBuy: true, zone: 'green'), // flips back to buy
        _bar(t: 5, hh: true, zone: 'green'),
      ]);
      expect(events, [
        const Worm10Event(type: Worm10EventType.sellOpen1, time: 2),
        const Worm10Event(type: Worm10EventType.sellOpen1, time: 5),
      ]);
    });

    test('zigzag BUY keeps only the first, even across a gap with nothing in between', () {
      final events = deriveWorm10Events([
        _bar(t: 1, zb: true),
        _bar(t: 2, zb: true),
        _bar(t: 3, zb: true),
        _bar(t: 4),
        _bar(t: 5, zb: true),
      ]);
      expect(events, [const Worm10Event(type: Worm10EventType.zigzagBuy, time: 1)]);
    });

    test('a different event between two zigzag BUYs keeps both', () {
      final events = deriveWorm10Events([
        _bar(t: 1, zb: true),
        _bar(t: 2, zs: true),
        _bar(t: 3),
        _bar(t: 4, zb: true),
      ]);
      expect(events, [
        const Worm10Event(type: Worm10EventType.zigzagBuy, time: 1),
        const Worm10Event(type: Worm10EventType.zigzagSell, time: 2),
        const Worm10Event(type: Worm10EventType.zigzagBuy, time: 4),
      ]);
    });

    test('a zigzag between two matching HHs keeps both HHs', () {
      final events = deriveWorm10Events([
        _bar(t: 1, stBuy: true, zone: 'green'),
        _bar(t: 2, hh: true, zone: 'green'),
        _bar(t: 3, zs: true, zone: 'green'),
        _bar(t: 4, hh: true, zone: 'green'),
      ]);
      expect(events, [
        const Worm10Event(type: Worm10EventType.sellOpen1, time: 2),
        const Worm10Event(type: Worm10EventType.zigzagSell, time: 3),
        const Worm10Event(type: Worm10EventType.sellOpen1, time: 4),
      ]);
    });

    test('a bar with no RSI reading does not break a swing', () {
      final events = deriveWorm10Events([
        _bar(t: 1, stBuy: true, zone: 'green'),
        _bar(t: 2, hh: true, zone: 'green'),
        _bar(t: 3),
        _bar(t: 4, hh: true, zone: 'green'),
      ]);
      expect(events, [const Worm10Event(type: Worm10EventType.sellOpen1, time: 4)]);
    });

    test('Supertrend state persists forward from one old tick', () {
      final events = deriveWorm10Events([
        _bar(t: 50, stSell: true),
        _bar(t: 9999, ll: true, zone: 'blue'),
      ]);
      expect(events, [const Worm10Event(type: Worm10EventType.buyOpen1, time: 9999)]);
    });

    test('no Supertrend tick yet means no OPEN1', () {
      expect(deriveWorm10Events([_bar(t: 200, ll: true, zone: 'blue')]), isEmpty);
    });

    test('same-bar Supertrend tick counts for that same bar\'s own confluence check', () {
      final events = deriveWorm10Events([
        _bar(t: 1, stSell: true, zone: 'green'),
        // stBuy and HH fire on the exact same bar - state must already be
        // "buy" for THIS bar's own HH check, not lag by one bar.
        _bar(t: 2, stBuy: true, hh: true, zone: 'green'),
      ]);
      expect(events, [const Worm10Event(type: Worm10EventType.sellOpen1, time: 2)]);
    });

    test('unsorted input is sorted before processing', () {
      final events = deriveWorm10Events([
        _bar(t: 2, hh: true, zone: 'green'),
        _bar(t: 1, stBuy: true, zone: 'green'),
      ]);
      expect(events, [const Worm10Event(type: Worm10EventType.sellOpen1, time: 2)]);
    });
  });

  group('candle timing (bar time is the OPEN time)', () {
    const hour = Duration(hours: 1);
    const bar = 1800000000;
    DateTime at(int sec) =>
        DateTime.fromMillisecondsSinceEpoch(sec * 1000, isUtc: true);

    test('still-forming candle is not closed; closes at +1 period', () {
      expect(isCandleClosed(bar, hour, at(bar + 3599)), isFalse);
      expect(isCandleClosed(bar, hour, at(bar + 3600)), isTrue);
    });

    test('the wait ends at +2 periods, one full candle after its own close', () {
      expect(worm10WaitIsOver(bar, hour, at(bar + 3600)), isFalse);
      expect(worm10WaitIsOver(bar, hour, at(bar + 7199)), isFalse);
      expect(worm10WaitIsOver(bar, hour, at(bar + 7200)), isTrue);
    });
  });

  group('worm10DecisionFor', () {
    test('no trade + OPEN1 opens; bare zigzag does nothing', () {
      expect(
        worm10DecisionFor(Worm10Running.none, Worm10EventType.buyOpen1).action,
        Worm10Action.open,
      );
      expect(
        worm10DecisionFor(Worm10Running.none, Worm10EventType.sellOpen1).action,
        Worm10Action.open,
      );
      expect(
        worm10DecisionFor(Worm10Running.none, Worm10EventType.zigzagBuy).action,
        Worm10Action.none,
      );
      expect(
        worm10DecisionFor(Worm10Running.none, Worm10EventType.zigzagSell).action,
        Worm10Action.none,
      );
    });

    test('BUY running: recycle on BUY_OPEN1, flip on SELL_OPEN1 or ZIGZAG_SELL, update-only on ZIGZAG_BUY', () {
      expect(
        worm10DecisionFor(Worm10Running.buy, Worm10EventType.buyOpen1).action,
        Worm10Action.recycle,
      );
      final flipFromSellOpen1 = worm10DecisionFor(Worm10Running.buy, Worm10EventType.sellOpen1);
      expect(flipFromSellOpen1.action, Worm10Action.flip);
      expect(flipFromSellOpen1.direction, Worm10Direction.sell);
      final flipFromZigzagSell = worm10DecisionFor(Worm10Running.buy, Worm10EventType.zigzagSell);
      expect(flipFromZigzagSell.action, Worm10Action.flip);
      expect(flipFromZigzagSell.direction, Worm10Direction.sell);
      expect(
        worm10DecisionFor(Worm10Running.buy, Worm10EventType.zigzagBuy).action,
        Worm10Action.updateOnly,
      );
    });

    test('SELL running: mirror of BUY running', () {
      expect(
        worm10DecisionFor(Worm10Running.sell, Worm10EventType.sellOpen1).action,
        Worm10Action.recycle,
      );
      final flipFromBuyOpen1 = worm10DecisionFor(Worm10Running.sell, Worm10EventType.buyOpen1);
      expect(flipFromBuyOpen1.action, Worm10Action.flip);
      expect(flipFromBuyOpen1.direction, Worm10Direction.buy);
      final flipFromZigzagBuy = worm10DecisionFor(Worm10Running.sell, Worm10EventType.zigzagBuy);
      expect(flipFromZigzagBuy.action, Worm10Action.flip);
      expect(flipFromZigzagBuy.direction, Worm10Direction.buy);
      expect(
        worm10DecisionFor(Worm10Running.sell, Worm10EventType.zigzagSell).action,
        Worm10Action.updateOnly,
      );
    });
  });
}
