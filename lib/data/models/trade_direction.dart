/// BUY (long) or SELL (short) — the MT5 equivalent of tradingPionex's
/// GridDirection, renamed since there's no grid here, just a single
/// market order per open.
enum TradeDirection { long, short }

TradeDirection? tradeDirectionFromString(String? value) {
  switch (value?.toLowerCase()) {
    case 'long':
    case 'buy':
      return TradeDirection.long;
    case 'short':
    case 'sell':
      return TradeDirection.short;
    default:
      return null;
  }
}
