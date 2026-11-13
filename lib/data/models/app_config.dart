/// Mirrors the original engine's config.json shape (PRD §11) — same fields,
/// same defaults, translated to a typed Dart model instead of a raw JSON blob
/// threaded through every function.
class GridPairConfig {
  const GridPairConfig({
    required this.symbol,
    required this.investment,
    this.autoReserve,
  });

  final String symbol;
  final double investment;
  final bool? autoReserve;

  factory GridPairConfig.fromJson(Map<String, dynamic> json) => GridPairConfig(
    symbol: json['symbol'] as String,
    investment: (json['investment'] as num).toDouble(),
    autoReserve: json['autoReserve'] as bool?,
  );

  Map<String, dynamic> toJson() => {
    'symbol': symbol,
    'investment': investment,
    if (autoReserve != null) 'autoReserve': autoReserve,
  };
}

class TechniqueConfig {
  const TechniqueConfig({
    this.minGrids = 3,
    this.maxGrids,
    this.gridSpacing = 'arithmetic',
    this.rangeSwingCount = 20,
    this.validateWithCheckParams = false,
  });

  final int minGrids;
  final int? maxGrids;
  final String gridSpacing;
  final int rangeSwingCount;
  final bool validateWithCheckParams;

  int get effectiveMaxGrids => maxGrids ?? 250;

  factory TechniqueConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const TechniqueConfig();
    return TechniqueConfig(
      minGrids: (json['min_grids'] as num?)?.toInt() ?? 3,
      maxGrids: (json['max_grids'] as num?)?.toInt(),
      gridSpacing: json['grid_spacing'] as String? ?? 'arithmetic',
      rangeSwingCount: (json['range_swing_count'] as num?)?.toInt() ?? 20,
      validateWithCheckParams:
          json['validate_with_checkparams'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'min_grids': minGrids,
    'max_grids': maxGrids,
    'grid_spacing': gridSpacing,
    'range_swing_count': rangeSwingCount,
    'validate_with_checkparams': validateWithCheckParams,
  };
}

/// `dailyLossLimitPct`/`maxPositions`/`maxTradeSizePct`/`cooldownSec`
/// removed 2026-09-15, per the user's explicit instruction to remove every
/// risk rule that's defined but not actually functioning. None of the four
/// were ever read by `RiskGate.gate()` in any way that could actually block
/// a trade: `dailyLossLimitPct`/`cooldownSec` depended on `RiskGate
/// .recordPnl()`, which had zero callers anywhere; `maxPositions` was
/// defined but never checked by the gate at all; `maxTradeSizePct` was
/// referenced nowhere in the entire codebase. Only `maxPerSymbol` was ever
/// real - kept.
class RiskConfig {
  const RiskConfig({this.maxPerSymbol = 1});

  final int maxPerSymbol;

  factory RiskConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const RiskConfig();
    return RiskConfig(
      maxPerSymbol: (json['max_per_symbol'] as num?)?.toInt() ?? 1,
    );
  }

  Map<String, dynamic> toJson() => {'max_per_symbol': maxPerSymbol};
}

class CdpConfig {
  const CdpConfig({this.host = '127.0.0.1', this.port = 9222, this.layoutId = ''});

  final String host;
  final int port;

  /// The saved TradingView layout to open when this app's chart tab is
  /// gone (`/chart/<layoutId>/`). Empty = take it from an open chart tab.
  final String layoutId;

  factory CdpConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const CdpConfig();
    return CdpConfig(
      host: json['host'] as String? ?? '127.0.0.1',
      port: (json['port'] as num?)?.toInt() ?? 9222,
      layoutId: json['layout_id'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    if (layoutId.isNotEmpty) 'layout_id': layoutId,
  };
}

class AppConfig {
  const AppConfig({
    this.pollIntervalSec = 5,
    this.autoReserve = true,
    this.cdp = const CdpConfig(),
    this.gridPairs = const [],
    this.technique = const TechniqueConfig(),
    this.risk = const RiskConfig(),
    this.heartbeatAlertEveryMin = 15,
  });

  final int pollIntervalSec;
  final bool autoReserve;

  final CdpConfig cdp;
  final List<GridPairConfig> gridPairs;
  final TechniqueConfig technique;
  final RiskConfig risk;
  final int heartbeatAlertEveryMin;

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
    pollIntervalSec: (json['poll_interval_sec'] as num?)?.toInt() ?? 5,
    autoReserve: json['autoReserve'] as bool? ?? true,
    cdp: CdpConfig.fromJson(json['cdp'] as Map<String, dynamic>?),
    gridPairs: ((json['grid_pairs'] as List?) ?? const [])
        .map((e) => GridPairConfig.fromJson(e as Map<String, dynamic>))
        .toList(),
    technique: TechniqueConfig.fromJson(
      json['technique'] as Map<String, dynamic>?,
    ),
    risk: RiskConfig.fromJson(json['risk'] as Map<String, dynamic>?),
    heartbeatAlertEveryMin:
        (json['heartbeat']?['alert_every_min'] as num?)?.toInt() ?? 15,
  );

  Map<String, dynamic> toJson() => {
    'poll_interval_sec': pollIntervalSec,
    'autoReserve': autoReserve,
    'cdp': cdp.toJson(),
    'grid_pairs': gridPairs.map((e) => e.toJson()).toList(),
    'technique': technique.toJson(),
    'risk': risk.toJson(),
    'heartbeat': {'alert_every_min': heartbeatAlertEveryMin},
  };

  static const defaultConfig = AppConfig(
    gridPairs: [GridPairConfig(symbol: 'BINANCE:BTCUSDT', investment: 100)],
  );
}
