import '../technique/worm10_decision.dart';
import '../technique/worm10_pionex.dart';
import 'trade_direction.dart';
import 'grid_bot.dart';

/// One currently-running auto bot's fresh signal read, captured during the
/// same full Red-list checkup that produces [LastReport] — the "GRID
/// ALREADY RUNNING - holding" branch in `_manageGridPair` populates this
/// instead of a [PreviewGridPair], since the bot already has its own live
/// range/TP/SL/leverage (see the Active grids table) and doesn't need a
/// second, hypothetical preview of them.
class RunningBotCheck {
  const RunningBotCheck({
    required this.symbol,
    required this.base,
    required this.buOrderId,
    required this.botDirection,
    this.latestEventType,
  });

  final String symbol;
  final String base;
  final String buOrderId;

  /// The bot's own open direction (long/short) - NOT necessarily the
  /// direction of [latestEventType], which is just whatever the chart
  /// shows right now.
  final GridDirection botDirection;

  /// Worm10 Hybrid Decision technique (2026-10-25) - the latest derived
  /// event type (not necessarily confirmed/actionable yet - purely
  /// informational display here, same role the old `latestSignalSide`
  /// played). Replaces `buyCount`/`sellCount`/`latestSignalSide` entirely
  /// (per the user: "remove any old technique from code and from prd") -
  /// neither of those had any real consumer beyond this file's own JSON
  /// round-trip.
  final Worm10EventKind? latestEventType;

  String get pairKey => '${base.toUpperCase()}/USDT';

  /// True when the latest event points the opposite way from the bot's
  /// own direction - i.e. the kind of event that (once confirmed and
  /// newer than the bot's entry) would close this grid. Purely
  /// informational here; the actual close decision is made elsewhere with
  /// the bot's exact entry time.
  bool get opposesBotDirection =>
      latestEventType != null &&
      ((botDirection == GridDirection.long &&
              worm10EventDirection(latestEventType!) == TradeDirection.short) ||
          (botDirection == GridDirection.short &&
              worm10EventDirection(latestEventType!) == TradeDirection.long));

  factory RunningBotCheck.fromJson(Map<String, dynamic> json) =>
      RunningBotCheck(
        symbol: json['symbol'] as String? ?? '',
        base: json['base'] as String? ?? '',
        buOrderId: json['buOrderId'] as String? ?? '',
        botDirection:
            gridDirectionFromString(json['botDirection'] as String?) ??
            GridDirection.long,
        latestEventType: () {
          final name = json['latestEventType'] as String?;
          if (name == null) return null;
          for (final t in Worm10EventKind.values) {
            if (t.name == name) return t;
          }
          return null;
        }(),
      );

  Map<String, dynamic> toJson() => {
    'symbol': symbol,
    'base': base,
    'buOrderId': buOrderId,
    'botDirection': botDirection.wireValue,
    'latestEventType': latestEventType?.name,
  };
}

/// Written to `logs/running-bots-report.json` by the engine every checkup
/// cycle, alongside `last-report.json` - read (never written) by the GUI.
class RunningBotsReport {
  const RunningBotsReport({required this.generatedAtMs, required this.entries});

  final int generatedAtMs;
  final List<RunningBotCheck> entries;

  DateTime get generatedAt =>
      DateTime.fromMillisecondsSinceEpoch(generatedAtMs);

  static const empty = RunningBotsReport(generatedAtMs: 0, entries: []);

  factory RunningBotsReport.fromJson(Map<String, dynamic> json) =>
      RunningBotsReport(
        generatedAtMs: (json['generatedAtMs'] as num?)?.toInt() ?? 0,
        entries: ((json['entries'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(RunningBotCheck.fromJson)
            .toList(),
      );

  Map<String, dynamic> toJson() => {
    'generatedAtMs': generatedAtMs,
    'entries': entries.map((e) => e.toJson()).toList(),
  };
}
