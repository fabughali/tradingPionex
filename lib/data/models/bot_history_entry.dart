import 'dart:math';

import 'auto_category.dart';
import 'grid_bot.dart';

enum BotHistoryKind { last, terminated, convertedToManual }

BotHistoryKind? botHistoryKindFromString(String? raw) => switch (raw) {
  'last' => BotHistoryKind.last,
  'terminated' => BotHistoryKind.terminated,
  'converted_to_manual' => BotHistoryKind.convertedToManual,
  _ => null,
};

extension BotHistoryKindWire on BotHistoryKind {
  String get wireValue => switch (this) {
    BotHistoryKind.last => 'last',
    BotHistoryKind.terminated => 'terminated',
    BotHistoryKind.convertedToManual => 'converted_to_manual',
  };

  String get label => switch (this) {
    BotHistoryKind.last => 'Last',
    BotHistoryKind.terminated => 'Terminated',
    BotHistoryKind.convertedToManual => 'Converted to manual',
  };
}

/// One row in the History screen: an app-initiated bot that was retired
/// ([BotHistoryKind.last]), stopped/closed ([BotHistoryKind.terminated]), or
/// stopped being tracked as app-initiated because a human intervened on it
/// directly in Pionex/TradingView ([BotHistoryKind.convertedToManual]).
/// Written by whichever side (engine or GUI repository) observes the event
/// first, to `logs/bot-history.jsonl` — append-only except for the History
/// screen's own delete/clear-all actions. Every field beyond the id/kind/
/// pair identity is a best-effort snapshot of whatever the recording site
/// actually had on hand at that moment — Pionex's own bot-order object
/// (full snapshot) for a GUI-initiated stop/last, or just the app's own
/// tracked entry (direction/entry price/investment/open time) for the
/// engine's opposite-signal auto-close, which doesn't re-fetch the full
/// bot object before closing it.
class BotHistoryEntry {
  const BotHistoryEntry({
    required this.id,
    required this.ts,
    required this.kind,
    required this.pairKey,
    required this.base,
    this.buOrderId,
    this.category,
    this.detail,
    this.direction,
    this.leverage,
    this.entryPrice,
    this.exitPrice,
    this.top,
    this.bottom,
    this.gridCount,
    this.initialInvestment,
    this.actualInvestment,
    this.extraMargin,
    this.liquidationPrice,
    this.realizedProfit,
    this.profitPercent,
    this.startTime,
    this.endTime,
    this.openSignalType,
    this.openSignalZone,
    this.openSignalValue,
    this.openSignalAt,
    this.closeSignalType,
    this.closeSignalZone,
    this.closeSignalValue,
    this.closeSignalAt,
    this.stopReason,
  });

  final String id;

  /// When the app recorded this event (not necessarily the same instant the
  /// bot actually stopped on Pionex — see [endTime] for that, when known).
  final DateTime ts;
  final BotHistoryKind kind;
  final String pairKey;
  final String base;
  final String? buOrderId;

  /// Which Auto engine (1m/1H/1D) this bot belonged to (2026-09-13, per the
  /// user: "add summary for each pair" broken down by category) - captured
  /// at record time, since `BotCategoryStore` forgets a bot's category the
  /// moment it closes (confirmed live: 0 of 69 since-reset closes still had
  /// a resolvable category by the time this field was added). Every
  /// recording site sources it from whatever it already has on hand at
  /// that exact moment (the live `category` in scope, `BotCategoryStore`
  /// read BEFORE it forgets, or the entry-key's own embedded category) so
  /// this never goes stale the way looking it up later would. Null only
  /// for entries recorded before this field existed.
  final AutoCategory? category;
  final String? detail;

  final GridDirection? direction;
  final double? leverage;
  final double? entryPrice;
  final double? exitPrice;
  final double? top;
  final double? bottom;
  final int? gridCount;
  final double? initialInvestment;
  final double? actualInvestment;
  final double? extraMargin;
  final double? liquidationPrice;
  final double? realizedProfit;
  final double? profitPercent;

  /// When the bot was originally opened. From Pionex's `createTime` when a
  /// full [GridBot] snapshot was available ([fromBot]), otherwise the app's
  /// own recorded signal-entry time (opposite-signal auto-close).
  final DateTime? startTime;

  /// When the bot actually stopped on Pionex (`closeTime`/`autoExpiredTime`)
  /// — null when that wasn't available at recording time, in which case
  /// [ts] is the closest known estimate.
  final DateTime? endTime;

  /// The entry-signal record (2026-09-26, per the user: "the record should
  /// be one out of those 60 entries" - which exact (signal, zone) pairing
  /// from their spec applied). [openSignalType] is one of 'HH'/'LH'/'HL'/
  /// 'LL', [openSignalZone] one of 'yellow'/'green'/'white_upper'/
  /// 'white_lower'/'purple'/'blue', [openSignalValue] the real RSI number
  /// (0-100) at that bar - see [EntrySignalStore]. Null for any bot opened
  /// before this feature existed, or opened via a path with no confirmed
  /// signal on hand (e.g. a forced reignite that found no strict signal).
  final String? openSignalType;
  final String? openSignalZone;
  final double? openSignalValue;

  /// When the open signal above actually fired (2026-09-26, per the user:
  /// "you have to include date and time for open/close in history .. so
  /// each singla is time stamped too") - the moment the confirmed signal
  /// was read, which can differ slightly from [startTime]/[ts] (the real
  /// grid-open call itself, a few seconds later once Pionex accepted it).
  final DateTime? openSignalAt;

  /// The SAME shape, for the signal that actually closed this bot - only
  /// ever populated for a genuine opposite-signal auto-close (see
  /// `_manageGridPair`'s "Take-profit = opposite signal" block). Null for
  /// every other close reason (real Pionex TP/SL, liquidation, manual
  /// cancel, never-filled safety cancel) - those aren't signal-driven, so
  /// there is no "stop signal" to record.
  final String? closeSignalType;
  final String? closeSignalZone;
  final double? closeSignalValue;
  final DateTime? closeSignalAt;

  /// WHY this bot actually stopped, as a short stable category (2026-09-26,
  /// per the user: "i want to add stop signal - it can be TP/SL/Terminated
  /// by user/close signal/etc") - separate from, and complementary to, the
  /// live "Take profit"/"Stop loss" PRICE columns shown for a running bot
  /// (those always reflect the bot's CURRENT configured levels, whether or
  /// not it ever actually ends via them - this field only exists once a
  /// bot has genuinely stopped, describing what actually happened). One of
  /// 'take_profit', 'stop_loss_baseline', 'stop_loss_ratchet',
  /// 'stop_loss_lock', 'liquidation', 'terminated_by_user', 'close_signal'
  /// (the HH/LH/HL/LL opposite-signal close), 'never_filled', or null (the
  /// real reason wasn't available, or this entry predates the field -
  /// [detail]'s free text still covers those cases).
  final String? stopReason;

  /// Returns a copy with the entry-signal fields filled in - every other
  /// field carried over unchanged. Used at every history-recording call
  /// site to attach whatever [EntrySignalStore] has on hand for this bot,
  /// without each site needing to reconstruct the whole entry by hand.
  BotHistoryEntry withEntrySignal({
    String? openSignalType,
    String? openSignalZone,
    double? openSignalValue,
    DateTime? openSignalAt,
    String? closeSignalType,
    String? closeSignalZone,
    double? closeSignalValue,
    DateTime? closeSignalAt,
    String? stopReason,
  }) => BotHistoryEntry(
    id: id,
    ts: ts,
    kind: kind,
    pairKey: pairKey,
    base: base,
    buOrderId: buOrderId,
    category: category,
    detail: detail,
    direction: direction,
    leverage: leverage,
    entryPrice: entryPrice,
    exitPrice: exitPrice,
    top: top,
    bottom: bottom,
    gridCount: gridCount,
    initialInvestment: initialInvestment,
    actualInvestment: actualInvestment,
    extraMargin: extraMargin,
    liquidationPrice: liquidationPrice,
    realizedProfit: realizedProfit,
    profitPercent: profitPercent,
    startTime: startTime,
    endTime: endTime,
    openSignalType: openSignalType ?? this.openSignalType,
    openSignalZone: openSignalZone ?? this.openSignalZone,
    openSignalValue: openSignalValue ?? this.openSignalValue,
    openSignalAt: openSignalAt ?? this.openSignalAt,
    closeSignalType: closeSignalType ?? this.closeSignalType,
    closeSignalZone: closeSignalZone ?? this.closeSignalZone,
    closeSignalValue: closeSignalValue ?? this.closeSignalValue,
    closeSignalAt: closeSignalAt ?? this.closeSignalAt,
    stopReason: stopReason ?? this.stopReason,
  );

  static String newId() {
    final rand = Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');
    return '${DateTime.now().microsecondsSinceEpoch}-$rand';
  }

  /// Builds an entry from a full Pionex bot-order snapshot — used wherever
  /// a [GridBot] is already on hand (GUI-initiated stop, "Last", and the
  /// engine's manual-interrupt detection).
  ///
  /// [realizedProfitOverride] (2026-09-11, per the user - live account,
  /// confirmed real: Pionex's own History showed a LOSS for a stopped bot
  /// while the app recorded a positive P/L for it): the Stop button used to
  /// build this entry from the SAME [bot] snapshot fetched BEFORE
  /// `cancelFuturesGrid` was even called - if the bot's still-open position
  /// settled at a worse price during the actual cancellation (slippage,
  /// price movement in the gap), that pre-cancel snapshot never reflected
  /// it. The caller now re-reads the bot's TRUE final P/L via
  /// `pionex.getGridPnl` AFTER cancellation completes and passes it here,
  /// overriding the (otherwise stale) `bot.totalRealizedProfit`/
  /// `bot.profitAmount` fallback.
  ///
  /// [BotHistoryKind.last] NEVER gets a realizedProfit, regardless of what
  /// [bot]/[realizedProfitOverride] carry (2026-09-11, per the user, same
  /// live-account finding): "Last" only ever fires for a bot that is still
  /// RUNNING - it hasn't closed, so there is no real "realized" P/L for it
  /// yet. Recording the bot's live, still-changing snapshot at that moment
  /// used to get summed as if it were a finished trade - and double-counted
  /// once that same bot genuinely closed later and recorded ITS real final
  /// number too. The bot's true result is only ever recorded once, at its
  /// real close (signal-flip or Stop), same as any other bot.
  factory BotHistoryEntry.fromBot(
    GridBot bot, {
    required BotHistoryKind kind,
    String? detail,
    double? realizedProfitOverride,
    AutoCategory? category,
  }) => BotHistoryEntry(
    id: newId(),
    ts: DateTime.now(),
    kind: kind,
    pairKey: bot.pairKey,
    // Bug fixed 2026-09-13, per the user (P&L summary showing "XRP" and
    // "XRP.PERP" as separate rows, same for NEAR/ETH/LTC/SOL/AAVE/BTC/DOT):
    // `bot.base` is Pionex's raw base field, which always carries the
    // ".PERP" suffix - unlike every other BotHistoryEntry construction
    // site in engine_service.dart, this one (used for manually-run/
    // interrupted bots reconciled via GridBot snapshots) never stripped
    // it, splitting one base's total across two rows in any per-base
    // breakdown. Same fix as the other sites: strip it once, here, so
    // every current and future caller of fromBot gets it right.
    base: bot.base.replaceAll(RegExp(r'\.PERP$', caseSensitive: false), ''),
    buOrderId: bot.buOrderId,
    category: category,
    detail: detail,
    direction: bot.trend,
    leverage: bot.leverage,
    entryPrice: bot.entryPrice,
    exitPrice: bot.currentPrice,
    top: bot.top,
    bottom: bot.bottom,
    gridCount: bot.row,
    initialInvestment: bot.initialInvestment,
    actualInvestment: bot.actualInvestment,
    extraMargin: bot.extraMargin,
    liquidationPrice: bot.liquidationPrice,
    realizedProfit: kind == BotHistoryKind.last
        ? null
        : (realizedProfitOverride ?? bot.totalRealizedProfit ?? bot.profitAmount),
    profitPercent: kind == BotHistoryKind.last ? null : bot.profitPercent,
    startTime: bot.startTime,
    endTime: bot.endTime,
  );

  factory BotHistoryEntry.fromJson(Map<String, dynamic> json) {
    double? numOf(String key) => (json[key] as num?)?.toDouble();
    DateTime? dateOf(String key) {
      final raw = json[key] as String?;
      return raw == null ? null : DateTime.tryParse(raw);
    }

    return BotHistoryEntry(
      id: json['id'] as String? ?? '',
      ts: DateTime.tryParse(json['ts'] as String? ?? '') ?? DateTime(1970),
      kind:
          botHistoryKindFromString(json['kind'] as String?) ??
          BotHistoryKind.terminated,
      pairKey: json['pairKey'] as String? ?? '',
      base: json['base'] as String? ?? '',
      buOrderId: json['buOrderId'] as String?,
      category: autoCategoryFromWire(json['category'] as String?),
      detail: json['detail'] as String?,
      direction: gridDirectionFromString(json['direction'] as String?),
      leverage: numOf('leverage'),
      entryPrice: numOf('entryPrice'),
      exitPrice: numOf('exitPrice'),
      top: numOf('top'),
      bottom: numOf('bottom'),
      gridCount: (json['gridCount'] as num?)?.toInt(),
      initialInvestment: numOf('initialInvestment'),
      actualInvestment: numOf('actualInvestment'),
      extraMargin: numOf('extraMargin'),
      liquidationPrice: numOf('liquidationPrice'),
      realizedProfit: numOf('realizedProfit'),
      profitPercent: numOf('profitPercent'),
      startTime: dateOf('startTime'),
      endTime: dateOf('endTime'),
      openSignalType: json['openSignalType'] as String?,
      openSignalZone: json['openSignalZone'] as String?,
      openSignalValue: numOf('openSignalValue'),
      openSignalAt: dateOf('openSignalAt'),
      closeSignalType: json['closeSignalType'] as String?,
      closeSignalZone: json['closeSignalZone'] as String?,
      closeSignalValue: numOf('closeSignalValue'),
      closeSignalAt: dateOf('closeSignalAt'),
      stopReason: json['stopReason'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'ts': ts.toIso8601String(),
    'kind': kind.wireValue,
    'pairKey': pairKey,
    'base': base,
    if (buOrderId != null) 'buOrderId': buOrderId,
    if (category != null) 'category': category!.wireValue,
    if (detail != null) 'detail': detail,
    if (direction != null) 'direction': direction!.wireValue,
    if (leverage != null) 'leverage': leverage,
    if (entryPrice != null) 'entryPrice': entryPrice,
    if (exitPrice != null) 'exitPrice': exitPrice,
    if (top != null) 'top': top,
    if (bottom != null) 'bottom': bottom,
    if (gridCount != null) 'gridCount': gridCount,
    if (initialInvestment != null) 'initialInvestment': initialInvestment,
    if (actualInvestment != null) 'actualInvestment': actualInvestment,
    if (extraMargin != null) 'extraMargin': extraMargin,
    if (liquidationPrice != null) 'liquidationPrice': liquidationPrice,
    if (realizedProfit != null) 'realizedProfit': realizedProfit,
    if (profitPercent != null) 'profitPercent': profitPercent,
    if (startTime != null) 'startTime': startTime!.toIso8601String(),
    if (endTime != null) 'endTime': endTime!.toIso8601String(),
    if (openSignalType != null) 'openSignalType': openSignalType,
    if (openSignalZone != null) 'openSignalZone': openSignalZone,
    if (openSignalValue != null) 'openSignalValue': openSignalValue,
    if (openSignalAt != null) 'openSignalAt': openSignalAt!.toIso8601String(),
    if (closeSignalType != null) 'closeSignalType': closeSignalType,
    if (closeSignalZone != null) 'closeSignalZone': closeSignalZone,
    if (closeSignalValue != null) 'closeSignalValue': closeSignalValue,
    if (closeSignalAt != null)
      'closeSignalAt': closeSignalAt!.toIso8601String(),
    if (stopReason != null) 'stopReason': stopReason,
  };
}
