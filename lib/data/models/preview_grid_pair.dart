import 'auto_category.dart';
import 'grid_bot.dart';

/// A read-only preview of what a NEW grid bot would look like if opened on
/// [base] right now — computed by the engine every cycle using the exact
/// same signal/range/leverage/grid-count/auto-reserve logic it would use for
/// a real open, but never actually placing an order. Backs the dashboard's
/// "Last report" checklist: the user picks which of these to actually start
/// (via `EngineControlRepository.select` + `checkNow`), at which point the
/// engine re-runs this same computation for real — these numbers are a
/// guide, not a lock-in, since the market can move between preview and start.
class PreviewGridPair {
  const PreviewGridPair({
    required this.symbol,
    required this.base,
    required this.quote,
    required this.direction,
    required this.top,
    required this.bottom,
    required this.stable,
    required this.widenApplied,
    required this.takeProfitPrice,
    required this.stopLossPrice,
    required this.maxLeverage,
    required this.leverage,
    required this.gridCount,
    required this.entryPrice,
    this.actualInvestment,
    this.extraMargin,
    this.liquidationPrice,
    this.category = AutoCategory.oneHour,
  });

  final String symbol;
  final String base;
  final String quote;
  final GridDirection direction;

  /// Which of the 3 engines this specific preview was computed under
  /// (2026-09-08) - Check Now computes one of these per category per pair,
  /// so a single base can have up to 3 entries in the same report, one for
  /// each category's own signal/range resolution. Defaults to 1H for
  /// backward-compat with any report written before this field existed.
  final AutoCategory category;

  /// Final range (post-40/60 adjustment if [widenApplied]).
  final double top;
  final double bottom;

  final bool stable;
  final bool widenApplied;
  final double takeProfitPrice;
  final double stopLossPrice;

  final double maxLeverage;
  final double leverage;
  final int gridCount;

  /// The signal price that triggered this candidate — the anticipated entry.
  final double entryPrice;

  /// From the same checkParams probe used for grid-count — the actual/reserve
  /// split Pionex would apply. Null if the probe didn't resolve (e.g. Pionex
  /// unreachable at preview time).
  final double? actualInvestment;
  final double? extraMargin;

  /// initial investment = actual + extra margin (what you'd actually send).
  double? get initialInvestment =>
      (actualInvestment == null || extraMargin == null)
      ? null
      : actualInvestment! + extraMargin!;

  final double? liquidationPrice;

  String get pairKey => '${base.toUpperCase()}/${quote.toUpperCase()}';

  factory PreviewGridPair.fromJson(Map<String, dynamic> json) =>
      PreviewGridPair(
        symbol: json['symbol'] as String? ?? '',
        base: json['base'] as String? ?? '',
        quote: json['quote'] as String? ?? 'USDT',
        direction:
            gridDirectionFromString(json['direction'] as String?) ??
            GridDirection.long,
        top: (json['top'] as num?)?.toDouble() ?? 0,
        bottom: (json['bottom'] as num?)?.toDouble() ?? 0,
        stable: json['stable'] as bool? ?? true,
        widenApplied: json['widenApplied'] as bool? ?? false,
        takeProfitPrice: (json['takeProfitPrice'] as num?)?.toDouble() ?? 0,
        stopLossPrice: (json['stopLossPrice'] as num?)?.toDouble() ?? 0,
        maxLeverage: (json['maxLeverage'] as num?)?.toDouble() ?? 0,
        leverage: (json['leverage'] as num?)?.toDouble() ?? 0,
        gridCount: (json['gridCount'] as num?)?.toInt() ?? 0,
        entryPrice: (json['entryPrice'] as num?)?.toDouble() ?? 0,
        actualInvestment: (json['actualInvestment'] as num?)?.toDouble(),
        extraMargin: (json['extraMargin'] as num?)?.toDouble(),
        liquidationPrice: (json['liquidationPrice'] as num?)?.toDouble(),
        category:
            autoCategoryFromWire(json['category'] as String?) ??
            AutoCategory.oneHour,
      );

  Map<String, dynamic> toJson() => {
    'symbol': symbol,
    'base': base,
    'quote': quote,
    'direction': direction.wireValue,
    'top': top,
    'bottom': bottom,
    'stable': stable,
    'widenApplied': widenApplied,
    'takeProfitPrice': takeProfitPrice,
    'stopLossPrice': stopLossPrice,
    'maxLeverage': maxLeverage,
    'leverage': leverage,
    'gridCount': gridCount,
    'entryPrice': entryPrice,
    'actualInvestment': actualInvestment,
    'extraMargin': extraMargin,
    'liquidationPrice': liquidationPrice,
    'category': category.wireValue,
  };
}

/// A Red List pair the engine deliberately did not read a signal for -
/// checked against Pionex's own futures listing (not TradingView) and found
/// absent, so it can never actually be opened as a grid. Carries no
/// signal/range/leverage values by design: per the user (2026-09-06), the
/// engine must not spend a TradingView chart-switch or any Pionex call on a
/// pair it already knows can't trade - this is a plain tag, not a preview.
class UnlistedRedListPair {
  const UnlistedRedListPair({required this.symbol, required this.base});

  final String symbol;
  final String base;

  static const message = 'This pair is not listed in Pionex futures trade.';

  factory UnlistedRedListPair.fromJson(Map<String, dynamic> json) =>
      UnlistedRedListPair(
        symbol: json['symbol'] as String? ?? '',
        base: json['base'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'symbol': symbol, 'base': base};
}

/// A Red List (tradeable-on-Pionex) pair Check Now has recognized but not
/// yet reached in its sequential sweep (2026-09-11, per the user: "if there
/// is extra pairs in red list not in next trade table, it will be added as
/// row with '-' as if data not yet pulled"). Written the moment a fresh
/// Check Now starts, for every red-list base with no existing [entries]
/// row under any category - shows the base's row immediately with dashes
/// instead of making the user wait for the whole sweep to reach it. Cleared
/// per-base the instant that base's first real preview merges in (see
/// [CoreStorage] / `_mergeLastReportEntry`'s pending-removal), whether that
/// preview finds a real signal or ultimately finds none - either way the
/// base has been visited and is no longer "not yet pulled".
class PendingRedListPair {
  const PendingRedListPair({required this.symbol, required this.base});

  final String symbol;
  final String base;

  factory PendingRedListPair.fromJson(Map<String, dynamic> json) =>
      PendingRedListPair(
        symbol: json['symbol'] as String? ?? '',
        base: json['base'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'symbol': symbol, 'base': base};
}

/// The full report — every currently-actionable candidate plus when it was
/// generated. Written to `logs/last-report.json` by the engine every cycle;
/// read (never written) by the GUI.
class LastReport {
  const LastReport({
    required this.generatedAtMs,
    required this.entries,
    this.unlisted = const [],
    this.pending = const [],
  });

  final int generatedAtMs;
  final List<PreviewGridPair> entries;
  final List<UnlistedRedListPair> unlisted;

  /// Red-list bases Check Now has reconciled in but not yet reached - see
  /// [PendingRedListPair].
  final List<PendingRedListPair> pending;

  DateTime get generatedAt =>
      DateTime.fromMillisecondsSinceEpoch(generatedAtMs);

  static const empty = LastReport(generatedAtMs: 0, entries: []);

  factory LastReport.fromJson(Map<String, dynamic> json) => LastReport(
    generatedAtMs: (json['generatedAtMs'] as num?)?.toInt() ?? 0,
    entries: ((json['entries'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(PreviewGridPair.fromJson)
        .toList(),
    unlisted: ((json['unlisted'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(UnlistedRedListPair.fromJson)
        .toList(),
    pending: ((json['pending'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(PendingRedListPair.fromJson)
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'generatedAtMs': generatedAtMs,
    'entries': entries.map((e) => e.toJson()).toList(),
    'unlisted': unlisted.map((e) => e.toJson()).toList(),
    'pending': pending.map((e) => e.toJson()).toList(),
  };
}
