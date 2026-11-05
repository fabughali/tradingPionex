import 'auto_category.dart';
import 'grid_bot.dart';

enum TradeTriggerKind { start, stop }

TradeTriggerKind? tradeTriggerKindFromString(String? value) => switch (value) {
  'start' => TradeTriggerKind.start,
  'stop' => TradeTriggerKind.stop,
  _ => null,
};

extension TradeTriggerKindWire on TradeTriggerKind {
  String get wireValue => this == TradeTriggerKind.start ? 'start' : 'stop';
}

/// One real TradingView-driven open/close decision (2026-09-17, per the
/// user: voice alerts - "start long/short PAIR" / "close PAIR"). Written to
/// `trade-start-events.jsonl` by the engine at the exact moment it commits
/// to acting on a fresh signal - AFTER every one of its own gates already
/// passed (already-running dedup, createBlocked/selection, risk gate for a
/// [TradeTriggerKind.start]; the pause/id-mismatch refusal checks for a
/// [TradeTriggerKind.stop]) so this only ever fires for a base genuinely
/// running or about to run, per the user's explicit "only play once auto
/// trade is running/waiting" - but BEFORE the actual Pionex API call and
/// its own delay/shrink-retry loop, per the user's explicit "I don't care
/// if app delay or retrying opening/closing - voice is for TradingView
/// triggers", not for however long Pionex itself then takes to confirm it.
/// GUI-only consumer (see `SoundService`); not read by the engine itself.
class TradeStartEvent {
  const TradeStartEvent({
    required this.id,
    required this.ts,
    required this.kind,
    required this.base,
    required this.direction,
    this.buOrderId,
    this.category,
  });

  final String id;
  final DateTime ts;
  final TradeTriggerKind kind;
  final String base;

  /// The position's direction - the NEW position for [TradeTriggerKind.start],
  /// the one being closed for [TradeTriggerKind.stop] (not currently spoken
  /// for stop, kept for completeness/future use).
  final GridDirection direction;
  final String? buOrderId;
  final AutoCategory? category;

  factory TradeStartEvent.fromJson(Map<String, dynamic> json) =>
      TradeStartEvent(
        id: json['id'] as String? ?? '',
        ts: DateTime.tryParse(json['ts'] as String? ?? '') ?? DateTime(1970),
        kind:
            tradeTriggerKindFromString(json['kind'] as String?) ??
            TradeTriggerKind.start,
        base: json['base'] as String? ?? '',
        direction:
            gridDirectionFromString(json['direction'] as String?) ??
            GridDirection.long,
        buOrderId: json['buOrderId'] as String?,
        category: autoCategoryFromWire(json['category'] as String?),
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'ts': ts.toIso8601String(),
    'kind': kind.wireValue,
    'base': base,
    'direction': direction.wireValue,
    if (buOrderId != null) 'buOrderId': buOrderId,
    if (category != null) 'category': category!.wireValue,
  };
}
