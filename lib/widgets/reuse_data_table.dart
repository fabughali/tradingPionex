import 'package:flutter/material.dart';

import 'reuse_empty_state.dart';

/// A horizontally-scrollable data table with a consistent empty state — the
/// base building block behind the grids table.
class ReuseDataTable extends StatelessWidget {
  const ReuseDataTable({
    super.key,
    required this.columns,
    required this.rows,
    this.emptyMessage = 'Nothing to show yet.',
    this.showCheckboxColumn = false,
    this.onSelectAll,
    this.sortColumnIndex,
    this.sortAscending = true,
  });

  final List<DataColumn> columns;
  final List<DataRow> rows;
  final String emptyMessage;

  /// Which [columns] entry currently owns the sort-arrow indicator, and
  /// which direction it points - pass straight through to each column's
  /// own `DataColumn.onSort` callback for a native, sortable table
  /// (2026-09-13, per the user - the P&L summary screen's columns should
  /// look and behave "same as auto table and next trade table"). Null
  /// (the default) draws no arrow at all, unchanged for every table that
  /// doesn't sort.
  final int? sortColumnIndex;
  final bool sortAscending;

  /// Set true to get the native leading checkbox column (row selection
  /// driven by each [DataRow]'s `selected`/`onSelectChanged`).
  final bool showCheckboxColumn;

  /// Wires the header checkbox (shown automatically whenever
  /// [showCheckboxColumn] is true) to actually select/clear every row -
  /// without this, Flutter still shows that checkbox but leaves it
  /// non-interactive. Left null to keep the header checkbox purely
  /// reflective (no tap action) where a table doesn't want one.
  final ValueChanged<bool?>? onSelectAll;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return ReuseEmptyState(message: emptyMessage);
    // Per the user (2026-09-06): table content (bot IDs, prices, etc.)
    // should be copyable - scoped to just the table (not the whole app,
    // which caused a red screen) since this is the one shared widget
    // behind every table (Next Trade, Auto bots, Manual bots).
    return SelectionArea(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: columns,
          rows: rows,
          headingRowHeight: 40,
          dataRowMinHeight: 44,
          dataRowMaxHeight: 52,
          showCheckboxColumn: showCheckboxColumn,
          onSelectAll: onSelectAll,
          sortColumnIndex: sortColumnIndex,
          sortAscending: sortAscending,
        ),
      ),
    );
  }
}
