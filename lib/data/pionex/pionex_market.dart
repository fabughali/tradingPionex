import '../../core/core_storage.dart';
import '../technique/trending.dart';

/// Every Pionex perpetual future for the Check Now table (2026-11-07, per the
/// user): price move, volume and Pionex's own category, so the table can list
/// all pairs and sort them like Pionex does.

/// Pionex's futures categories, in the order the user listed them.
enum MarketCategory { usdtM, coinM, stockToken, coinFutures }

extension MarketCategoryX on MarketCategory {
  String get label => switch (this) {
    MarketCategory.usdtM => 'USDT-M',
    MarketCategory.coinM => 'COIN-M',
    MarketCategory.stockToken => 'Stock token',
    MarketCategory.coinFutures => 'Coin futures',
  };

  /// The app's grid bots are USDT-margined: only these can be traded.
  bool get tradable =>
      this == MarketCategory.usdtM || this == MarketCategory.stockToken;
}

/// One Pionex perpetual.
class MarketPair {
  const MarketPair({
    required this.pionexSymbol,
    required this.base,
    required this.quote,
    required this.category,
    required this.changePct,
    required this.turnoverUsdt,
  });

  /// Pionex's own name, e.g. `AKE_USDT_PERP`.
  final String pionexSymbol;
  final String base;
  final String quote;
  final MarketCategory category;
  final double changePct;

  /// 24h traded value in the quote currency.
  final double turnoverUsdt;

  /// How Pionex shows it, e.g. `AKE/USDT`.
  String get displayPair => '$base/$quote';

  /// The app's symbol for a tradable pair (`AKEUSDT`), else null.
  String? get appSymbol => category.tradable ? '${base}USDT' : null;
}

/// Splits `AKE_USDT_PERP` into (AKE, USDT); null if it isn't a perpetual.
(String, String)? splitPerpSymbol(String pionexSymbol) {
  final m = RegExp(r'^([A-Z0-9]+)_([A-Z0-9]+)_PERP$').firstMatch(pionexSymbol);
  return m == null ? null : (m.group(1)!, m.group(2)!);
}

/// Pionex's category for a perpetual: COIN-M are the reverse contracts
/// (`USDT_BTC_PERP`), coin futures are quoted in a coin (`ETH_BTC_PERP`),
/// stock tokens are the USDT pairs whose base Pionex tags as a US stock.
MarketCategory categoryOf(String base, String quote, Set<String> stockBases) {
  if (base == 'USDT') return MarketCategory.coinM;
  if (quote != 'USDT') return MarketCategory.coinFutures;
  return stockBases.contains(base)
      ? MarketCategory.stockToken
      : MarketCategory.usdtM;
}

/// Builds the market list from Pionex's 24h tickers.
List<MarketPair> buildMarket(
  List<PerpTicker> tickers,
  Set<String> stockBases,
) => [
  for (final t in tickers)
    if (splitPerpSymbol(t.symbol) case (final base, final quote))
      MarketPair(
        pionexSymbol: t.symbol,
        base: base,
        quote: quote,
        category: categoryOf(base, quote, stockBases),
        changePct: t.changePct,
        turnoverUsdt: t.turnoverUsdt,
      ),
];

/// The table's sort, cycled by its sort icon in this order.
enum MarketSort { gainers, losers, category, volume }

extension MarketSortX on MarketSort {
  String get label => switch (this) {
    MarketSort.gainers => 'Top gainers first',
    MarketSort.losers => 'Top losers first',
    MarketSort.category => 'By category',
    MarketSort.volume => 'By 24h volume (Pionex trend)',
  };

  MarketSort get next =>
      MarketSort.values[(index + 1) % MarketSort.values.length];
}

/// Sorts a copy of [pairs]. Category order is USDT-M, COIN-M, Stock token,
/// Coin futures; within a category, and for the volume sort, the most traded
/// first.
List<MarketPair> sortMarket(List<MarketPair> pairs, MarketSort sort) {
  int byVolume(MarketPair a, MarketPair b) =>
      b.turnoverUsdt.compareTo(a.turnoverUsdt);
  final out = [...pairs];
  switch (sort) {
    case MarketSort.gainers:
      out.sort((a, b) => b.changePct.compareTo(a.changePct));
    case MarketSort.losers:
      out.sort((a, b) => a.changePct.compareTo(b.changePct));
    case MarketSort.category:
      out.sort((a, b) {
        final c = a.category.index.compareTo(b.category.index);
        return c != 0 ? c : byVolume(a, b);
      });
    case MarketSort.volume:
      out.sort(byVolume);
  }
  return out;
}

/// How many rows the table adds per "Show more".
const int marketPageSize = 100;

/// Pionex's US-stock token perpetuals, read from Pionex's own website market
/// list (tag `us_stocks`) on 2026-11-07 - Pionex's public API has no category
/// field. Written once to [CoreStorage.stockTokensFile], which the user can
/// edit when Pionex adds or removes stock tokens.
const List<String> defaultStockTokenBases = [
  'AAOIX', 'AAPLX', 'AAX', 'AMATX', 'AMDX', 'AMZNX', 'APPX', 'ARMX',
  'ASMLX', 'ASTSX', 'AVGOX', 'AXTIX', 'BABAX', 'BEX', 'BMNRX', 'BNOX',
  'CEGX', 'CF', 'CIFRX', 'COHRX', 'COINX', 'CPERX', 'CRCLX', 'CRDOX',
  'CRWVX', 'CSCOX', 'CVXX', 'DELLX', 'DRAMX', 'EWJX', 'EWYX', 'FLNCX',
  'GEVX', 'GLWX', 'GMEX', 'GOOGLX', 'GSGX', 'HIMSX', 'HOODX', 'IBMX',
  'INTCX', 'IRENX', 'LITEX', 'LLYX', 'LMTX', 'LNGX', 'LRCXX', 'METAX',
  'MOSX', 'MPX', 'MRNAX', 'MRVLX', 'MSFTX', 'MSTRX', 'MUX', 'NBISX',
  'NETX', 'NFLXX', 'NIOX', 'NKEX', 'NOKX', 'NTRX', 'NVDAX', 'OKLOX',
  'ONDSX', 'ONX', 'ORCLX', 'PAYPX', 'PLTRX', 'QCOMX', 'QQQX', 'RGTIX',
  'RKLBX', 'RTXX', 'SITMX', 'SKHY', 'SLVX', 'SMCIX', 'SMHX', 'SNDKX',
  'SNXXX', 'SOXLX', 'SOXSX', 'SOXXX', 'SPCX', 'SPYX', 'STXX', 'TQQQX',
  'TSLAX', 'TSMX', 'TTEX', 'TXNX', 'UNGX', 'UNHX', 'URAX', 'URNMX',
  'USARX', 'USOX', 'VGKX', 'VSHX', 'WDCX', 'XYZ',
];

/// The user's saved stock-token list ([CoreStorage.stockTokensFile]); written
/// from [defaultStockTokenBases] the first time. A broken file falls back to
/// the built-in list.
Set<String> loadStockTokenBases(CoreStorage storage) {
  try {
    final raw = storage.readJsonArray(storage.stockTokensFile);
    if (raw == null) {
      storage.writeJson(storage.stockTokensFile, defaultStockTokenBases);
      return defaultStockTokenBases.toSet();
    }
    return {
      for (final e in raw)
        if ('$e'.trim().isNotEmpty) '$e'.trim().toUpperCase(),
    };
  } catch (_) {
    return defaultStockTokenBases.toSet();
  }
}
