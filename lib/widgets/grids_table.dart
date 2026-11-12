import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/core_spacing.dart';
import '../core/core_theme.dart';
import '../data/identity/entry_signal_store.dart';
import '../data/models/auto_category.dart';
import '../data/models/grid_bot.dart';
import '../utilities/util_string.dart';
import 'bot_actions_menu.dart';
import 'reuse_button.dart';
import 'reuse_chip.dart';
import 'reuse_data_table.dart';
import 'reuse_empty_state.dart';

/// Renders a list of [GridBot]s — the SAME table, same columns, same
/// checkbox-select-then-bulk-action mechanism, for both the Manual bots and
/// Auto bots tables (per the user, 2026-09-06: "make auto bot table and
/// manual bot table identical"). Every column shown is real data pulled
/// from TradingView/Pionex (or derived from it) - nothing invented.
///
/// Which bulk action(s) actually appear depends on which callback the
/// caller passes: manual bots table -> [onBulkConvertToAuto] (never
/// stop/close, per PRD §10 rule 2 - the app never touches a manual bot);
/// auto bots table -> [onBulkStop]/[onBulkLast]. Tapping a row (anywhere
/// outside the checkbox) opens BotDetailsScreen with every Pionex-reported
/// field for that bot.
class GridsTable extends StatefulWidget {
  const GridsTable({
    super.key,
    required this.grids,
    this.busy = false,
    this.emptyMessage = 'No grids running.',
    this.lastMarkedBases = const {},
    this.onCancelLast,
    this.cancelLastActiveRowId,
    this.stopLossLockedIds = const {},
    this.onCancelStopLossLock,
    this.cancelStopLossLockActiveRowId,
    this.onBulkConvertToAuto,
    this.onBulkStop,
    this.onBulkLast,
    this.onBulkConvertToManual,
    this.onBulkStopLossLock,
    this.categoryOf,
    this.cycleMarkerFor,
    this.entrySignalFor,
    this.closeCandidateFor,
    this.asCards = false,
    this.favoriteIds = const {},
  });

  /// Bots opened as favorite trades - a star on their card.
  final Set<String> favoriteIds;

  /// tradingMT5-style running cards instead of the table (Auto bots).
  final bool asCards;

  final List<GridBot> grids;
  final bool busy;
  final String emptyMessage;

  /// Uppercase bases currently sent through the "Last" flow (retired) - each
  /// keeps running and shows here like any other auto bot until it closes on
  /// its own, but the engine will never auto-recreate it afterward. Rows
  /// whose base is in this set get a tappable flag icon to undo that.
  final Set<String> lastMarkedBases;

  /// Called when the flag icon on an already-Last-marked row is tapped -
  /// wired to unretire that base so it goes back to auto-recreating
  /// normally.
  final void Function(GridBot bot)? onCancelLast;

  /// The `buOrderId` of the one row whose [onCancelLast] is actually
  /// running right now, if any - shows a spinner in place of just that
  /// row's flag icon.
  final String? cancelLastActiveRowId;

  /// buOrderIds currently tagged for "Stop Loss Lock" (2026-09-22, per the
  /// user: "add a disable toggle same as last toggle") - resolved by the
  /// caller via [EngineControlRepository.stopLossLockedIds] so this widget
  /// never needs to know auto-vs-manual tag-key differences. A row whose
  /// buOrderId is in this set gets the same kind of tappable toggle chip
  /// [lastMarkedBases] gives a Last-marked row.
  final Set<String> stopLossLockedIds;

  /// Called when an already-locked row's toggle is switched off - wired to
  /// disable Stop Loss Lock for that one bot.
  final void Function(GridBot bot)? onCancelStopLossLock;

  /// The `buOrderId` of the one row whose [onCancelStopLossLock] is
  /// actually running right now, if any - shows a spinner in place of just
  /// that row's toggle, same pattern as [cancelLastActiveRowId].
  final String? cancelStopLossLockActiveRowId;

  /// Manual bots table's bulk action - hands every selected bot over to the
  /// app (Auto Bots report, opposite-signal close from here on). The bot(s)
  /// themselves are never touched on Pionex by this action.
  final Future<void> Function(List<GridBot> bots)? onBulkConvertToAuto;

  /// Auto bots table's bulk actions.
  final Future<void> Function(List<GridBot> bots)? onBulkStop;
  final Future<void> Function(List<GridBot> bots)? onBulkLast;

  /// Auto bots table's bulk action - the reverse of [onBulkConvertToAuto]:
  /// removes each selected bot from the app's own tracking (it moves to the
  /// Manual bots table from here on). The bot(s) themselves are never
  /// touched on Pionex by this action either.
  final Future<void> Function(List<GridBot> bots)? onBulkConvertToManual;

  /// Bulk-tags every selected bot for "Stop Loss Lock" (2026-09-22, per the
  /// user: "add SL lock icon button next to buttons series in auto card and
  /// in manual card... once a list of bots is checked, then SL lock icon is
  /// tagged and applied") - available on BOTH the Auto and Manual bots
  /// tables. Bulk-only ENABLES the tag (matches [onBulkLast]'s own
  /// enable-only bulk convention) - disabling one is a per-row action via
  /// the gear menu's own Stop Loss Lock sheet. The caller is responsible for
  /// resolving a manual bot's chart timeframe (it has none inherently)
  /// before calling this - see the Manual bots table's own wiring.
  ///
  /// The 2nd argument, [markPending], must be called exactly once the
  /// caller is genuinely committed to tagging (2026-09-22, per the user:
  /// "while the selected bots... are still in stop loss lock process, the
  /// check box is disabled... once the process is done, check box is
  /// active and deselected") - deliberately NOT marked automatically on
  /// click like [onBulkStop]/[onBulkLast], since the Manual bots table's
  /// own wiring shows a cancellable chart-timeframe picker FIRST; marking
  /// pending unconditionally would leave a row's checkbox stuck disabled
  /// forever if that picker gets cancelled (nothing would ever land in
  /// [stopLossLockedIds] to clear it). Call it right after any such
  /// picker resolves successfully, immediately before the real repository
  /// call - the Auto tables' own wiring (no picker needed) just calls it
  /// first thing.
  final Future<void> Function(List<GridBot> bots, VoidCallback markPending)?
  onBulkStopLossLock;

  /// The category (1m/1H/1D) an app-initiated bot belongs to, if known -
  /// null (the default) means don't tag rows at all (manual bots table has
  /// no use for it). Sourced from `BotCategoryStore` (2026-09-07).
  final AutoCategory? Function(String buOrderId)? categoryOf;

  /// The rotating cycle-marker text to show next to this bot's pair name,
  /// if any (2026-09-12, per the user: "add an icon/emoji next to pair
  /// name... once pair is checked in this interval, ad same emoji/icon
  /// next to pair name... this will help user to identify and assure if
  /// all list get checked in this interval or not"). Null/empty shows
  /// nothing - manual bots (no category) never pass this at all. The
  /// caller resolves the actual marker text (comparing the bot's last-
  /// checked marker against its category's CURRENT one) since that needs
  /// both `EngineControlRepository.cycleMarkerFor` and `EngineStatus` -
  /// this widget only renders whatever string it's given.
  final String? Function(GridBot bot)? cycleMarkerFor;

  /// Which of the user's 60 (signal, zone) table entries opened this bot -
  /// and, once known, which one closed it (2026-09-26, per the user: "the
  /// record should be one out of those 60 entries"). Resolves via
  /// `EngineControlRepository.entrySignalFor(buOrderId)`; null (shown as
  /// "—") for a bot opened before this feature existed, or via a path with
  /// no confirmed signal on hand.
  final EntrySignalRecord? Function(String buOrderId)? entrySignalFor;

  /// tradingMT5's Close A / Close B for a running bot - see
  /// EngineControlRepository.closeCandidateFor.
  final ({String kind, DateTime barTime, DateTime eta})? Function(GridBot bot)?
  closeCandidateFor;

  @override
  State<GridsTable> createState() => _GridsTableState();
}

class _GridsTableState extends State<GridsTable> {
  final Set<String> _selected = {};

  /// buOrderIds a bulk action (Stop/Convert/Last) was just fired on
  /// (2026-09-18, per the user: "once user select a list of running bots
  /// and make an action, their checkbox should not become active until the
  /// process is over" - e.g. Stop's checkbox must stay disabled until the
  /// bot is completely terminated, "same about last and convert to
  /// manual... and convert to auto"). A row in this set keeps showing
  /// checked (still selected) but its checkbox becomes uninteractive -
  /// cleared automatically in [didUpdateWidget] once the action's real
  /// completion signal shows up: the bot leaving this table entirely
  /// (Stop/Convert - it stops appearing in [GridsTable.grids]) or, for
  /// Last specifically (which deliberately keeps running in this SAME
  /// list), the base actually landing in [GridsTable.lastMarkedBases].
  final Set<String> _pendingAction = {};

  /// Subset of [_pendingAction] pending specifically because of a Last
  /// click (2026-09-20, per the user: "once pair is tagged last, the check
  /// box is still checked"). Needed as its own set, separate from a plain
  /// "is this base in lastMarkedBases right now" check: a base can already
  /// be Last-marked from an EARLIER action while the user selects it again
  /// for something unrelated (e.g. bulk-Stopping an already-Last bot) -
  /// without this, the very next poll would see "already last-marked" and
  /// immediately clear that unrelated selection/pending-Stop before it had
  /// a chance to complete, reintroducing the exact race the 2026-09-18 fix
  /// prevented. Only a base that WASN'T last-marked when Last was clicked,
  /// and now is, counts as this specific action's own completion signal.
  final Set<String> _pendingLastAction = {};

  /// Same as [_pendingLastAction], for a bulk "Stop Loss Lock" tag
  /// (2026-09-22, per the user: "while the selected bots... are still in
  /// stop loss lock process, the check box is disabled. once the process
  /// is done, check box is active and deselected") - a Stop Loss Lock tag
  /// also keeps the bot running in this SAME list (unlike Stop/Convert), so
  /// its own completion signal is landing in [GridsTable.stopLossLockedIds]
  /// rather than leaving the table.
  final Set<String> _pendingStopLossLockAction = {};

  /// Matches [GridsTable.lastMarkedBases]' raw keys (RetiredStore's
  /// composite "BASE|CATEGORY_WIRE" keys, or a legacy bare "BASE" from
  /// before the 2026-09-20 category-scoping fix) against one row - a bare
  /// base with no category available falls back to "retired under ANY
  /// category" so a row never silently loses its Last tag just because
  /// [GridsTable.categoryOf] returned null for it.
  bool _isLastMarked(String bareBase, AutoCategory? category) {
    if (widget.lastMarkedBases.contains(bareBase)) return true;
    if (category == null) return false;
    return widget.lastMarkedBases.contains('$bareBase|${category.wireValue}');
  }

  bool get _hasBulkActions =>
      widget.onBulkConvertToAuto != null ||
      widget.onBulkStop != null ||
      widget.onBulkLast != null ||
      widget.onBulkConvertToManual != null ||
      widget.onBulkStopLossLock != null;

  @override
  void didUpdateWidget(covariant GridsTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A bot that closed/stopped since the last poll can't stay selected.
    final currentIds = widget.grids.map((g) => g.buOrderId).toSet();
    // A bot just marked Last deliberately keeps running in this SAME list
    // (unlike Stop/Convert, which make it leave the table outright), so
    // the plain "no longer in currentIds" check below never clears it on
    // its own - scoped to `_pendingLastAction` only (see its own doc
    // comment for why a bare "is this base last-marked" check isn't safe
    // to use for the general `_selected` set).
    bool justFinishedLast(String id) {
      if (!_pendingLastAction.contains(id)) return false;
      for (final g in widget.grids) {
        if (g.buOrderId != id) continue;
        final bareBase = g.base
            .toUpperCase()
            .replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '');
        return _isLastMarked(bareBase, widget.categoryOf?.call(id));
      }
      return false;
    }

    bool justFinishedStopLossLock(String id) {
      if (!_pendingStopLossLockAction.contains(id)) return false;
      return widget.stopLossLockedIds.contains(id);
    }

    bool justFinished(String id) =>
        justFinishedLast(id) || justFinishedStopLossLock(id);

    _selected.removeWhere(
      (id) => !currentIds.contains(id) || justFinished(id),
    );
    _pendingAction.removeWhere(
      (id) => !currentIds.contains(id) || justFinished(id),
    );
    _pendingLastAction.removeWhere(
      (id) => !currentIds.contains(id) || justFinishedLast(id),
    );
    _pendingStopLossLockAction.removeWhere(
      (id) => !currentIds.contains(id) || justFinishedStopLossLock(id),
    );
  }

  void _markPending(
    Iterable<GridBot> bots, {
    bool isLast = false,
    bool isStopLossLock = false,
  }) {
    setState(() {
      final ids = bots.map((b) => b.buOrderId);
      _pendingAction.addAll(ids);
      if (isLast) _pendingLastAction.addAll(ids);
      if (isStopLossLock) _pendingStopLossLockAction.addAll(ids);
    });
  }

  void _selectAll() {
    setState(() {
      _selected
        ..clear()
        ..addAll(widget.grids.map((g) => g.buOrderId));
    });
  }

  String _formatDuration(Duration? d) {
    if (d == null) return '—';
    final days = d.inDays;
    final hours = d.inHours % 24;
    final minutes = d.inMinutes % 60;
    if (days > 0) return '${days}d ${hours}h';
    if (hours > 0) return '${hours}h ${minutes}m';
    return '${minutes}m';
  }

  String _twoDigits(int n) => n.toString().padLeft(2, '0');

  /// Renders "the record" (2026-09-26, per the user: "the record should be
  /// one out of those 60 entries") - which exact (signal, zone) entry
  /// opened this bot, and, once known, which one closed it. "—" for a bot
  /// with no record on file (opened before this feature existed, or via a
  /// path with no confirmed signal on hand, e.g. a forced reignite).
  /// tradingMT5's labels for a Hybrid Decision event.
  String _eventLabel(String type) => switch (type) {
    'buyOpen1' => 'LL',
    'sellOpen1' => 'HH',
    'zigzagBuy' => 'Buy',
    'zigzagSell' => 'Sell',
    _ => type,
  };

  String _shortTime(DateTime t) {
    final l = t.toLocal();
    return '${_twoDigits(l.month)}-${_twoDigits(l.day)} ${_twoDigits(l.hour)}:${_twoDigits(l.minute)}';
  }

  /// Open / Update / Close A / Close B, as tradingMT5 shows them on a
  /// running auto trade.
  Widget _entrySignalCell(GridBot bot, EntrySignalRecord? record) {
    final candidate = widget.closeCandidateFor?.call(bot);
    if (record == null && candidate == null) return const Text('—');
    final lines = <String>[
      if (record != null)
        'Open: ${_eventLabel(record.open.type)} ${_shortTime(record.open.at)}',
      if (record?.update != null)
        'Update: ${_eventLabel(record!.update!.type)} ${_shortTime(record.update!.at)}',
      if (candidate != null) ...[
        'Close A: ${_eventLabel(candidate.kind)} ${_shortTime(candidate.barTime)}',
        'Close B: watching until ${_shortTime(candidate.eta)}',
      ],
      if (record?.close != null)
        'Closed: ${_eventLabel(record!.close!.type)} ${_shortTime(record.close!.at)}',
    ];
    return Text(lines.join('\n'), style: const TextStyle(fontSize: 12));
  }

  @override
  Widget build(BuildContext context) {
    final trading = context.tradingColors;
    final grids = widget.grids;
    final selectedBots = grids
        .where((g) => _selected.contains(g.buOrderId))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (grids.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: CoreSpacing.sm),
            child: ReuseEmptyState(
              message: widget.emptyMessage,
              icon: Icons.smart_toy_outlined,
            ),
          )
        else ...[
          if (_hasBulkActions) ...[
            Wrap(
              spacing: CoreSpacing.sm,
              runSpacing: CoreSpacing.sm,
              children: [
                if (widget.asCards)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: grids.isNotEmpty &&
                            _selected.length == grids.length,
                        onChanged: (v) => v == true
                            ? _selectAll()
                            : setState(_selected.clear),
                      ),
                      const Text('Select all'),
                    ],
                  ),
                if (widget.onBulkConvertToAuto != null)
                  ReuseButton(
                    label: 'Convert to Auto',
                    icon: Icons.smart_toy_outlined,
                    onPressed: (widget.busy || selectedBots.isEmpty)
                        ? null
                        : () {
                            _markPending(selectedBots);
                            widget.onBulkConvertToAuto!(selectedBots);
                          },
                  ),
                if (widget.onBulkConvertToManual != null)
                  ReuseButton(
                    label: 'Convert to Manual',
                    icon: Icons.person_outline,
                    tone: ReuseButtonTone.neutral,
                    onPressed: (widget.busy || selectedBots.isEmpty)
                        ? null
                        : () {
                            _markPending(selectedBots);
                            widget.onBulkConvertToManual!(selectedBots);
                          },
                  ),
                if (widget.onBulkLast != null)
                  ReuseButton(
                    label: 'Last selected (${_selected.length})',
                    icon: Icons.flag_outlined,
                    tone: ReuseButtonTone.neutral,
                    onPressed: (widget.busy || selectedBots.isEmpty)
                        ? null
                        : () {
                            _markPending(selectedBots, isLast: true);
                            widget.onBulkLast!(selectedBots);
                          },
                  ),
                if (widget.onBulkStop != null)
                  ReuseButton(
                    label: 'Stop selected (${_selected.length})',
                    icon: Icons.stop_circle_outlined,
                    tone: ReuseButtonTone.danger,
                    onPressed: (widget.busy || selectedBots.isEmpty)
                        ? null
                        : () {
                            _markPending(selectedBots);
                            widget.onBulkStop!(selectedBots);
                          },
                  ),
                if (widget.onBulkStopLossLock != null)
                  ReuseButton(
                    label: 'Stop Loss Lock (${_selected.length})',
                    icon: Icons.lock_clock_outlined,
                    tone: ReuseButtonTone.neutral,
                    onPressed: (widget.busy || selectedBots.isEmpty)
                        ? null
                        : () => widget.onBulkStopLossLock!(
                            selectedBots,
                            () => _markPending(
                              selectedBots,
                              isStopLossLock: true,
                            ),
                          ),
                  ),
              ],
            ),
            const SizedBox(height: CoreSpacing.sm),
          ],
          if (widget.asCards)
            LayoutBuilder(
              builder: (context, constraints) {
                const gap = 12.0;
                final w = constraints.maxWidth;
                final n = (w / 330).floor().clamp(1, 4);
                final cardWidth = (w - gap * (n - 1)) / n;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final g in grids)
                      SizedBox(
                        width: cardWidth,
                        child: _buildCard(g, trading),
                      ),
                  ],
                );
              },
            )
          else
          ReuseDataTable(
            showCheckboxColumn: _hasBulkActions,
            // Select-all now lives only in the table's own header checkbox
            // (per the user, 2026-09-11: the separate "Select all" text
            // link above was removed as redundant) - ticking it selects
            // every row, unticking clears the selection, same behavior the
            // old link had.
            onSelectAll: !_hasBulkActions
                ? null
                : (v) => v == true ? _selectAll() : setState(_selected.clear),
            columns: const [
              DataColumn(label: Text('')),
              DataColumn(label: Text('Pair')),
              DataColumn(label: Text('Bot ID')),
              DataColumn(label: Text('Direction')),
              DataColumn(label: Text('Entry signal')),
              DataColumn(label: Text('Status')),
              DataColumn(label: Text('Leverage')),
              DataColumn(label: Text('Current price')),
              // Per the user (2026-09-10): P&L, then Initial/Actual
              // investment/Extra margin, all moved here right after Current
              // price, in both this (Auto bots) and the Manual bots table -
              // one shared GridsTable, one change covers both.
              DataColumn(label: Text('P&L')),
              DataColumn(label: Text('Initial investment')),
              DataColumn(label: Text('Actual investment')),
              DataColumn(label: Text('Extra margin')),
              DataColumn(label: Text('Price range')),
              DataColumn(label: Text('Take profit')),
              DataColumn(label: Text('Stop loss')),
              DataColumn(label: Text('Grids')),
              DataColumn(label: Text('40/60')),
              DataColumn(label: Text('Liquidation')),
              DataColumn(label: Text('Duration')),
            ],
            rows: [for (final g in grids) _buildRow(g, trading)],
          ),
        ],
      ],
    );
  }

  DataRow _buildRow(GridBot g, TradingColors trading) {
    final category = widget.categoryOf?.call(g.buOrderId);
    final pairLabel = g.pairKey;
    // Pionex's raw `base` always carries a ".PERP" suffix ("GALA.PERP"), but
    // `lastMarkedBases` (RetiredStore) keys on the bare name ("GALA") - same
    // systemic mismatch fixed at every other retired-base comparison site
    // this session (RiskGate, hasLastPendingBots, etc). Strip it here too,
    // otherwise this tag would never show for a real bot.
    final bareBase = g.base
        .toUpperCase()
        .replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '');
    final cycleMarker = widget.cycleMarkerFor?.call(g);
    final categoryChip = category == null
        ? null
        : Container(
            margin: const EdgeInsets.only(left: 4),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.outline.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              category.label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          );
    final pairLabelWithMarker = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(pairLabel),
        if (categoryChip != null) categoryChip,
        if (cycleMarker != null && cycleMarker.isNotEmpty) ...[
          const SizedBox(width: 4),
          Text(
            cycleMarker,
            style: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
        ],
      ],
    );
    return DataRow(
      selected: _selected.contains(g.buOrderId),
      // Bug fixed 2026-09-11, per the user: this used to also disable
      // (visually, near-invisibly) every row's checkbox in BOTH the Auto
      // bots and Manual bots tables the ENTIRE time ANY action was
      // in-flight anywhere on the screen - `busy` here is the same global
      // flag the Next Trade table's Start button sets, and Start alone can
      // legitimately run for minutes (see the engine-log investigation
      // earlier today). Selecting a row is a harmless, purely local
      // toggle - it fires nothing - so it never needed to be blocked; only
      // the bulk-action BUTTONS below (which actually submit a request)
      // need to stay disabled during busy, and they already do via their
      // own `(widget.busy || selectedBots.isEmpty)` guard.
      //
      // Separately disabled (2026-09-18, per the user) while this specific
      // bot is in [_pendingAction] - a bulk action was just fired on it and
      // hasn't finished yet, so its checkbox stays checked but uninteractive
      // until [didUpdateWidget] confirms the action's real completion.
      onSelectChanged: (!_hasBulkActions || _pendingAction.contains(g.buOrderId))
          ? null
          : (v) => setState(
              () => v == true
                  ? _selected.add(g.buOrderId)
                  : _selected.remove(g.buOrderId),
            ),
      cells: [
        for (final entry in <Widget>[
          // Gear-icon "More" menu (2026-09-18, per the user: moved from the
          // trailing column to lead the row - "gear icon in tables, i dont
          // like its place, it should be before checkbox in tables". The
          // native checkbox column itself is untouched, per the user's
          // explicit follow-up ("dont modify anyhting in checkbox... just
          // make the gear icon at the beginning") - it still renders first,
          // leftmost, exactly as before; this is just the first of THIS
          // table's own columns now instead of the last. Right padding
          // keeps visible spacing between it and the Pair cell right after
          // it, per the user's "keep spacing" follow-up.
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: IconButton(
              icon: const Icon(Icons.settings_outlined, size: 20),
              tooltip: 'More',
              onPressed: () => showBotActionsMenu(context, bot: g),
            ),
          ),
          () {
            // Tag + toggle grouped into one visual unit (2026-09-20, per
            // the user: "make last tage and toggle inside one card") -
            // extended 2026-09-22 to a second, independent tag ("Stop Loss
            // Lock", per the user: "add a disable toggle same as last
            // toggle") - a row can show either, both, or neither; each is
            // its own self-contained chip+switch so the two never interact.
            final tags = <Widget>[
              if (_isLastMarked(bareBase, category))
                _tagChip(
                  label: 'Last',
                  background: Theme.of(context).colorScheme.errorContainer,
                  onBackground: Theme.of(context).colorScheme.onErrorContainer,
                  switchColor: trading.loss,
                  tooltip:
                      'Last active — will finish naturally '
                      'and never auto-recreate. Toggle off to cancel.',
                  spinning: widget.cancelLastActiveRowId == g.buOrderId,
                  busy: widget.busy,
                  onToggleOff: () => widget.onCancelLast?.call(g),
                ),
              if (widget.stopLossLockedIds.contains(g.buOrderId))
                _tagChip(
                  label: 'SL Lock',
                  background: Theme.of(context).colorScheme.primaryContainer,
                  onBackground: Theme.of(context).colorScheme.onPrimaryContainer,
                  switchColor: Theme.of(context).colorScheme.primary,
                  tooltip:
                      'Stop Loss Lock active — sole SL authority for this '
                      'pair once P&L clears +100%. Toggle off to disable.',
                  spinning: widget.cancelStopLossLockActiveRowId == g.buOrderId,
                  busy: widget.busy,
                  onToggleOff: () => widget.onCancelStopLossLock?.call(g),
                ),
            ];
            if (tags.isEmpty) return pairLabelWithMarker;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                pairLabelWithMarker,
                for (final tag in tags) ...[const SizedBox(width: 4), tag],
              ],
            );
          }(),
          Text(g.buOrderId),
          g.trend == null
              ? const Text('—')
              : ReuseChip(
                  label: g.trend!.wireValue.toUpperCase(),
                  tone: g.trend == GridDirection.long
                      ? ReuseChipTone.success
                      : ReuseChipTone.danger,
                ),
          _entrySignalCell(g, widget.entrySignalFor?.call(g.buOrderId)),
          Text(g.status),
          Text(g.leverage == null ? '—' : '${g.leverage!.toStringAsFixed(0)}x'),
          Text(
            g.currentPrice == null ? '—' : UtilString.price(g.currentPrice!),
          ),
          _ProfitCell(bot: g, trading: trading),
          Text(
            g.initialInvestment == null
                ? '—'
                : UtilString.usd(g.initialInvestment!),
          ),
          Text(
            g.actualInvestment == null
                ? '—'
                : UtilString.usd(g.actualInvestment!),
          ),
          Text(g.extraMargin == null ? '—' : UtilString.usd(g.extraMargin!)),
          Text(
            (g.bottom == null || g.top == null)
                ? '—'
                : '${UtilString.price(g.bottom!)}–${UtilString.price(g.top!)}',
          ),
          Text(
            g.takeProfitPrice == null
                ? '—'
                : UtilString.price(g.takeProfitPrice!),
          ),
          Text(
            g.stopLossPrice == null ? '—' : UtilString.price(g.stopLossPrice!),
          ),
          Text(g.row == null ? '—' : '${g.row}'),
          Text(g.widenApplied ? '40/60' : 'Neutral'),
          Text(
            (g.liquidationPrice == null || g.liquidationPrice == 0)
                ? '—'
                : UtilString.price(g.liquidationPrice!),
          ),
          Text(_formatDuration(g.duration)),
        ].asMap().entries)
          // Per the user (2026-09-06): only the Pair cell opens bot details
          // on tap/hover - every other cell is just selectable text, not
          // clickable. Pair is index 1 (2026-09-18) now that the gear icon
          // is a leading cell at index 0.
          DataCell(
            entry.value,
            onTap: entry.key == 1
                ? () => context.push('/bot-details', extra: g)
                : null,
          ),
      ],
    );
  }

  /// tradingMT5's running card, filled with this bot's Pionex fields.
  Widget _buildCard(GridBot g, TradingColors trading) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final category = widget.categoryOf?.call(g.buOrderId);
    final bareBase = g.base
        .toUpperCase()
        .replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '');
    final record = widget.entrySignalFor?.call(g.buOrderId);
    final candidate = widget.closeCandidateFor?.call(g);
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.outline);
    String p(double? v) => (v == null || v == 0) ? '—' : UtilString.price(v);
    String usd(double? v) => v == null ? '—' : UtilString.usd(v);

    Widget badge(String text, Color bg, Color fg) => Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: fg),
      ),
    );

    Widget kv(String k, String v, {Color? color}) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(k, style: muted),
          Text(
            v,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );

    Widget sig(String label, String value, {Color? color}) => Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(label, style: muted?.copyWith(color: color)),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );

    final long = g.trend == GridDirection.long;
    final profit = g.profitAmount;
    final pct = g.profitPercent;
    final pnlColor = profit == null
        ? null
        : (profit >= 0 ? trading.profit : trading.loss);
    final selected = _selected.contains(g.buOrderId);
    final pending = _pendingAction.contains(g.buOrderId);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Per the user (2026-11-12): from the left - the "more" dots, the
          // selection checkbox, a gap, then the pair and its chips. Chips
          // wrap to a new line rather than cutting text with "...".
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              BotMoreMenuButton(bot: g),
              if (_hasBulkActions)
                SizedBox(
                  width: 28,
                  height: 28,
                  child: Checkbox(
                    value: selected,
                    onChanged: pending
                        ? null
                        : (v) => setState(
                            () => v == true
                                ? _selected.add(g.buOrderId)
                                : _selected.remove(g.buOrderId),
                          ),
                  ),
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    InkWell(
                      onTap: () => context.push('/bot-details', extra: g),
                      child: Text(
                        g.pairKey,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (widget.cycleMarkerFor?.call(g) case final mark?)
                      Tooltip(
                        message: 'Checked this hour',
                        child: Text(
                          mark,
                          style: TextStyle(
                            color: trading.profit,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    if (widget.favoriteIds.contains(g.buOrderId))
                      const Tooltip(
                        message: 'Favorite trade',
                        child: Icon(Icons.star, size: 16, color: Colors.amber),
                      ),
                    if (g.trend != null)
                      badge(
                        long ? 'LONG' : 'SHORT',
                        (long ? trading.profit : trading.loss).withValues(alpha: 0.15),
                        long ? trading.profit : trading.loss,
                      ),
                    if (g.leverage != null)
                      badge(
                        '${g.leverage!.toStringAsFixed(0)}x',
                        scheme.outline.withValues(alpha: 0.15),
                        scheme.outline,
                      ),
                  ],
                ),
              ),
            ],
          ),
          Text(
            '#${g.buOrderId} · ${category?.label ?? '1H'} · '
            'lasting ${_formatDuration(g.duration)} · ${g.status}',
            style: muted,
          ),
          if (_isLastMarked(bareBase, category) ||
              widget.stopLossLockedIds.contains(g.buOrderId))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (_isLastMarked(bareBase, category))
                    _tagChip(
                      label: 'Last',
                      background: scheme.errorContainer,
                      onBackground: scheme.onErrorContainer,
                      switchColor: trading.loss,
                      tooltip:
                          'Last active — will finish naturally '
                          'and never auto-recreate. Toggle off to cancel.',
                      spinning: widget.cancelLastActiveRowId == g.buOrderId,
                      busy: widget.busy,
                      onToggleOff: () => widget.onCancelLast?.call(g),
                    ),
                  if (widget.stopLossLockedIds.contains(g.buOrderId))
                    _tagChip(
                      label: 'SL Lock',
                      background: scheme.primaryContainer,
                      onBackground: scheme.onPrimaryContainer,
                      switchColor: scheme.primary,
                      tooltip:
                          'Stop Loss Lock active. Toggle off to disable.',
                      spinning:
                          widget.cancelStopLossLockActiveRowId == g.buOrderId,
                      busy: widget.busy,
                      onToggleOff: () => widget.onCancelStopLossLock?.call(g),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Investment', style: muted),
                      Text(
                        usd(g.initialInvestment),
                        style: theme.textTheme.titleMedium,
                      ),
                      Text('actual ${usd(g.actualInvestment)}', style: muted),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('P&L', style: muted),
                      Text(
                        profit == null
                            ? '—'
                            : '${profit >= 0 ? '+' : ''}${UtilString.usd(profit)}',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: pnlColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (pct != null)
                        Text(
                          '${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(1)}%',
                          style: muted?.copyWith(color: pnlColor),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    kv('Price now', p(g.currentPrice)),
                    kv('Liquidation', p(g.liquidationPrice), color: trading.loss),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    kv('TP', p(g.takeProfitPrice), color: trading.profit),
                    kv('SL', p(g.stopLossPrice), color: trading.loss),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    kv('Extra margin', usd(g.extraMargin)),
                    kv(
                      'Grids',
                      '${g.row ?? '—'} · ${g.widenApplied ? '40/60' : 'Neutral'}',
                    ),
                  ],
                ),
              ),
            ],
          ),
          kv(
            'Range',
            (g.bottom == null || g.top == null)
                ? '—'
                : '${UtilString.price(g.bottom!)} – ${UtilString.price(g.top!)}',
          ),
          const Divider(height: 12),
          if (record == null && candidate == null)
            sig('Open', '—')
          else ...[
            if (record != null)
              sig(
                'Open',
                '${_eventLabel(record.open.type)} · ${_shortTime(record.open.at)}',
              ),
            if (record?.update != null)
              sig(
                'Update',
                '${_eventLabel(record!.update!.type)} · ${_shortTime(record.update!.at)}',
              ),
            if (candidate != null) ...[
              sig(
                'Close A',
                '${_eventLabel(candidate.kind)} · ${_shortTime(candidate.barTime)}',
                color: Colors.orange,
              ),
              sig(
                'Close B',
                'watching · ETA ${_shortTime(candidate.eta)}',
                color: Colors.orange,
              ),
            ],
            if (record?.close != null)
              sig(
                'Closed',
                '${_eventLabel(record!.close!.type)} · ${_shortTime(record.close!.at)}',
              ),
          ],
        ],
      ),
    );
  }

  /// One self-contained "tag active — toggle off to cancel" chip (2026-09-20
  /// design, generalized 2026-09-22 for reuse between the "Last" and "Stop
  /// Loss Lock" tags - see their call sites in [_buildRow]). A bordered
  /// pill combining the label and its own on/off switch, matching the
  /// user's "grouped into one visual unit" request; [spinning] swaps the
  /// switch for a small progress indicator while the toggle-off request is
  /// still in flight.
  Widget _tagChip({
    required String label,
    required Color background,
    required Color onBackground,
    required Color switchColor,
    required String tooltip,
    required bool spinning,
    required bool busy,
    required VoidCallback onToggleOff,
  }) {
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: onBackground,
              fontWeight: FontWeight.w600,
            ),
          ),
          Tooltip(
            message: tooltip,
            child: spinning
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : Transform.scale(
                    scale: 0.7,
                    child: Switch(
                      value: true,
                      activeThumbColor: switchColor,
                      onChanged: busy
                          ? null
                          : (v) {
                              if (!v) onToggleOff();
                            },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ProfitCell extends StatelessWidget {
  const _ProfitCell({required this.bot, required this.trading});

  final GridBot bot;
  final TradingColors trading;

  @override
  Widget build(BuildContext context) {
    final profit = bot.profitAmount;
    if (profit == null) return const Text('—');
    final color = profit >= 0 ? trading.profit : trading.loss;
    final percent = bot.profitPercent;
    return Text(
      '${profit >= 0 ? '+' : ''}${UtilString.usd(profit)}${percent != null ? ' (${percent.toStringAsFixed(1)}%)' : ''}',
      style: TextStyle(color: color, fontWeight: FontWeight.w500),
    );
  }
}
