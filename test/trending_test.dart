import 'package:flutter_test/flutter_test.dart';
import 'package:trading_pionex/data/technique/trending.dart';

PerpTicker t(String s, double open, double close, double amount) =>
    PerpTicker(symbol: s, open: open, close: close, turnoverUsdt: amount);

void main() {
  test('only USDT-settled perps count; COIN-M and coin-quoted are left out', () {
    expect(usdtPerpBase('AKE_USDT_PERP'), 'AKE');
    expect(usdtPerpBase('AAPLX_USDT_PERP'), 'AAPLX');
    expect(usdtPerpBase('1INCH_USDT_PERP'), '1INCH');
    expect(usdtPerpBase('USDT_BTC_PERP'), isNull);
    expect(usdtPerpBase('ETH_BTC_PERP'), isNull);
    expect(usdtPerpBase('BTC_USDT'), isNull);
  });

  test('ranks liquid pairs by the size of the 24h move, up or down', () {
    final list = rankTrending([
      t('BTC_USDT_PERP', 100, 101, 900e6), // +1%
      t('AKE_USDT_PERP', 100, 146, 13e6), // +46%
      t('UAI_USDT_PERP', 100, 63, 3e6), // -37%
      t('THIN_USDT_PERP', 100, 300, 0.2e6), // +200% but illiquid
      t('USDT_BTC_PERP', 100, 50, 50e6), // COIN-M
    ]);
    expect(list, ['AKEUSDT', 'UAIUSDT', 'BTCUSDT']);
  });

  test('caps the list', () {
    final many = [
      for (var i = 0; i < 30; i++) t('P${i}_USDT_PERP', 100, 100.0 + i, 2e6),
    ];
    expect(rankTrending(many, maxPairs: 20).length, 20);
    expect(rankTrending(many).first, 'P29USDT');
  });

  test('parses a Pionex ticker', () {
    final p = PerpTicker.fromJson({
      'symbol': 'AKE_USDT_PERP',
      'open': '0.01',
      'close': '0.015',
      'amount': '13300000.5',
    })!;
    expect(p.changePct, closeTo(50, 1e-9));
    expect(p.turnoverUsdt, 13300000.5);
    expect(PerpTicker.fromJson({'symbol': 'X'}), isNull);
  });
}
