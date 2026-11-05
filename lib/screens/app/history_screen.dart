import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/core_layout.dart';
import '../../core/core_spacing.dart';
import '../../core/core_theme.dart';
import '../../data/control/engine_control_repository.dart';
import '../../data/models/auto_category.dart';
import '../../data/models/bot_history_entry.dart';
import '../../data/providers/app_providers.dart';
import '../../utilities/util_date.dart';
import '../../utilities/util_string.dart';
import '../../widgets/reuse_card.dart';
import '../../widgets/reuse_chip.dart';
import '../../widgets/reuse_empty_state.dart';
import '../../widgets/reuse_error.dart';
import '../../widgets/reuse_loading_indicator.dart';

/// "Bot type" filter (2026-09-22, per the user: "i want hisory to have
/// filter for auto trades, manual trades") - a [BotHistoryEntry] has no
/// explicit `appInitiated` field, so this is derived the same way every
/// other part of the app infers it: `category != null` means auto (every
/// auto-entry call site passes one), `category == null` means manual.
enum _BotTypeFilter { auto, manual }

/// Display name for an `EntrySignalStore` zone key ('yellow'/'green'/
/// 'white_upper'/'white_lower'/'purple'/'blue' - White split at 50%, per
/// the user's spec). Null/unrecognized just echoes back whatever string
/// was stored.
String _zoneLabel(String? zone) => switch (zone) {
  'yellow' => 'Yellow',
  'green' => 'Green',
  'white_upper' => 'White ≥50',
  'white_lower' => 'White <50',
  'purple' => 'Purple',
  'blue' => 'Blue',
  _ => zone ?? '—',
};

/// One "Opened:"/"Closed:" line - `type` alone for a signal recorded since
/// 2026-09-29 (worm_9_26 is the only source now; no zone/RSI value exists
/// any more), or the full "type · zone · value" form for an entry recorded
/// before that, so old history keeps displaying exactly as it always did.
String _signalLine(
  String label,
  String? type,
  String? zone,
  double? value,
  DateTime? at,
) {
  final head = zone != null && value != null
      ? '$type · ${_zoneLabel(zone)} · ${value.toStringAsFixed(1)}'
      : '$type';
  final ts = at != null ? ' (${UtilDate.dateTime(at)})' : '';
  return '$label: $head$ts';
}

/// The 3 "reason" tags requested alongside bot-type/category (2026-09-22,
/// per the user: "last/stopped by user/SLL") - independent, multi-select
/// toggles, since these describe DIFFERENT axes of a history entry (Last is
/// a [BotHistoryKind], the other two are only ever inferable from
/// [BotHistoryEntry.detail]'s free text - see [_HistoryScreenState._matchesReasonTag]).
enum _ReasonTag { last, stoppedByUser, stopLossLock }

/// History of every app-initiated bot that stopped being an active auto bot:
/// retired via "Last", stopped/closed ("Terminated"), or a human intervened
/// on it directly so the app stopped tracking it as its own ("Converted to
/// manual"). Read-only except for delete — a single record or the whole
/// list at once.
///
/// Filters added 2026-09-22, per the user ("i want hisory to have filter
/// for auto trades, manual trades, 3m/5m/15m/1H/1D/last/stopped by
/// user/SLL"): 3 independent chip groups - bot type (auto/manual, single-
/// select), category (3m/5m/15m/1H/1D, single-select - only auto entries
/// can ever match one), and reason tags (Last/Stopped by user/SLL,
/// multi-select, since an entry could in principle need more than one).
/// All 3 groups AND together; no selection in a group means "don't filter
/// on this axis." Purely a display-layer filter over the same
/// [botHistoryProvider] data - nothing about the underlying history file
/// changes.
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  // All 3 groups are multi-select (2026-09-22, per the user: "can you make
  // multiple selection. currently filter selection can only be applied to
  // one selection" - the bot-type/category groups were single-select
  // `ChoiceChip`s, and even the reason-tags group, despite already using
  // togglable `FilterChip`s, ANDed its selections together internally -
  // since the 3 reason tags are mutually exclusive per entry in practice,
  // picking two together always produced zero results, the same usability
  // problem in different clothes). Semantics now: OR WITHIN a group (any
  // selected value in that group counts as a match), AND ACROSS groups (an
  // entry must satisfy every group that has an active selection) - the
  // standard faceted-filter convention, and the only one where selecting
  // more chips in one group can only ever show MORE results, never fewer.
  final Set<_BotTypeFilter> _typeFilters = {};
  final Set<AutoCategory> _categoryFilters = {};
  final Set<_ReasonTag> _reasonFilters = {};

  /// [BotHistoryEntry] has no structured field for "stopped by the user" or
  /// "closed via Stop Loss Lock" - both are only ever inferable from
  /// `detail`'s free text (see the engine's own `_reconciledCloseReason`
  /// and `EngineControlRepository`'s Stop/gear-menu detail strings, which
  /// this matches verbatim). "Stopped by user" covers all 3 real ways a
  /// close is genuinely user-initiated: the app's own Stop button, the
  /// gear menu's manual-bot Stop, or a cancel done directly on Pionex/
  /// TradingView outside the app.
  bool _matchesReasonTag(BotHistoryEntry e, _ReasonTag tag) {
    final detail = e.detail ?? '';
    return switch (tag) {
      _ReasonTag.last => e.kind == BotHistoryKind.last,
      _ReasonTag.stoppedByUser =>
        detail.contains('Stopped from the app.') ||
            detail.contains('Stopped manually via the gear menu.') ||
            detail.contains('Canceled directly on Pionex/TradingView'),
      _ReasonTag.stopLossLock => detail.contains('Stop Loss Lock'),
    };
  }

  /// Replaces the old single generic "Terminated" chip (2026-09-22, per the
  /// user: "instead of 'terminated' tag in history card. i want a tag for
  /// interval... & tag for other things like 'terminated by user', 'last',
  /// 'SLL', and so on") with the SPECIFIC real reason, reusing the exact
  /// same `detail` substrings [_matchesReasonTag]/the engine's own
  /// `_reconciledCloseReason` already produce - every distinct wording that
  /// function can return gets its own label/tone here, so this can never
  /// silently drift out of sync with what's actually being written to
  /// `detail`. Falls back to the bare kind label for anything genuinely
  /// unmatched (a reason string this screen doesn't know about yet, or one
  /// of the few kinds - `terminated` with no real reason available - that
  /// never gets more specific than that).
  ({String label, ReuseChipTone tone}) _reasonChip(BotHistoryEntry e) {
    if (e.kind == BotHistoryKind.last) {
      return (label: 'Last', tone: ReuseChipTone.neutral);
    }
    if (e.kind == BotHistoryKind.convertedToManual) {
      return (label: 'Converted to manual', tone: ReuseChipTone.warning);
    }
    // Prefer the structured `stopReason` field (2026-09-26, per the user:
    // "i want to add stop signal - it can be TP/SL/Terminated by user/
    // close signal/etc") - reliable by construction, unlike the substring
    // fallback below, which stays only for entries recorded before this
    // field existed.
    switch (e.stopReason) {
      case 'take_profit':
        return (label: 'Take Profit', tone: ReuseChipTone.success);
      case 'stop_loss_baseline':
        return (label: 'SL Baseline', tone: ReuseChipTone.danger);
      case 'stop_loss_ratchet':
        return (label: 'SL Ratchet', tone: ReuseChipTone.danger);
      case 'stop_loss_lock':
        return (label: 'SLL', tone: ReuseChipTone.danger);
      case 'liquidation':
        return (label: 'Liquidated', tone: ReuseChipTone.danger);
      case 'terminated_by_user':
        return (label: 'Terminated by user', tone: ReuseChipTone.warning);
      case 'close_signal':
        return (label: 'Close Signal', tone: ReuseChipTone.neutral);
      case 'never_filled':
        return (label: 'Never Filled', tone: ReuseChipTone.warning);
    }
    final detail = e.detail ?? '';
    if (detail.contains('Stop Loss Lock')) {
      return (label: 'SLL', tone: ReuseChipTone.danger);
    }
    if (detail.contains('Stopped from the app.') ||
        detail.contains('Stopped manually via the gear menu.') ||
        detail.contains('Canceled directly on Pionex/TradingView')) {
      return (label: 'Terminated by user', tone: ReuseChipTone.warning);
    }
    if (detail.contains('ratchet had already locked')) {
      return (label: 'SL Ratchet', tone: ReuseChipTone.danger);
    }
    if (detail.contains('-50% (baseline) triggered')) {
      return (label: 'SL Baseline', tone: ReuseChipTone.danger);
    }
    if (detail.contains('Take-profit triggered')) {
      return (label: 'Take Profit', tone: ReuseChipTone.success);
    }
    if (detail.contains('Position liquidated')) {
      return (label: 'Liquidated', tone: ReuseChipTone.danger);
    }
    return (label: e.kind.label, tone: ReuseChipTone.danger);
  }

  bool _matches(BotHistoryEntry e) {
    if (_typeFilters.isNotEmpty) {
      final type = e.category != null
          ? _BotTypeFilter.auto
          : _BotTypeFilter.manual;
      if (!_typeFilters.contains(type)) return false;
    }
    if (_categoryFilters.isNotEmpty &&
        (e.category == null || !_categoryFilters.contains(e.category))) {
      return false;
    }
    if (_reasonFilters.isNotEmpty &&
        !_reasonFilters.any((tag) => _matchesReasonTag(e, tag))) {
      return false;
    }
    return true;
  }

  bool get _hasActiveFilters =>
      _typeFilters.isNotEmpty ||
      _categoryFilters.isNotEmpty ||
      _reasonFilters.isNotEmpty;

  Widget _filterBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CoreSpacing.md,
        CoreSpacing.sm,
        CoreSpacing.md,
        0,
      ),
      child: Wrap(
        spacing: CoreSpacing.xs,
        runSpacing: CoreSpacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilterChip(
            label: const Text('Auto'),
            selected: _typeFilters.contains(_BotTypeFilter.auto),
            onSelected: (v) => setState(
              () => v
                  ? _typeFilters.add(_BotTypeFilter.auto)
                  : _typeFilters.remove(_BotTypeFilter.auto),
            ),
          ),
          FilterChip(
            label: const Text('Manual'),
            selected: _typeFilters.contains(_BotTypeFilter.manual),
            onSelected: (v) => setState(
              () => v
                  ? _typeFilters.add(_BotTypeFilter.manual)
                  : _typeFilters.remove(_BotTypeFilter.manual),
            ),
          ),
          const SizedBox(width: CoreSpacing.xs, child: VerticalDivider()),
          for (final c in allAutoCategories)
            FilterChip(
              label: Text(c.label),
              selected: _categoryFilters.contains(c),
              onSelected: (v) => setState(
                () => v ? _categoryFilters.add(c) : _categoryFilters.remove(c),
              ),
            ),
          const SizedBox(width: CoreSpacing.xs, child: VerticalDivider()),
          FilterChip(
            label: const Text('Last'),
            selected: _reasonFilters.contains(_ReasonTag.last),
            onSelected: (v) => setState(
              () => v
                  ? _reasonFilters.add(_ReasonTag.last)
                  : _reasonFilters.remove(_ReasonTag.last),
            ),
          ),
          FilterChip(
            label: const Text('Stopped by user'),
            selected: _reasonFilters.contains(_ReasonTag.stoppedByUser),
            onSelected: (v) => setState(
              () => v
                  ? _reasonFilters.add(_ReasonTag.stoppedByUser)
                  : _reasonFilters.remove(_ReasonTag.stoppedByUser),
            ),
          ),
          FilterChip(
            label: const Text('SLL'),
            selected: _reasonFilters.contains(_ReasonTag.stopLossLock),
            onSelected: (v) => setState(
              () => v
                  ? _reasonFilters.add(_ReasonTag.stopLossLock)
                  : _reasonFilters.remove(_ReasonTag.stopLossLock),
            ),
          ),
          if (_hasActiveFilters)
            ActionChip(
              avatar: const Icon(Icons.close, size: 16),
              label: const Text('Clear'),
              onPressed: () => setState(() {
                _typeFilters.clear();
                _categoryFilters.clear();
                _reasonFilters.clear();
              }),
            ),
        ],
      ),
    );
  }

  /// Sum shown at the top of the screen (2026-09-22, per the user: "i want
  /// to have sum at the top of the hisotry screen, this sum will be changed
  /// according to filter selection") - recomputed from whatever the
  /// current filter selection leaves visible, so it's always the sum of
  /// exactly what's on screen. Scoped to the same P&L-reset boundary as the
  /// official Dashboard sum and this screen's own reset divider (an entry
  /// before the reset never counted toward "the sum" anywhere else in the
  /// app, so this shouldn't silently start counting it either) - [entries]
  /// is null only while history is still loading/erroring, in which case
  /// nothing is shown yet.
  Widget _sumBar(
    BuildContext context,
    List<BotHistoryEntry>? entries,
    DateTime? resetSince,
  ) {
    if (entries == null) return const SizedBox.shrink();
    final scoped = resetSince == null
        ? entries
        : entries.where((e) => !e.ts.isBefore(resetSince)).toList();
    final sum = scoped.fold<double>(
      0,
      (acc, e) => acc + (e.realizedProfit ?? 0),
    );
    final color = sum >= 0
        ? context.tradingColors.profit
        : context.tradingColors.loss;
    final sign = sum < 0 ? '-' : '+';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CoreSpacing.md,
        CoreSpacing.sm,
        CoreSpacing.md,
        0,
      ),
      child: Row(
        children: [
          Text(
            _hasActiveFilters ? 'Sum (filtered):' : 'Sum:',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(width: CoreSpacing.xs),
          Text(
            '$sign${UtilString.usd(sum.abs())}',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: CoreSpacing.xs),
          Text(
            '(${scoped.length} entr${scoped.length == 1 ? 'y' : 'ies'})',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearAll(
    BuildContext context,
    WidgetRef ref,
    EngineControlRepository repo,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all history'),
        content: const Text(
          'Permanently delete every history record? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete all'),
          ),
        ],
      ),
    );
    if (ok == true) {
      repo.clearHistory();
      ref.invalidate(botHistoryProvider);
    }
  }

  /// Card background tint by P&L (2026-09-19, per the user: "the card in
  /// history should have 3 colors. yellow for 0.00 P&L, green for positive
  /// P&L, red for negative P&L") - null (no realizedProfit at all, e.g. a
  /// "Last" entry, which never gets one) keeps the theme's normal card
  /// color rather than forcing one of the three.
  Color? _cardColor(BuildContext context, double? pnl) {
    if (pnl == null) return null;
    final trading = context.tradingColors;
    if (pnl > 0) return trading.profitContainer;
    if (pnl < 0) return trading.lossContainer;
    return Colors.amber.withValues(alpha: 0.18);
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(controlRepositoryProvider);
    final historyAsync = ref.watch(botHistoryProvider);
    // Same summary the Auto bots card itself uses - reused here so the
    // divider's position AND the net figure it shows can never drift out of
    // sync with what's actually counted.
    final pnl = repo.pnlSummary();
    final resetSince = pnl.since;
    final netColor = pnl.net >= 0
        ? context.tradingColors.profit
        : context.tradingColors.loss;
    final netSign = pnl.net < 0 ? '-' : '+';
    // Filtered independently of the `.when()` builder below (2026-09-22, per
    // the user) so the top-of-screen sum stays visible/correct even while
    // that builder is mid-rebuild for an unrelated reason - `.value` (this
    // riverpod version's nullable data getter) is null only during the
    // genuine initial load/error state, which `_sumBar` itself handles.
    final filteredEntries = historyAsync.value?.where(_matches).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Delete all history',
            onPressed: () => _confirmClearAll(context, ref, repo),
          ),
        ],
      ),
      body: Column(
        children: [
          _sumBar(context, filteredEntries, resetSince),
          _filterBar(context),
          Expanded(
            child: historyAsync.when(
              loading: () => const ReuseLoadingIndicator(),
              error: (err, st) => ReuseError(message: '$err'),
              data: (allEntries) {
                final entries = allEntries.where(_matches).toList();
                return LayoutBuilder(
                  builder: (context, constraints) {
                    if (allEntries.isEmpty) {
                      return const Center(
                        child: ReuseEmptyState(
                          message:
                              'No history yet — a bot shows up here once it\'s '
                              'retired, stopped, or converted to manual.',
                          icon: Icons.history,
                        ),
                      );
                    }
                    if (entries.isEmpty) {
                      return const Center(
                        child: ReuseEmptyState(
                          message: 'No history matches the selected filters.',
                          icon: Icons.filter_alt_off_outlined,
                        ),
                      );
                    }
                    // Index of the divider (2026-09-19, per the user: "there
                    // should be a single dot in right side scroll to show the
                    // location of this line in the scroll bar") - drives the dot's
                    // vertical position as a fraction of the list, an
                    // approximation (list items vary slightly in height) rather
                    // than an exact scroll-offset match, which is good enough for
                    // "roughly where the reset is" at a glance.
                    int? dividerIndex;
                    if (resetSince != null) {
                      for (var i = 0; i < entries.length; i++) {
                        if (entries[i].ts.isBefore(resetSince)) {
                          dividerIndex = i;
                          break;
                        }
                      }
                    }
                    return Stack(
                      children: [
                        ListView(
                          padding: CoreLayout.edgeMargin(constraints),
                          children: [
                            for (final (index, e) in entries.indexed) ...[
                              // Reset divider (2026-09-19, per the user: "add a
                              // horizontal line... everything below this line is
                              // not included in sum, everything above is
                              // included") - entries are newest-first, so this
                              // lands right before the first entry whose `ts` falls
                              // before the reset boundary, i.e. exactly where
                              // repo.pnlSummary() itself stops counting.
                              if (resetSince != null &&
                                  e.ts.isBefore(resetSince) &&
                                  (index == 0 ||
                                      !entries[index - 1].ts.isBefore(
                                        resetSince,
                                      )))
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: CoreSpacing.sm,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Divider(
                                          thickness: 4,
                                          color: netColor,
                                        ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: CoreSpacing.sm,
                                        ),
                                        child: Text(
                                          '$netSign${UtilString.usd(pnl.net.abs())}',
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelSmall
                                              ?.copyWith(
                                                color: netColor,
                                                fontWeight: FontWeight.bold,
                                              ),
                                        ),
                                      ),
                                      Expanded(
                                        child: Divider(
                                          thickness: 4,
                                          color: netColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ReuseCard(
                                color: _cardColor(context, e.realizedProfit),
                                child: InkWell(
                                  onTap: () => context.push(
                                    '/history-details',
                                    extra: e,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Text(
                                                  e.pairKey,
                                                  style: Theme.of(
                                                    context,
                                                  ).textTheme.titleMedium,
                                                ),
                                                const SizedBox(
                                                  width: CoreSpacing.sm,
                                                ),
                                                // Interval tag + reason tag
                                                // (2026-09-22, per the user:
                                                // "instead of 'terminated'
                                                // tag... i want a tag for
                                                // interval... & tag for
                                                // other things like
                                                // 'terminated by user',
                                                // 'last', 'SLL'") - replaces
                                                // the old single generic
                                                // kind-based chip. The
                                                // interval only ever shows
                                                // for an auto entry (manual
                                                // entries have no category).
                                                if (e.category != null) ...[
                                                  ReuseChip(
                                                    label: e.category!.label,
                                                    tone: ReuseChipTone.neutral,
                                                  ),
                                                  const SizedBox(width: 4),
                                                ],
                                                ReuseChip(
                                                  label: _reasonChip(e).label,
                                                  tone: _reasonChip(e).tone,
                                                ),
                                                // P&L value (2026-09-19, per the
                                                // user: "the card in history...
                                                // and in the card it should be
                                                // mentioned the value, not in
                                                // details screen") - previously
                                                // only shown on the details screen.
                                                if (e.realizedProfit !=
                                                    null) ...[
                                                  const Spacer(),
                                                  Text(
                                                    '${e.realizedProfit! >= 0 ? '+' : ''}${UtilString.usd(e.realizedProfit!)}',
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleMedium
                                                        ?.copyWith(
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          color:
                                                              e.realizedProfit! >
                                                                  0
                                                              ? context
                                                                    .tradingColors
                                                                    .profit
                                                              : e.realizedProfit! <
                                                                    0
                                                              ? context
                                                                    .tradingColors
                                                                    .loss
                                                              : Colors
                                                                    .amber
                                                                    .shade800,
                                                        ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              UtilDate.dateTime(e.ts),
                                              style: Theme.of(
                                                context,
                                              ).textTheme.bodySmall,
                                            ),
                                            if (e.buOrderId != null) ...[
                                              const SizedBox(height: 2),
                                              // Selectable (2026-09-22, per
                                              // the user: "i want bot id to
                                              // be selectable") - a plain
                                              // Text can't be highlighted/
                                              // copied; SelectableText's own
                                              // drag-select gesture takes
                                              // priority over the row's
                                              // InkWell tap when the user is
                                              // actually dragging across
                                              // this text, so selecting the
                                              // ID no longer also opens the
                                              // details screen.
                                              SelectableText(
                                                'Bot ID: ${e.buOrderId}',
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.bodySmall,
                                              ),
                                            ],
                                            if (e.detail != null) ...[
                                              const SizedBox(height: 2),
                                              Text(
                                                e.detail!,
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.bodySmall,
                                              ),
                                            ],
                                            // The entry-signal record
                                            // (2026-09-26, per the user:
                                            // "the record should be one out
                                            // of those 60 entries") -
                                            // permanently carried into
                                            // History at close time (see
                                            // `BotHistoryEntry
                                            // .openSignalType` etc), so it
                                            // survives even after the live
                                            // `EntrySignalStore` record for
                                            // this buOrderId is forgotten.
                                            if (e.openSignalType != null) ...[
                                              const SizedBox(height: 2),
                                              Text(
                                                // Timestamped per the user
                                                // (2026-09-26: "you have to
                                                // include date and time for
                                                // open/close in history..
                                                // so each singla is time
                                                // stamped too") - using
                                                // TradingView's own bar
                                                // time (openSignalAt/
                                                // closeSignalAt), not
                                                // ts/startTime/endTime
                                                // (when the app itself
                                                // recorded/acted on it).
                                                e.closeSignalType != null
                                                    ? '${_signalLine('Opened', e.openSignalType, e.openSignalZone, e.openSignalValue, e.openSignalAt)}\n'
                                                          '${_signalLine('Closed', e.closeSignalType, e.closeSignalZone, e.closeSignalValue, e.closeSignalAt)}'
                                                    : _signalLine('Opened', e.openSignalType, e.openSignalZone, e.openSignalValue, e.openSignalAt),
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall
                                                    ?.copyWith(
                                                      fontStyle:
                                                          FontStyle.italic,
                                                    ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline),
                                        tooltip: 'Delete this record',
                                        onPressed: () {
                                          repo.deleteHistoryEntry(e.id);
                                          ref.invalidate(botHistoryProvider);
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (dividerIndex != null)
                          Positioned(
                            right: 2,
                            top:
                                (dividerIndex / entries.length) *
                                constraints.maxHeight,
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: Colors.amber,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
