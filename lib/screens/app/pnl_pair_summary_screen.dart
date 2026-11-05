import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/core_layout.dart';
import '../../core/core_spacing.dart';
import '../../core/core_theme.dart';
import '../../data/models/auto_category.dart';
import '../../data/providers/app_providers.dart';
import '../../widgets/reuse_card.dart';
import '../../widgets/reuse_data_table.dart';
import '../../widgets/reuse_empty_state.dart';

enum _SortColumn { pair, trades, net }

/// Per-pair, per-category breakdown of every closed auto bot since the
/// last reset - reached by tapping the "Summary" link inside
/// [PnlSummaryView] on the Auto bots card (2026-09-13, per the user: "add
/// summary for each pair ... xrp: 3m / 2 T / 20$ where T refers to
/// trades"). One row per base+category pair that had at least one closed
/// trade in the current reset window, sourced from
/// `EngineControlRepository.pnlByPairSummary()`.
///
/// Built on [ReuseDataTable] - the same table widget behind the Next
/// Trade and Auto bots tables - per the user's explicit request ("same
/// as auto table and next trade table ... same design") rather than a
/// bespoke layout, so sorting/hover/scroll all look and behave
/// identically to every other table in the app.
///
/// Sortable by tapping any column header: Pair defaults to A-Z, then
/// Z-A on a second tap; Trades and P&L both default to high-to-low, then
/// low-to-high/negative-to-positive on a second tap - a second tap on
/// the SAME column flips it, tapping a DIFFERENT column switches to its
/// own default direction.
///
/// Filterable by category via the three checkboxes above the table -
/// each toggles independently (2026-09-13, per the user, confirmed with
/// their own example: "3m checked = show 3m, 1H & 1D checked show 1H
/// and 1D but not 3m because 3m is not checked") - never a cascading
/// "checking a longer interval implies the shorter ones too" behavior.
class PnlPairSummaryScreen extends ConsumerStatefulWidget {
  const PnlPairSummaryScreen({super.key});

  @override
  ConsumerState<PnlPairSummaryScreen> createState() =>
      _PnlPairSummaryScreenState();
}

class _PnlPairSummaryScreenState extends ConsumerState<PnlPairSummaryScreen> {
  _SortColumn _sortColumn = _SortColumn.pair;
  bool _ascending = true;

  final Set<AutoCategory> _visibleCategories = {...AutoCategory.values};

  static const _defaultAscending = {
    _SortColumn.pair: true,
    _SortColumn.trades: false,
    _SortColumn.net: false,
  };

  static const _columnIndex = {
    _SortColumn.pair: 0,
    _SortColumn.trades: 1,
    _SortColumn.net: 2,
  };

  void _onSort(_SortColumn column) {
    setState(() {
      if (_sortColumn == column) {
        _ascending = !_ascending;
      } else {
        _sortColumn = column;
        _ascending = _defaultAscending[column]!;
      }
    });
  }

  int _compare(
    ({String base, AutoCategory category, int trades, double net}) a,
    ({String base, AutoCategory category, int trades, double net}) b,
  ) {
    final cmp = switch (_sortColumn) {
      _SortColumn.pair => a.base == b.base
          ? a.category.wireValue.compareTo(b.category.wireValue)
          : a.base.compareTo(b.base),
      _SortColumn.trades => a.trades.compareTo(b.trades),
      _SortColumn.net => a.net.compareTo(b.net),
    };
    return _ascending ? cmp : -cmp;
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(controlRepositoryProvider);
    // Bug fixed 2026-09-14, per the user ("why summary screen is not
    // updates according to auto sum?"): unlike the Auto card (which
    // rebuilds on every statusReportProvider tick) and the History screen
    // (which watches botHistoryProvider), this screen never subscribed to
    // any polling stream - it computed pnlByPairSummary() once at build
    // time and never again unless something else forced a rebuild
    // (sorting, filtering, leaving and re-entering). The underlying data
    // was never stale (repo.history() always reads bot-history.jsonl
    // fresh) - only this screen's own rebuild trigger was missing.
    // Watching the same botHistoryProvider the History screen already
    // uses (ignoring its value, just using it as a 5-second tick) fixes
    // it the same way, with no new polling mechanism to maintain.
    ref.watch(botHistoryProvider);
    final allRows = repo.pnlByPairSummary();
    final rows =
        allRows.where((r) => _visibleCategories.contains(r.category)).toList()
          ..sort(_compare);
    final trading = context.tradingColors;

    return Scaffold(
      appBar: AppBar(title: const Text('P&L summary by pair')),
      body: LayoutBuilder(
        builder: (context, constraints) => allRows.isEmpty
            ? const ReuseEmptyState(
                message: 'No closed trades since the last reset.',
              )
            : ListView(
                padding: CoreLayout.edgeMargin(constraints),
                children: [
                  ReuseCard(
                    child: Wrap(
                      spacing: CoreSpacing.md,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          'Show:',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        for (final category in AutoCategory.values)
                          FilterChip(
                            label: Text(category.label),
                            selected: _visibleCategories.contains(category),
                            onSelected: (selected) => setState(() {
                              if (selected) {
                                _visibleCategories.add(category);
                              } else {
                                _visibleCategories.remove(category);
                              }
                            }),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: CoreSpacing.sm),
                  ReuseDataTable(
                    emptyMessage: 'No trades match the selected interval(s).',
                    sortColumnIndex: _columnIndex[_sortColumn],
                    sortAscending: _ascending,
                    columns: [
                      DataColumn(
                        label: const Text('Pair'),
                        onSort: (_, _) => _onSort(_SortColumn.pair),
                      ),
                      DataColumn(
                        label: const Text('T'),
                        numeric: true,
                        onSort: (_, _) => _onSort(_SortColumn.trades),
                      ),
                      DataColumn(
                        label: const Text(r'$'),
                        numeric: true,
                        onSort: (_, _) => _onSort(_SortColumn.net),
                      ),
                    ],
                    rows: [
                      for (final row in rows)
                        DataRow(
                          // No-op - a DataRow only gets the native
                          // hover/press highlight once it's selectable;
                          // showCheckboxColumn stays false so no checkbox
                          // actually appears (2026-09-13, per the user:
                          // "add hover effect to each row so user can
                          // monitor easily").
                          onSelectChanged: (_) {},
                          cells: [
                            DataCell(
                              Text('${row.base}: ${row.category.label}'),
                            ),
                            DataCell(Text('${row.trades}')),
                            DataCell(
                              Text(
                                '${row.net >= 0 ? '+' : ''}${row.net.toStringAsFixed(2)}',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: row.net >= 0
                                      ? trading.profit
                                      : trading.loss,
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}
