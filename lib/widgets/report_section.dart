import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/core_spacing.dart';
import '../core/core_theme.dart';
import '../data/models/auto_category.dart';
import '../data/models/engine_status.dart';
import '../data/models/grid_bot.dart';
import '../data/models/preview_grid_pair.dart';
import '../data/pionex/pionex_market.dart';
import '../l10n/app_localizations.dart';
import '../utilities/util_date.dart';
import '../utilities/util_string.dart';
import 'reuse_button.dart';
import 'reuse_card.dart';
import 'reuse_chip.dart';
import 'reuse_data_table.dart';
import 'reuse_empty_state.dart';

/// The Next Trade table's data columns (2026-09-10, per the user - shared
/// so any other place showing one of these rows, e.g. Controls' single-pair
/// Check result, renders the exact same table shape). Excludes the leading
/// checkbox/loading-indicator column - that only makes sense for the
/// multi-row, selectable Next Trade table itself.
const List<DataColumn> previewDataColumns = [
  DataColumn(label: Text('Pair')),
  DataColumn(label: Text('Interval')),
  DataColumn(label: Text('Initial investment')),
  DataColumn(label: Text('Actual investment')),
  DataColumn(label: Text('Extra margin')),
  DataColumn(label: Text('Direction')),
  DataColumn(label: Text('Leverage')),
  DataColumn(label: Text('Entry price')),
  DataColumn(label: Text('Price range')),
  DataColumn(label: Text('Take profit')),
  DataColumn(label: Text('Stop loss')),
  DataColumn(label: Text('Grids')),
  DataColumn(label: Text('40/60')),
  DataColumn(label: Text('Liquidation')),
];

/// A small inline spinner for a cell whose value is mid-refresh - same
/// visual language as [ReuseButton]'s own loading spinner (16x16,
/// strokeWidth 2), just without a button around it.
const Widget _pendingCellSpinner = SizedBox(
  width: 16,
  height: 16,
  child: CircularProgressIndicator(strokeWidth: 2),
);

/// The 11 "computed" cells (Actual investment through Liquidation) shared by
/// a Next Trade row and a Controls single-pair Check result - 11 dashes if
/// [entry] is null (no live signal for this category right now).
///
/// [pending] (2026-09-10, per the user): true while a check requested by
/// THIS row's own category/investment edit hasn't come back from Pionex
/// yet. Shows a spinner in Actual investment/Extra margin specifically -
/// the two fields a fresh Pionex probe actually recomputes - so the user
/// can tell "still loading" apart from "genuinely unavailable" (a plain
/// dash) or "this is the real, current number." The other 9 cells still
/// render from [entry] if one is already on hand (best-available data,
/// not blanked out just because the slow probe hasn't returned) - only
/// the two fields that are ACTUALLY mid-refresh show a spinner.
List<Widget> previewComputedCells(
  PreviewGridPair? entry, {
  bool pending = false,
}) {
  if (entry == null) {
    return [
      if (pending) _pendingCellSpinner else const Text('—'),
      if (pending) _pendingCellSpinner else const Text('—'),
      for (var i = 0; i < 9; i++) const Text('—'),
    ];
  }
  return [
    if (pending)
      _pendingCellSpinner
    else
      Text(
        entry.actualInvestment == null
            ? '—'
            : UtilString.usd(entry.actualInvestment!),
      ),
    if (pending)
      _pendingCellSpinner
    else
      Text(
        entry.extraMargin == null ? '—' : UtilString.usd(entry.extraMargin!),
      ),
    ReuseChip(
      label: entry.direction.wireValue.toUpperCase(),
      tone: entry.direction == GridDirection.long
          ? ReuseChipTone.success
          : ReuseChipTone.danger,
    ),
    Text('${entry.leverage.toStringAsFixed(0)}x'),
    Text(UtilString.price(entry.entryPrice)),
    Text('${UtilString.price(entry.bottom)}–${UtilString.price(entry.top)}'),
    Text(UtilString.price(entry.takeProfitPrice)),
    Text(UtilString.price(entry.stopLossPrice)),
    Text('${entry.gridCount}'),
    Text(entry.widenApplied ? '40/60' : 'Neutral'),
    Text(
      entry.liquidationPrice == null
          ? '—'
          : UtilString.price(entry.liquidationPrice!),
    ),
  ];
}

/// The "Report" checklist — the engine's per-cycle preview of every
/// currently-actionable pair (see `PreviewGridPair`). Thin `ReuseCard`
/// wrapper around [PreviewChecklist]. Shown on both the Dashboard and the
/// Controls screen — same data, same Start action, same widget.
class ReportSection extends StatelessWidget {
  const ReportSection({
    super.key,
    required this.report,
    required this.engineStatus,
    required this.freeBalance,
    required this.busy,
    required this.startLoading,
    required this.onStart,
    required this.categoryOf,
    required this.onCategoryChanged,
    required this.investmentOf,
    required this.onInvestmentChanged,
    required this.checkNowLoading,
    required this.onCheckNow,
    required this.canOpenNewGrid,
    required this.isCheckPending,
    required this.storedCheckupMarkerFor,
    this.blockedByBase = const {},
    this.market = const [],
    this.onVisibleSymbols,
    this.onShowMore,
  });

  /// See [PreviewChecklist.market], [PreviewChecklist.onVisibleSymbols] and
  /// [PreviewChecklist.onShowMore] - passed straight through.
  final List<MarketPair> market;
  final void Function(List<String> symbols)? onVisibleSymbols;
  final VoidCallback? onShowMore;

  final LastReport report;
  final EngineStatus engineStatus;
  final double freeBalance;
  final bool busy;

  /// Drives ONLY the Start-selected button's spinner (2026-09-15, per the
  /// user: "loading indicator of start button keep spinning while power
  /// toggle is off") - deliberately separate from [busy], which also goes
  /// true whenever the engine process isn't alive (used correctly to
  /// disable the button, but was ALSO wrongly driving its spinner, making
  /// it look like something was actively in progress when it was really
  /// just structurally blocked). True only while a genuine Start action
  /// is in flight.
  final bool startLoading;

  /// Colors the balance shown top right of this card (2026-09-09, per the
  /// user - the standalone Balance card is gone, shown here and opposite
  /// "Engine" on the Engine card instead). Same rule as StatusReport's own
  /// `canOpenNewGrid`: not paused AND free balance >= the new-pair minimum.
  final bool canOpenNewGrid;
  final Future<void> Function(List<String> bases) onStart;

  /// The full Red-list sweep's own busy/trigger (2026-09-09, per the user) -
  /// deliberately separate from [busy] (which gates the Start-selected
  /// button here). Null [onCheckNow] disables the button. Check now is the
  /// button "responsible for the red list check", so it lives here, top
  /// left of the Next Trade card, rather than under Power/Quick Actions.
  final bool checkNowLoading;
  final VoidCallback? onCheckNow;

  /// The category (1m/1H/1D) currently on file for a pair - backs each
  /// row's knob, initialized from `PairCategoryStore` (defaults to 1H).
  final AutoCategory Function(String symbol) categoryOf;

  /// Persists the user's knob choice immediately (not deferred to Start) -
  /// the running engine reads it fresh the next time this pair is actually
  /// checked/opened.
  final void Function(String symbol, AutoCategory category) onCategoryChanged;

  /// The initial investment (USDT) currently on file for a pair (2026-09-09)
  /// - defaults to $10, backs each row's editable field. Only ever used for
  /// that pair's very first real open - never overrides an already-
  /// recycling bot's P&L-adjusted amount.
  final double Function(String symbol) investmentOf;

  /// Persists the user's typed amount immediately (not deferred to Start).
  /// `category` is the row's own currently-displayed interval - needed so
  /// the caller can reprice the right (base, category) entry. `hasData` is
  /// false for a still-pending "-" row (2026-09-11, point 7) - the caller
  /// is expected to skip the Pionex pull entirely in that case.
  final void Function(
    String symbol,
    double amount,
    AutoCategory category,
    bool hasData,
  )
  onInvestmentChanged;

  /// True while a category/investment edit for this exact symbol has fired
  /// a check that hasn't come back from Pionex yet (2026-09-10, per the
  /// user) - drives the loading spinner in that row's Actual
  /// investment/Extra margin cells. Owned by the caller (which is the one
  /// that actually awaits `requestPairAction`), not this widget.
  final bool Function(String symbol) isCheckPending;

  /// The rotating cycle-marker index a base was last actually checked
  /// under by the Checkup track, if ever this session (2026-09-12, per the
  /// user) - null means "not checked yet." Compared here against
  /// [engineStatus]'s own current index to decide whether a row shows a
  /// marker at all.
  final int? Function(String base) storedCheckupMarkerFor;

  /// See [PreviewChecklist.blockedByBase] - passed straight through.
  final Map<String, Set<AutoCategory>> blockedByBase;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final textTheme = Theme.of(context).textTheme;
    return ReuseCard(
      // 1H is the only timeframe, so the title shows just the count.
      title: 'Next Trade: ${report.entries.length}',
      // Per the user (2026-09-09): the standalone Balance card is gone -
      // shown here, inline on the same row as this card's own title (same
      // text size as the Engine card's copy of it), and again opposite
      // "Engine" on the Engine card.
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Free balance: ', style: textTheme.titleMedium),
          Text(
            UtilString.usd(freeBalance),
            style: textTheme.titleMedium?.copyWith(
              color: canOpenNewGrid
                  ? context.tradingColors.profit
                  : context.tradingColors.warning,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Per the user (2026-09-09): this is the ONLY text under
                // the balance now - no separate "last run"/countdown lines.
                Text(
                  engineStatus.updatedAtMs == 0
                      ? l10n.engineNeverStarted
                      : 'Last updated: ${UtilDate.dateTime(engineStatus.updatedAt)}',
                  style: textTheme.labelSmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: CoreSpacing.sm),
          ReuseButton(
            // Per the user (2026-09-12): "a symbol appears inside check now
            // button and this symbol is next to pair name after check in
            // next trade table... helps user to know if all pairs updated
            // according to last check now or not" - the CURRENT cycle
            // marker, same convention as the auto-category toggles.
            // No ✓ round marker here or on the rows (per the user,
            // 2026-11-07: the app must not put check marks on Next Trade).
            label: 'Check now',
            icon: Icons.bolt,
            tone: ReuseButtonTone.neutral,
            loading: checkNowLoading,
            onPressed: onCheckNow,
          ),
          const SizedBox(height: CoreSpacing.sm),
          PreviewChecklist(
            entries: report.entries,
            unlisted: report.unlisted,
            pending: report.pending,
            freeBalance: freeBalance,
            busy: busy,
            startLoading: startLoading,
            checkupCurrentBase: engineStatus.checkupCurrentBase,
            // Per the user (2026-09-09): replaces the old "N pair(s) with a
            // signal right now..." line entirely - that spot now shows the
            // Check now sweep's own live status instead, blank when idle.
            checkNowStatus: checkNowLoading
                ? '${engineStatus.lastCycleMessage} '
                      '(${engineStatus.checkupPairIndex}/${engineStatus.checkupPairTotal})'
                : '',
            onStart: onStart,
            categoryOf: categoryOf,
            onCategoryChanged: onCategoryChanged,
            investmentOf: investmentOf,
            onInvestmentChanged: onInvestmentChanged,
            isCheckPending: isCheckPending,
            blockedByBase: blockedByBase,
            market: market,
            onVisibleSymbols: onVisibleSymbols,
            onShowMore: onShowMore,
          ),
        ],
      ),
    );
  }
}

/// The Report table body: one row per actionable pair (direction/entry/
/// grids/leverage/investment), a native checkbox column, a "select all",
/// and a Start button. Kept as its own StatefulWidget so checkbox
/// selections survive a parent rebuild (e.g. the 5s status poll) —
/// re-deriving from `entries` on every poll would otherwise wipe the user's
/// picks out from under them.
class PreviewChecklist extends StatefulWidget {
  const PreviewChecklist({
    super.key,
    required this.entries,
    this.unlisted = const [],
    this.pending = const [],
    required this.freeBalance,
    required this.busy,
    required this.startLoading,
    this.checkupCurrentBase = '',
    this.checkNowStatus = '',
    required this.onStart,
    required this.categoryOf,
    required this.onCategoryChanged,
    required this.investmentOf,
    required this.onInvestmentChanged,
    required this.isCheckPending,
    this.cycleMarkerFor,
    this.blockedByBase = const {},
    this.market = const [],
    this.onVisibleSymbols,
    this.onShowMore,
  });

  final List<PreviewGridPair> entries;

  /// Every Pionex perpetual (2026-11-07, per the user): when non-empty the
  /// table lists all of them in the chosen sort, 100 at a time, with each
  /// pair's signal data merged in from [entries].
  final List<MarketPair> market;

  /// Reports the tradable pairs currently shown, in order - what Check Now
  /// reads.
  final void Function(List<String> symbols)? onVisibleSymbols;

  /// "Show more" was pressed; [onVisibleSymbols] already has the longer list.
  final VoidCallback? onShowMore;

  /// Red List pairs Pionex doesn't offer as futures - tagged, not
  /// selectable, no computed values (see [UnlistedRedListPair]).
  final List<UnlistedRedListPair> unlisted;

  /// Red List bases Check Now has reconciled in but not yet reached - see
  /// [PendingRedListPair]. Shown as a "-" row, same as a base with no live
  /// signal, just for every category at once.
  final List<PendingRedListPair> pending;
  final double freeBalance;
  final bool busy;

  /// See [ReportSection.startLoading]'s doc - same purpose, threaded down
  /// to where the actual button lives.
  final bool startLoading;

  /// The base Checkup is reading right now, if any - that one row shows a
  /// loading indicator instead of its checkbox while this matches.
  final String checkupCurrentBase;

  /// The Check now sweep's own live status line (2026-09-09, per the user)
  /// - shown where the old "N pair(s) with a signal right now..." summary
  /// used to be. Blank while no sweep is running.
  final String checkNowStatus;
  final Future<void> Function(List<String> bases) onStart;
  final AutoCategory Function(String symbol) categoryOf;
  final void Function(String symbol, AutoCategory category) onCategoryChanged;
  final double Function(String symbol) investmentOf;
  final void Function(
    String symbol,
    double amount,
    AutoCategory category,
    bool hasData,
  )
  onInvestmentChanged;
  final bool Function(String symbol) isCheckPending;

  /// The rotating cycle-marker text to show next to a row's pair name, if
  /// any (2026-09-12, per the user - see [ReportSection]'s doc for the
  /// full feature). Null/empty shows nothing.
  final String? Function(String base)? cycleMarkerFor;

  /// base -> categories that already have a running auto bot for that exact
  /// base right now (2026-09-11, per the user) - a pair can only have one
  /// running auto bot per interval, so those segments show yellow/blocked
  /// on the knob rather than letting the user pick a duplicate.
  final Map<String, Set<AutoCategory>> blockedByBase;

  @override
  State<PreviewChecklist> createState() => _PreviewChecklistState();
}

class _PreviewChecklistState extends State<PreviewChecklist> {
  final Set<String> _selected = {};

  /// The table's sort (cycled by the sort icon) and how many rows it shows.
  MarketSort _sort = MarketSort.gainers;
  int _visibleCount = marketPageSize;

  /// The market in the current sort, and the rows of it on screen.
  List<MarketPair> get _sortedMarket => sortMarket(widget.market, _sort);

  /// Immediate local echo of a knob change (keyed by base) - the store
  /// write happens right away via [PreviewChecklist.onCategoryChanged], but
  /// the row shouldn't flicker back to the old value until the next poll
  /// picks the write back up from disk.
  final Map<String, AutoCategory> _categoryOverride = {};

  /// One text-editing controller per row (keyed by base), created once and
  /// reused across rebuilds - the 5s status poll must never fight the user
  /// mid-keystroke by resetting the field's text out from under them.
  final Map<String, TextEditingController> _investmentControllers = {};

  /// One FocusNode per row (2026-09-20, per the user - live incident: typed
  /// $20 into several pairs' investment fields, clicked Start, the engine
  /// used the OLD $5 default for most of them). Root cause: the field only
  /// committed via `onSubmitted` (Enter) or `onTapOutside` (a mouse click
  /// elsewhere) - neither fires when moving between fields with Tab, the
  /// natural way to fill in several rows in a row. Only the single
  /// last-focused field before an actual mouse click ever got saved; every
  /// value typed into a field the user merely Tabbed away from silently
  /// reverted to whatever was on disk before. A focus-loss listener commits
  /// on ANY way of leaving the field - Tab, click-away, or Start itself
  /// stealing focus - not just the two pointer/Enter-specific paths above.
  final Map<String, FocusNode> _investmentFocusNodes = {};

  TextEditingController _investmentControllerFor(_RowView row) =>
      _investmentControllers.putIfAbsent(
        row.base,
        () => TextEditingController(
          text: _formatInvestment(widget.investmentOf(row.symbol)),
        ),
      );

  FocusNode _investmentFocusNodeFor(_RowView row) =>
      _investmentFocusNodes.putIfAbsent(row.base, () {
        final node = FocusNode();
        // Re-derives the row fresh at the moment focus is lost, rather than
        // closing over the `row` passed in when the node was first created
        // (which `putIfAbsent` would otherwise pin to a single, possibly
        // stale, snapshot for this node's entire lifetime) - so a category
        // switch on this same row between typing and tabbing away still
        // commits against the right category.
        node.addListener(() {
          if (node.hasFocus) return;
          final current = _buildRows().firstWhere(
            (r) => r.base == row.base,
            orElse: () => row,
          );
          _commitInvestment(current);
        });
        return node;
      });

  String _formatInvestment(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  /// Parses and persists a row's typed investment amount - invalid input
  /// (empty, non-numeric, zero, negative) is silently reverted to the last
  /// known-good value rather than sent anywhere; per the user (2026-09-09)
  /// no ceiling/floor is enforced beyond "must be a positive number".
  void _commitInvestment(_RowView row) {
    final controller = _investmentControllers[row.base];
    if (controller == null) return;
    final parsed = double.tryParse(controller.text.trim());
    if (parsed == null || parsed <= 0) {
      controller.text = _formatInvestment(widget.investmentOf(row.symbol));
      return;
    }
    // Per the user (2026-09-10): re-submitting the SAME number (tap into
    // the field, tap back out with nothing changed) must not pull fresh
    // Pionex data again - only an actual value change does.
    if (parsed == widget.investmentOf(row.symbol)) return;
    // Per the user (2026-09-11, point 7): a row with no data yet pulled
    // (still showing "-") has nothing to reprice - the value still gets
    // saved (it'll be used whenever Check Now eventually reaches this
    // pair), but no Pionex pull, no loading indicator.
    widget.onInvestmentChanged(
      row.symbol,
      parsed,
      row.category,
      row.entry != null,
    );
  }

  @override
  void dispose() {
    for (final c in _investmentControllers.values) {
      c.dispose();
    }
    for (final n in _investmentFocusNodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  /// One row per base - the UNION of every base with a signal under ANY of
  /// the 3 categories (2026-09-08, per the user), since Check Now now
  /// computes all 3 up front. The row shows whichever category's own data
  /// the knob currently has selected; [_RowView.entry] is null when that
  /// specific category has no live signal for this base right now (the
  /// other 2 might still have one).
  List<_RowView> _buildRows() {
    final byBase = <String, Map<AutoCategory, PreviewGridPair>>{};
    for (final e in widget.entries) {
      byBase.putIfAbsent(e.base, () => {})[e.category] = e;
    }
    if (widget.market.isNotEmpty) return _buildMarketRows(byBase);
    final rows = [
      for (final base in byBase.keys.toList()..sort())
        _rowViewFor(base, byBase[base]!),
    ];
    // Per the user (2026-09-11): a red-list base Check Now has reconciled
    // in but not yet reached shows as a "-" row immediately, rather than
    // being invisible until the sweep actually gets to it. Every data cell
    // renders exactly like the existing "no live signal" case (entry:
    // null) - no new rendering path needed, this base just has ALL 3
    // categories unavailable instead of some.
    for (final p in widget.pending) {
      if (byBase.containsKey(p.base)) continue;
      final category = _categoryOverride[p.base] ?? widget.categoryOf(p.symbol);
      rows.add(
        _RowView(
          base: p.base,
          symbol: p.symbol,
          pairKey: '${p.base.toUpperCase()}/USDT',
          category: category,
          entry: null,
          unavailable: allAutoCategories.toSet(),
          blocked: widget.blockedByBase[p.base] ?? const {},
        ),
      );
    }
    rows.sort((a, b) => a.base.compareTo(b.base));
    return rows;
  }

  /// The table's rows when the Pionex market is loaded: the first
  /// [_visibleCount] pairs in the current sort, each with its signal data (if
  /// Check Now has read it), then any read pair the market doesn't list.
  List<_RowView> _buildMarketRows(
    Map<String, Map<AutoCategory, PreviewGridPair>> byBase,
  ) {
    final entryBaseByUpper = {for (final b in byBase.keys) b.toUpperCase(): b};
    final rows = <_RowView>[];
    final shown = <String>{};
    for (final m in _sortedMarket.take(_visibleCount)) {
      final entryBase = m.category.tradable
          ? entryBaseByUpper[m.base.toUpperCase()]
          : null;
      if (entryBase != null) {
        shown.add(entryBase);
        rows.add(_rowViewFor(entryBase, byBase[entryBase]!, market: m));
        continue;
      }
      final key = m.category.tradable ? m.base : m.displayPair;
      final symbol = m.appSymbol ?? '';
      rows.add(
        _RowView(
          base: key,
          symbol: symbol,
          pairKey: m.displayPair,
          category: _categoryOverride[key] ??
              (symbol.isEmpty ? AutoCategory.oneHour : widget.categoryOf(symbol)),
          entry: null,
          unavailable: allAutoCategories.toSet(),
          blocked: widget.blockedByBase[key] ?? const {},
          market: m,
        ),
      );
    }
    for (final base in byBase.keys) {
      if (!shown.contains(base) &&
          !widget.market.any((m) => m.base.toUpperCase() == base.toUpperCase())) {
        rows.add(_rowViewFor(base, byBase[base]!));
      }
    }
    return rows;
  }

  /// The icon for each sort, so the button shows which one is active.
  Widget _sortIcon(MarketSort sort) => switch (sort) {
    MarketSort.gainers => const Icon(Icons.trending_up, size: 18),
    MarketSort.losers => const Icon(Icons.trending_down, size: 18),
    MarketSort.category => const Icon(Icons.category_outlined, size: 18),
    MarketSort.volume => const Icon(Icons.bar_chart, size: 18),
    // Per the user: A–Z is a downward arrow, Z–A an upward arrow.
    MarketSort.aToZ => const Icon(Icons.arrow_downward, size: 18),
    MarketSort.zToA => const Icon(Icons.arrow_upward, size: 18),
  };

  /// The 24h move, green up / red down, like Pionex shows it.
  Widget _changeCell(BuildContext context, MarketPair? m) {
    if (m == null) return const Text('—');
    final pct = m.changePct;
    return Text(
      '${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(2)}%',
      style: TextStyle(
        color: pct >= 0
            ? context.tradingColors.profit
            : context.tradingColors.loss,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  /// The tradable pairs on screen, in order - what Check Now reads.
  List<String> _visibleTradableSymbols() => [
    for (final m in _sortedMarket.take(_visibleCount))
      if (m.appSymbol != null) m.appSymbol!,
  ];

  _RowView _rowViewFor(
    String base,
    Map<AutoCategory, PreviewGridPair> variants, {
    MarketPair? market,
  }) {
    final any = variants.values.first;
    final category = _categoryOverride[base] ?? widget.categoryOf(any.symbol);
    return _RowView(
      base: base,
      symbol: any.symbol,
      pairKey: any.pairKey,
      category: category,
      entry: variants[category],
      unavailable: {
        for (final c in allAutoCategories)
          if (!variants.containsKey(c)) c,
      },
      blocked: widget.blockedByBase[base] ?? const {},
      market: market,
    );
  }

  /// Sums each selected pair's OWN configured initial investment (the same
  /// per-pair text field/default this widget already reads via
  /// `widget.investmentOf`) — not a flat per-pair assumption. Bug fixed
  /// 2026-09-10: this used to be `freeBalance ~/ 10`, a hardcoded $10-per-
  /// pair floor left over from before custom per-pair investment existed.
  /// The engine's own real Start path (`_pairActionStart`) never enforced
  /// that floor either — it calls `_manageGridPair` with
  /// `fundsRestricted: false` and just uses `pairInvestments.investmentOf`
  /// directly, so this GUI pre-check's comment claiming to "mirror the
  /// engine" was simply wrong. The old flat floor meant selecting 4 pairs
  /// at $5 each (a real $20 total) demanded $40 free and rejected a user
  /// who had, say, $25 free with "not enough balance" even though $25 was
  /// plenty.
  double _totalInvestmentFor(Iterable<_RowView> selectedRows) => selectedRows
      .fold(0.0, (sum, r) => sum + widget.investmentOf(r.symbol));

  @override
  void didUpdateWidget(covariant PreviewChecklist oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A pair that dropped out of the latest report (signal gone under every
    // category, now running, retired, etc.) can't stay selected. Balance is
    // deliberately NOT a reason to drop a selection here - checkboxes stay
    // exactly as the user left them regardless of balance moving; Start is
    // the only place balance gets enforced.
    final currentBases = {
      ...widget.entries.map((e) => e.base),
      ...widget.pending.map((p) => p.base),
      // Market rows shown without a signal yet keep their fields too.
      for (final m in _sortedMarket.take(_visibleCount))
        m.category.tradable ? m.base : m.displayPair,
    };
    _selected.removeWhere((b) => !currentBases.contains(b));
    // Dispose and drop controllers for bases that dropped out of the
    // report entirely - a base that's still present (even under a
    // different category than before) keeps its controller/text as-is.
    final staleBases = _investmentControllers.keys
        .where((b) => !currentBases.contains(b))
        .toList();
    for (final b in staleBases) {
      _investmentControllers.remove(b)?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _buildRows();
    final textTheme = Theme.of(context).textTheme;
    final hasMarket = widget.market.isNotEmpty;
    if (hasMarket) widget.onVisibleSymbols?.call(_visibleTradableSymbols());
    final marketTotal = widget.market.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (rows.isEmpty && widget.unlisted.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: CoreSpacing.sm),
            child: ReuseEmptyState(
              message:
                  'No actionable pairs right now — a pair shows up here once it has a live buy/sell signal.',
              icon: Icons.fact_check_outlined,
            ),
          ),
        if (rows.isNotEmpty) ...[
          Text(
            widget.checkNowStatus,
            style: textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
          const Divider(height: CoreSpacing.lg),
          ReuseDataTable(
            // Per the user (2026-09-06): the native leading checkbox can't
            // conditionally become a loading indicator per row, so it's
            // replaced with a manual leading column that does exactly that.
            showCheckboxColumn: false,
            // Per the user (2026-09-07): same columns as the Auto/Manual
            // bots tables wherever a preview actually has that data - Bot
            // ID, Status, P&L, and Duration are dropped since nothing has
            // been opened yet, so none of those exist for a candidate.
            // Per the user (2026-09-09): checkbox/loading, pair, interval,
            // initial investment (the editable field - the old read-only
            // computed "Initial investment" column is gone, this one now
            // covers that name), actual investment, extra margin, then
            // everything else in its previous order.
            columns: [
              // Per the user (2026-09-11): shows how many pairs the table
              // currently holds, right in the checkbox column's own header
              // cell - "16 pairs" for 16 rows, "1 pair" for exactly one.
              DataColumn(
                label: hasMarket
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${rows.length < marketTotal ? rows.length : marketTotal} of $marketTotal',
                          ),
                          // Cycles gainers -> losers -> category -> volume;
                          // the icon shows the current sort.
                          IconButton(
                            tooltip: '${_sort.label} - click for '
                                '${_sort.next.label.toLowerCase()}',
                            icon: _sortIcon(_sort),
                            visualDensity: VisualDensity.compact,
                            onPressed: () => setState(() {
                              _sort = _sort.next;
                              _visibleCount = marketPageSize;
                            }),
                          ),
                        ],
                      )
                    : Text('${rows.length} pair${rows.length == 1 ? '' : 's'}'),
              ),
              // Per the user (2026-11-07): only these columns. The full
              // preview (investment, direction, range, TP/SL...) opens by
              // tapping the pair.
              previewDataColumns[0], // Pair
              const DataColumn(label: Text('24h %')),
              const DataColumn(label: Text('Category')),
              // No Interval column: 1H is the only timeframe (per the user).
              previewDataColumns[2], // Initial investment
            ],
            rows: [
              for (final row in rows)
                DataRow(
                  // Every cell gets its own `onTap` (-> details screen), not
                  // just the Pair cell - a DataCell with no onTap of its own
                  // falls back to the row's onSelectChanged, which would
                  // make clicking anywhere on the row also toggle the
                  // checkbox. Only the manual leading checkbox cell (below)
                  // should ever select a pair.
                  cells: [
                    DataCell(
                      // Both branches centered in the same fixed-size box
                      // (2026-09-09, per the user) so swapping between the
                      // checkbox and the loading indicator never shifts
                      // anything vertically - Checkbox's own tap-target
                      // padding otherwise sits the indicator's plain 18x18
                      // box higher than the checkbox's visual square.
                      SizedBox(
                        width: 48,
                        height: 48,
                        child: Center(
                          child:
                              widget.checkupCurrentBase.isNotEmpty &&
                                  row.base.toUpperCase() ==
                                      widget.checkupCurrentBase.toUpperCase()
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Checkbox(
                                  value:
                                      _selected.contains(row.base) &&
                                      row.entry != null &&
                                      !row.blocked.contains(row.category),
                                  // Always selectable regardless of balance
                                  // - never disabled for that reason.
                                  // Balance is only enforced once Start is
                                  // actually pressed (below). Disabled when
                                  // the currently-displayed category has no
                                  // live signal for this pair - nothing to
                                  // start. Bug fixed 2026-09-11: also used
                                  // to disable while ANY action was
                                  // in-flight anywhere on the screen
                                  // (`widget.busy`) - selecting a row is
                                  // harmless and fires nothing, so it never
                                  // needed to wait out an unrelated,
                                  // possibly minutes-long Start. Bug fixed
                                  // 2026-09-11 (same day, follow-up): the
                                  // knob already shows yellow/"blocked" when
                                  // this exact base+category already has a
                                  // running bot or is waiting to open, but
                                  // the checkbox itself stayed selectable
                                  // regardless - per the user, "user can't
                                  // select them in this interval, same as
                                  // if they are already started." Disabled
                                  // (and forced unchecked) the same as the
                                  // no-signal case now.
                                  onChanged:
                                      (row.entry == null ||
                                          row.blocked.contains(row.category))
                                      ? null
                                      : (v) => setState(
                                          () => v == true
                                              ? _selected.add(row.base)
                                              : _selected.remove(row.base),
                                        ),
                                ),
                        ),
                      ),
                    ),
                    DataCell(
                      Builder(
                        builder: (context) {
                          final marker = widget.cycleMarkerFor?.call(
                            row.base,
                          );
                          if (marker == null || marker.isEmpty) {
                            return Text(row.pairKey);
                          }
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(row.pairKey),
                              const SizedBox(width: 4),
                              Text(
                                marker,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                      onTap: row.entry == null
                          ? null
                          : () =>
                                context.push('/pair-preview', extra: row.entry),
                    ),
                    DataCell(_changeCell(context, row.market)),
                    DataCell(
                      Text(
                        row.market == null
                            ? '—'
                            : row.tradable
                            ? row.market!.category.label
                            : '${row.market!.category.label} (not tradable by the bots)',
                        style: textTheme.bodySmall,
                      ),
                    ),
                    DataCell(
                      SizedBox(
                        width: 76,
                        child: TextField(
                          controller: _investmentControllerFor(row),
                          focusNode: _investmentFocusNodeFor(row),
                          enabled: !widget.busy && row.tradable,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          style: const TextStyle(fontSize: 13),
                          decoration: const InputDecoration(
                            prefixText: r'$',
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 6,
                            ),
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => _commitInvestment(row),
                          onTapOutside: (_) => _commitInvestment(row),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          if (hasMarket && _visibleCount < marketTotal) ...[
            const SizedBox(height: CoreSpacing.sm),
            Center(
              child: ReuseButton(
                label:
                    'Show more (${(marketTotal - _visibleCount).clamp(0, marketPageSize)} more)',
                icon: Icons.expand_more,
                tone: ReuseButtonTone.neutral,
                onPressed: () {
                  setState(() => _visibleCount += marketPageSize);
                  widget.onVisibleSymbols?.call(_visibleTradableSymbols());
                  widget.onShowMore?.call();
                },
              ),
            ),
          ],
          const SizedBox(height: CoreSpacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: ReuseButton(
              label: 'Start selected (${_selected.length})',
              icon: Icons.rocket_launch_outlined,
              loading: widget.startLoading,
              onPressed: (widget.busy || _selected.isEmpty)
                  ? null
                  : () {
                      // Re-check against the LIVE free balance at the
                      // moment Start is actually pressed, not the balance
                      // this selection was made against - it can shift
                      // between polls (other grids trading, fees). Only
                      // rows with a live signal (`entry != null`) actually
                      // get sent below, so only those count toward the
                      // amount needed - a signal-less selected pair (see
                      // the dropped-pair notice below) shouldn't be able to
                      // block Start for the ones that ARE going through.
                      // Per the user (2026-09-11): a row blocked (yellow -
                      // already running or already waiting to open in this
                      // exact interval) can no longer even be checked, but
                      // treat it here the same way too in case it became
                      // blocked AFTER being selected (a live poll updated
                      // mid-selection) - it's excluded from this Start
                      // press entirely, same as a signal-less row already
                      // is below.
                      final selectedRowsAll = rows.where(
                        (r) =>
                            _selected.contains(r.base) &&
                            !r.blocked.contains(r.category),
                      );
                      final totalNeeded = _totalInvestmentFor(
                        selectedRowsAll.where((r) => r.entry != null),
                      );
                      if (totalNeeded > widget.freeBalance) {
                        setState(_selected.clear);
                        ScaffoldMessenger.of(context)
                          ..hideCurrentSnackBar()
                          ..showSnackBar(
                            SnackBar(
                              content: Text(
                                'Not enough free balance to start — your '
                                'selected pairs need '
                                '${UtilString.usd(totalNeeded)} total (you '
                                'have ${UtilString.usd(widget.freeBalance)} '
                                'free). Selection cleared.',
                              ),
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.error,
                            ),
                          );
                        return;
                      }
                      // Per the user (2026-09-05): pass the EXACT symbol
                      // string the engine itself read from the Red List
                      // (e.g. "BINANCE:ETHUSDT") - reconstructing it from
                      // the bare base ("ETH" + "USDT" + a guessed exchange
                      // prefix) is exactly the kind of text manipulation
                      // that broke chart lookups, since it can't be
                      // trusted to match what TradingView actually listed
                      // it as.
                      final selectedSymbols = selectedRowsAll
                          .where((r) => r.entry != null)
                          .map((r) => r.symbol)
                          .toList();
                      // Bug fixed 2026-09-10: a selected pair with no live
                      // signal for its currently-displayed category (
                      // `r.entry == null`) used to be dropped from the
                      // Start request with zero feedback - looked exactly
                      // like "I selected 6, only 5 got created" with no way
                      // to tell why the 6th never even reached the engine.
                      final droppedBases = selectedRowsAll
                          .where((r) => r.entry == null)
                          .map((r) => r.base)
                          .toList();
                      if (droppedBases.isNotEmpty) {
                        ScaffoldMessenger.of(context)
                          ..hideCurrentSnackBar()
                          ..showSnackBar(
                            SnackBar(
                              content: Text(
                                '${droppedBases.join(', ')} - no live signal '
                                'on the currently-shown interval, so '
                                '${droppedBases.length == 1 ? 'it was' : 'they were'} '
                                'left out of this Start. Switch to a category '
                                'with a signal and try again if you meant to '
                                'include ${droppedBases.length == 1 ? 'it' : 'them'}.',
                              ),
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.error,
                            ),
                          );
                      }
                      if (selectedSymbols.isEmpty) return;
                      // Bug fixed 2026-09-11, per the user ("I select 1 now
                      // but it shows 6"): unlike a row that disappears after
                      // an action (Stop, Convert), a started pair stays
                      // right here in the Next Trade table - didUpdateWidget's
                      // cleanup (which only drops a selection when its base
                      // is no longer in the table at all) never fires for
                      // it, so the checkbox and the "Start selected (N)"
                      // count just kept accumulating every pair ever
                      // started, across every press, forever. Clear
                      // explicitly on click, same fix as GridsTable's
                      // "Last selected" button got earlier today.
                      setState(_selected.clear);
                      widget.onStart(selectedSymbols);
                    },
            ),
          ),
        ],
        if (widget.unlisted.isNotEmpty) ...[
          if (rows.isNotEmpty) const SizedBox(height: CoreSpacing.sm),
          // Per the user (2026-09-06): plain text, no checkbox, no computed
          // values - these pairs are on the Red List but Pionex doesn't
          // offer them as futures, so nothing about them was ever read.
          for (final u in widget.unlisted)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '${u.symbol} — ${UnlistedRedListPair.message}',
                style: textTheme.bodySmall,
              ),
            ),
        ],
      ],
    );
  }
}

/// One Next Trade row's resolved view: which base/pair it is, which
/// category is currently selected for it, and that category's own preview
/// data - null when this base has no live signal under that specific
/// category right now (2026-09-08, per the user: row stays, shows dashes).
class _RowView {
  const _RowView({
    required this.base,
    required this.symbol,
    required this.pairKey,
    required this.category,
    required this.entry,
    required this.unavailable,
    required this.blocked,
    this.market,
  });

  /// The pair's Pionex market data (24h move, category), when known.
  final MarketPair? market;

  /// False for COIN-M / coin futures rows: shown, but the USDT-margined grid
  /// bots can't trade them, so nothing on the row can be selected.
  bool get tradable => market?.category.tradable ?? true;

  final String base;
  final String symbol;
  final String pairKey;
  final AutoCategory category;
  final PreviewGridPair? entry;

  /// Categories with no live signal for this base right now - drives the
  /// knob's red-tinted segments (2026-09-09, per the user).
  final Set<AutoCategory> unavailable;

  /// Categories that already have a running auto bot for this exact base
  /// (2026-09-11, per the user) - drives the knob's yellow-tinted segments.
  final Set<AutoCategory> blocked;
}
