/// Check Now's pair list (2026-11-07, per the user: "catch trending pairs"
/// from Pionex's own futures categories instead of the TradingView Red list).
///
/// Built from Pionex's public 24h perpetual tickers: the USDT-M crypto pairs
/// and the tokenized stocks (both settle in USDT, so both are `X_USDT_PERP`).
/// COIN-M (`USDT_X_PERP`) and coin-quoted pairs (`X_BTC_PERP`...) are left
/// out: the app's grid bots are USDT-margined.
///
/// Ranking: pairs that traded at least [minTurnoverUsdt] in 24h (enough
/// liquidity for a grid), sorted by the size of their 24h price move, up
/// or down - biggest first.

/// One perpetual's 24h numbers from `GET /api/v1/market/tickers?type=PERP`.
class PerpTicker {
  const PerpTicker({
    required this.symbol,
    required this.open,
    required this.close,
    required this.turnoverUsdt,
  });

  /// Pionex's own name, e.g. `AKE_USDT_PERP`.
  final String symbol;
  final double open;
  final double close;

  /// 24h traded value in the quote currency (`amount`).
  final double turnoverUsdt;

  /// 24h move in percent; 0 when there's no open price.
  double get changePct => open == 0 ? 0 : (close - open) / open * 100;

  static PerpTicker? fromJson(Map<String, dynamic> j) {
    final symbol = j['symbol']?.toString();
    final open = double.tryParse('${j['open']}');
    final close = double.tryParse('${j['close']}');
    final amount = double.tryParse('${j['amount']}');
    if (symbol == null || open == null || close == null || amount == null) {
      return null;
    }
    return PerpTicker(
      symbol: symbol,
      open: open,
      close: close,
      turnoverUsdt: amount,
    );
  }
}

/// `AKE_USDT_PERP` -> `AKE`; null for anything that isn't a plain
/// USDT-settled perpetual (COIN-M `USDT_BTC_PERP`, `ETH_BTC_PERP`...).
String? usdtPerpBase(String pionexSymbol) {
  final m = RegExp(r'^([A-Z0-9]+)_USDT_PERP$').firstMatch(pionexSymbol);
  if (m == null) return null;
  final base = m.group(1)!;
  return base == 'USDT' ? null : base;
}

/// The trending list as app symbols (`AKEUSDT`), best first.
List<String> rankTrending(
  List<PerpTicker> tickers, {
  double minTurnoverUsdt = 1000000,
  int maxPairs = 20,
}) {
  final liquid = [
    for (final t in tickers)
      if (usdtPerpBase(t.symbol) != null && t.turnoverUsdt >= minTurnoverUsdt) t,
  ]..sort((a, b) => b.changePct.abs().compareTo(a.changePct.abs()));
  return [
    for (final t in liquid.take(maxPairs)) '${usdtPerpBase(t.symbol)}USDT',
  ];
}
