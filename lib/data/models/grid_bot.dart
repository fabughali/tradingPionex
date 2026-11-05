enum GridDirection { long, short }

GridDirection? gridDirectionFromString(String? value) {
  switch (value?.toLowerCase()) {
    case 'long':
      return GridDirection.long;
    case 'short':
      return GridDirection.short;
    default:
      return null;
  }
}

extension GridDirectionX on GridDirection {
  String get wireValue => this == GridDirection.long ? 'long' : 'short';
}

/// A running (or just-created) Pionex futures grid bot, as returned by
/// `GET /api/v1/bot/orders`. `appInitiated` is never trusted from Pionex
/// itself — it's stamped on by the caller from `logs/created-bots.json`
/// (see CreatedBotsStore), matching the original's `_appInitiated`/`_manual`
/// convention on the raw grid object.
///
/// Every field below (other than `currentPrice`, fetched separately from the
/// public ticker endpoint) was verified against a real live grid via a
/// read-only probe (`node list-active-grids.mjs`) — not guessed from the
/// Pionex marketing docs, which describe a different, hypothetical API shape.
class GridBot {
  const GridBot({
    required this.buOrderId,
    required this.base,
    required this.quote,
    required this.status,
    required this.appInitiated,
    this.trend,
    this.leverage,
    this.row,
    this.gridType,
    this.top,
    this.bottom,
    this.initialInvestment,
    this.actualInvestment,
    this.extraMargin,
    this.marginBalance,
    this.entryPrice,
    this.positionSize,
    this.totalRealizedProfit,
    this.gridProfit,
    this.totalFee,
    this.totalFundingFee,
    this.liquidationPriceUp,
    this.liquidationPriceDown,
    this.currentPrice,
    this.canceling = false,
    this.startTime,
    this.endTime,
    this.widenApplied = false,
    this.stopProfitEnabled = false,
    this.stopLossEnabled = false,
    this.realTakeProfitPrice,
    this.realStopLossPrice,
    this.profitStopType,
    this.profitStopRaw,
    this.lossStopType,
    this.lossStopRaw,
  });

  final String buOrderId;
  final String base;
  final String quote;
  final String status;
  final bool appInitiated;
  final GridDirection? trend;
  final double? leverage;
  final int? row;
  final String? gridType;
  final double? top;
  final double? bottom;

  /// `initUsdtInvestment` — the TOTAL amount sent when the grid was created
  /// (actual + reserve).
  final double? initialInvestment;

  /// `quoteInvestment` — the current actual margin allocated to grid orders.
  final double? actualInvestment;

  /// `extraMargin` — the current reserve buffer (auto-reserve).
  final double? extraMargin;

  /// `marginBalance` — current total equity for this bot (actual + reserve +
  /// net P&L). Compared against [initialInvestment] to derive P&L, since
  /// Pionex's bot-order object has no direct "unrealized profit" field.
  final double? marginBalance;

  /// `initPrice` / `positionOpenPrice` — the average entry price.
  final double? entryPrice;

  /// `baseAmount` — current position size, in the base asset.
  final double? positionSize;

  /// `totalRealizedProfit` — realized P&L booked by the grid so far.
  final double? totalRealizedProfit;

  /// `gridProfit` — profit attributed specifically to grid trading (subset
  /// of realized P&L, excludes funding fees).
  final double? gridProfit;

  final double? totalFee;
  final double? totalFundingFee;

  /// `estimateLiquidationPriceUp` / `estimateLiquidationPriceDown` — Pionex
  /// reports both; only one is meaningful depending on direction (see
  /// [liquidationPrice]). The unused side reads back as `0` from Pionex.
  final double? liquidationPriceUp;
  final double? liquidationPriceDown;

  /// Live last-traded price from the public ticker endpoint — fetched
  /// separately (`PionexClient.getTickerPrice`), not part of the bot-order
  /// object itself. Null until that fetch completes.
  final double? currentPrice;

  final bool canceling;

  /// `createTime` — when this bot was originally opened on Pionex. Same
  /// field `PionexClient.getClosedGrids` already reads to filter closed
  /// grids by recency, epoch-millis on the wire.
  final DateTime? startTime;

  /// `closeTime`/`autoExpiredTime` — when this bot actually stopped on
  /// Pionex. Only present for a finished order; null for a running one.
  final DateTime? endTime;

  /// Whether the app's 40/60 range-widen adjustment was applied when this
  /// bot was opened - stamped on separately from [WidenAppliedStore], since
  /// Pionex's own data has no such field. Always false for a manual bot
  /// (the concept doesn't apply to it).
  final bool widenApplied;

  /// `stopProfitEnabled` / `stopLossEnabled` — Pionex's own native
  /// take-profit/stop-loss toggle for this specific bot, independent of
  /// the grid's own top/bottom range. `realTakeProfitPrice` /
  /// `realStopLossPrice` are the matching trigger prices
  /// (`profitStopLimitPrice` / `lossStopLimitPrice`, falling back to the
  /// unsuffixed `profitStop` / `lossStop` field Pionex also sends) - both
  /// null whenever the corresponding Enabled flag is false. Added
  /// 2026-09-10 after the user confirmed Pionex genuinely populates these
  /// for their bots and asked for the real value, not the app's own
  /// computed range-based estimate these fields replaced (see
  /// [takeProfitPrice]/[stopLossPrice] below).
  final bool stopProfitEnabled;
  final bool stopLossEnabled;
  final double? realTakeProfitPrice;
  final double? realStopLossPrice;

  /// Raw `profitStopType`/`lossStopType` ("price", "profit_amount",
  /// "profit_ratio", "price_limit") and the matching raw `profitStop`/
  /// `lossStop` string value, exactly as Pionex sends them - added
  /// 2026-09-18 for the gear-icon TP/SL editor, which needs to know the
  /// bot's CURRENT mode+value to pre-populate the right tab (unlike
  /// [realTakeProfitPrice]/[realStopLossPrice] above, which always treats
  /// the value as a price - wrong whenever the type is actually a ratio or
  /// amount, e.g. a real bot seen with `profitStopType: "profit_ratio",
  /// profitStop: "0.05"`, not a price at all).
  final String? profitStopType;
  final String? profitStopRaw;
  final String? lossStopType;
  final String? lossStopRaw;

  String get pairKey => '${base.toUpperCase()}/${quote.toUpperCase()}';

  /// No-slash ticker form ("DOTUSDT") - added 2026-09-18, per the user, for
  /// the gear-menu action sheets' titles ("Take Profit DOTUSDT").
  String get tickerSymbol =>
      '${base.toUpperCase().replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '')}${quote.toUpperCase()}';

  /// Pionex's own real take-profit trigger, when set - `null` if
  /// [stopProfitEnabled] is false (no fallback to the grid's own top/
  /// bottom range: showing a number here that ISN'T Pionex's real TP is
  /// exactly the confusion this was fixed to remove).
  double? get takeProfitPrice => stopProfitEnabled ? realTakeProfitPrice : null;

  /// Pionex's own real stop-loss trigger, when set - `null` if
  /// [stopLossEnabled] is false. See [takeProfitPrice].
  double? get stopLossPrice => stopLossEnabled ? realStopLossPrice : null;

  /// How long this bot has been open, as of now. Null if [startTime] is
  /// unknown.
  Duration? get duration =>
      startTime == null ? null : DateTime.now().difference(startTime!);

  /// A grid the user paused or is in the process of stopping manually —
  /// mirrors bot-grid.js's `_manual` reclassification for interrupted bots
  /// (canceling===true, top-level status 'paused', or inner status 'paused').
  bool get isManuallyInterrupted =>
      canceling || status.toLowerCase() == 'paused';

  /// The liquidation price that actually matters for this position's
  /// direction — Pionex reports both up/down estimates but only one is
  /// non-zero/meaningful at a time (long liquidates on the downside, short
  /// on the upside).
  double? get liquidationPrice {
    if (trend == GridDirection.long) return liquidationPriceDown;
    if (trend == GridDirection.short) return liquidationPriceUp;
    return null;
  }

  /// P&L since open, matching Pionex's own real "Total Profit" display
  /// (bug fixed 2026-09-18, live, real money — per the user, confirmed
  /// against a real running bot: Pionex's own app showed BCH bot
  /// `d69d5abb...` at "+0.248 (+21.94%)" while the OLD formula here —
  /// `marginBalance - initialInvestment` — read roughly -0.28%, wildly
  /// wrong, not even the right sign. `marginBalance` does NOT track this
  /// bot's real floating P&L; Pionex's own UI breaks "Total Profit" down
  /// as `Grid profit + Trend PnL`, where Trend PnL is the held position's
  /// own mark-to-market move — `positionSize * (currentPrice -
  /// entryPrice)` (sign-correct for both long and short automatically,
  /// since `positionSize` is already signed: negative for a short) —
  /// netted against real trading/funding fees. Verified live: recomputing
  /// this exact formula from the bot's own raw fields plus a fresh ticker
  /// read landed at +23.65%, matching Pionex's own +21.94% to within the
  /// real price movement between the two reads (confirmed by comparing
  /// the "current price" each was computed against). Requires
  /// [currentPrice] — null until that's populated (see the class doc
  /// comment; the engine's own ratchet check fetches it fresh per bot
  /// since `_activeGridsById` doesn't carry it the way the GUI's repository
  /// does).
  double? get profitAmount {
    if (positionSize == null || currentPrice == null || entryPrice == null) {
      return null;
    }
    final trendPnl =
        positionSize! * (currentPrice! - entryPrice!) +
        (totalFee ?? 0) +
        (totalFundingFee ?? 0);
    return trendPnl + (gridProfit ?? 0);
  }

  /// Percentage is against `actualInvestment` (`quoteInvestment` — the
  /// actual capital deployed), matching Pionex's own "Actual Investment"
  /// denominator — NOT `initialInvestment`, which also includes the
  /// untouched `extraMargin` reserve and wrongly dilutes the percentage
  /// (the old bug: a bot with $1.13 actually at risk and $3.87 sitting in
  /// reserve had its P&L% diluted against the full $5, understating a real
  /// +22% move as roughly -0.3%).
  double? get profitPercent {
    final amount = profitAmount;
    if (amount == null || actualInvestment == null || actualInvestment == 0) {
      return null;
    }
    return amount / actualInvestment! * 100;
  }

  GridBot copyWith({
    bool? appInitiated,
    double? currentPrice,
    bool? widenApplied,
  }) => GridBot(
    buOrderId: buOrderId,
    base: base,
    quote: quote,
    status: status,
    appInitiated: appInitiated ?? this.appInitiated,
    trend: trend,
    leverage: leverage,
    row: row,
    gridType: gridType,
    top: top,
    bottom: bottom,
    initialInvestment: initialInvestment,
    actualInvestment: actualInvestment,
    extraMargin: extraMargin,
    marginBalance: marginBalance,
    entryPrice: entryPrice,
    positionSize: positionSize,
    totalRealizedProfit: totalRealizedProfit,
    gridProfit: gridProfit,
    totalFee: totalFee,
    totalFundingFee: totalFundingFee,
    liquidationPriceUp: liquidationPriceUp,
    liquidationPriceDown: liquidationPriceDown,
    currentPrice: currentPrice ?? this.currentPrice,
    canceling: canceling,
    startTime: startTime,
    endTime: endTime,
    widenApplied: widenApplied ?? this.widenApplied,
  );

  factory GridBot.fromPionexOrder(
    Map<String, dynamic> order, {
    required bool appInitiated,
    bool widenApplied = false,
  }) {
    final data =
        (order['buOrderData'] as Map?)?.cast<String, dynamic>() ?? const {};
    final innerStatus = (data['status'] as String?)?.toLowerCase();
    final topStatus = (order['status'] as String?)?.toLowerCase();
    double? numOf(Object? v) =>
        v == null ? null : double.tryParse(v.toString());
    DateTime? dateOf(Object? v) {
      if (v == null) return null;
      final ms = int.tryParse(v.toString());
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    }

    return GridBot(
      buOrderId: (order['buOrderId'] ?? data['buOrderId']).toString(),
      base: (order['base'] ?? data['base'] ?? '').toString(),
      quote: (order['quote'] ?? data['quote'] ?? 'USDT').toString(),
      status: innerStatus ?? topStatus ?? 'unknown',
      appInitiated: appInitiated,
      trend: gridDirectionFromString(data['trend'] as String?),
      leverage: numOf(data['leverage']),
      row: (data['row'] as num?)?.toInt(),
      gridType: data['gridType'] as String?,
      top: numOf(data['top']),
      bottom: numOf(data['bottom']),
      initialInvestment: numOf(data['initUsdtInvestment']),
      actualInvestment: numOf(data['quoteInvestment']),
      extraMargin: numOf(data['extraMargin']),
      marginBalance: numOf(data['marginBalance']),
      entryPrice: numOf(data['positionOpenPrice']) ?? numOf(data['initPrice']),
      positionSize: numOf(data['baseAmount']),
      totalRealizedProfit: numOf(data['totalRealizedProfit']),
      gridProfit: numOf(data['gridProfit']),
      totalFee: numOf(data['totalFee']),
      totalFundingFee: numOf(data['totalFundingFee']),
      liquidationPriceUp: numOf(data['estimateLiquidationPriceUp']),
      liquidationPriceDown: numOf(data['estimateLiquidationPriceDown']),
      canceling: order['canceling'] == true,
      startTime: dateOf(order['createTime'] ?? data['createTime']),
      endTime: dateOf(
        order['closeTime'] ??
            order['autoExpiredTime'] ??
            data['closeTime'] ??
            data['autoExpiredTime'],
      ),
      widenApplied: widenApplied,
      stopProfitEnabled: data['stopProfitEnabled'] == true,
      stopLossEnabled: data['stopLossEnabled'] == true,
      realTakeProfitPrice:
          numOf(data['profitStopLimitPrice']) ?? numOf(data['profitStop']),
      realStopLossPrice:
          numOf(data['lossStopLimitPrice']) ?? numOf(data['lossStop']),
      profitStopType: data['profitStopType'] as String?,
      profitStopRaw: data['profitStop']?.toString(),
      lossStopType: data['lossStopType'] as String?,
      lossStopRaw: data['lossStop']?.toString(),
    );
  }
}
