import 'package:flutter_test/flutter_test.dart';
import 'package:trading_pionex/data/technique/worm10_decision.dart';
import 'package:trading_pionex/data/models/trade_direction.dart';

void main() {
  group('worm10DecisionWithIgnite - ignite fills on the CURRENT signal', () {
    test('flat + ignited + ZIGZAG_BUY opens BUY (the ETH case)', () {
      final d = worm10DecisionWithIgnite(null, Worm10EventKind.zigzagBuy, ignited: true);
      expect(d.action, Worm10Action.openFresh);
      expect(d.resultDirection, TradeDirection.long);
    });

    test('flat + ignited + ZIGZAG_SELL opens SELL', () {
      final d = worm10DecisionWithIgnite(null, Worm10EventKind.zigzagSell, ignited: true);
      expect(d.action, Worm10Action.openFresh);
      expect(d.resultDirection, TradeDirection.short);
    });

    test('flat + NOT ignited + zigzag still never opens (strict rule unchanged)', () {
      final d = worm10DecisionWithIgnite(null, Worm10EventKind.zigzagBuy, ignited: false);
      expect(d.action, Worm10Action.none);
    });

    test('OPEN1 events behave exactly as before, ignited or not', () {
      for (final ignited in [true, false]) {
        final d = worm10DecisionWithIgnite(null, Worm10EventKind.sellOpen1, ignited: ignited);
        expect(d.action, Worm10Action.openFresh);
        expect(d.resultDirection, TradeDirection.short);
      }
    });

    test('a RUNNING trade is never changed by ignite', () {
      final flip = worm10DecisionWithIgnite(TradeDirection.short, Worm10EventKind.zigzagBuy, ignited: true);
      expect(flip.action, Worm10Action.flip);
      final update = worm10DecisionWithIgnite(TradeDirection.long, Worm10EventKind.zigzagBuy, ignited: true);
      expect(update.action, Worm10Action.update);
    });
  });
}
