import 'package:flutter_test/flutter_test.dart';
import 'package:trading_pionex/data/pionex/pionex_market.dart';
import 'package:trading_pionex/data/technique/trending.dart';

PerpTicker t(String s, double changePct, double amount) => PerpTicker(
  symbol: s,
  open: 100,
  close: 100 + changePct,
  turnoverUsdt: amount,
);

void main() {
  final market = buildMarket(
    [
      t('AKE_USDT_PERP', 46, 13e6),
      t('UAI_USDT_PERP', -37, 3e6),
      t('BTC_USDT_PERP', 0.2, 1800e6),
      t('AAPLX_USDT_PERP', 1, 0.5e6),
      t('USDT_BTC_PERP', -0.2, 2e6),
      t('ETH_BTC_PERP', 0.5, 1e6),
      t('BAD', 9, 9),
    ],
    {'AAPLX'},
  );

  test('puts each pair in Pionex\'s category', () {
    final cats = {for (final p in market) p.displayPair: p.category};
    expect(cats, {
      'AKE/USDT': MarketCategory.usdtM,
      'UAI/USDT': MarketCategory.usdtM,
      'BTC/USDT': MarketCategory.usdtM,
      'AAPLX/USDT': MarketCategory.stockToken,
      'USDT/BTC': MarketCategory.coinM,
      'ETH/BTC': MarketCategory.coinFutures,
    });
  });

  test('only USDT-settled pairs get an app symbol (tradable)', () {
    final syms = {for (final p in market) p.displayPair: p.appSymbol};
    expect(syms['AKE/USDT'], 'AKEUSDT');
    expect(syms['AAPLX/USDT'], 'AAPLXUSDT');
    expect(syms['USDT/BTC'], isNull);
    expect(syms['ETH/BTC'], isNull);
  });

  test('sort icon cycles gainers, losers, category, volume, A-Z, Z-A', () {
    expect(MarketSort.gainers.next, MarketSort.losers);
    expect(MarketSort.losers.next, MarketSort.category);
    expect(MarketSort.category.next, MarketSort.volume);
    expect(MarketSort.volume.next, MarketSort.aToZ);
    expect(MarketSort.aToZ.next, MarketSort.zToA);
    expect(MarketSort.zToA.next, MarketSort.gainers);
  });

  test('each sort orders the pairs as Pionex would', () {
    List<String> order(MarketSort s) =>
        sortMarket(market, s).map((p) => p.base).toList();
    expect(order(MarketSort.gainers).first, 'AKE');
    expect(order(MarketSort.gainers).last, 'UAI');
    expect(order(MarketSort.losers).first, 'UAI');
    expect(order(MarketSort.losers).last, 'AKE');
    expect(order(MarketSort.volume).first, 'BTC');
    expect(order(MarketSort.aToZ), ['AAPLX', 'AKE', 'BTC', 'ETH', 'UAI', 'USDT']);
    expect(order(MarketSort.zToA), ['USDT', 'UAI', 'ETH', 'BTC', 'AKE', 'AAPLX']);
    expect(order(MarketSort.category), [
      'BTC', 'AKE', 'UAI', // USDT-M by volume
      'USDT', // COIN-M
      'AAPLX', // stock token
      'ETH', // coin futures
    ]);
  });
}
