import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/core_theme.dart';
import '../../data/control/engine_control_repository.dart';
import '../../data/models/auto_category.dart';
import '../../data/models/bot_history_entry.dart';
import '../../data/models/grid_bot.dart';
import '../../data/providers/app_providers.dart';
import '../../utilities/util_string.dart';
import '../../widgets/reuse_empty_state.dart';
import '../../widgets/reuse_error.dart';
import '../../widgets/reuse_loading_indicator.dart';

/// History, in tradingMT5's layout (2026-11-12, per the user: "check history
/// card in tradingmt5 and apply same concept"): a totals bar with an
/// All / Wins / Losses filter, a per-close-reason summary, the "P&L since"
/// divider line, and a wrapped grid of cards (up to 3 per row) - each card
/// tinted green / red by realized P&L, with header chips, investment and
/// P&L, three columns (open / close / trade) and a remarks section.
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

enum _HistoryFilter { all, wins, losses }

/// The close reason, from the structured `stopReason` (or the older free
/// text in `detail` for entries recorded before that field existed).
({String label, Color color, String explained}) historyReason(
  BotHistoryEntry e,
) {
  if (e.kind == BotHistoryKind.last) {
    return (
      label: 'Last',
      color: Colors.blueGrey,
      explained: 'Marked Last - it finished and was not reopened.',
    );
  }
  if (e.kind == BotHistoryKind.convertedToManual) {
    return (
      label: 'Converted to manual',
      color: Colors.orange,
      explained: 'Handed over to manual - the app stopped managing it.',
    );
  }
  switch (e.stopReason) {
    case 'take_profit':
      return (
        label: 'Take profit',
        color: Colors.green,
        explained: "Pionex hit the bot's take-profit.",
      );
    case 'stop_loss_lock':
      return (
        label: 'SLL',
        color: Colors.red,
        explained: 'The SLL stop-loss lock was hit.',
      );
    case 'stop_loss_baseline':
      return (
        label: 'SL baseline',
        color: Colors.red,
        explained: 'The old -50% baseline stop-loss was hit.',
      );
    case 'stop_loss_ratchet':
      return (
        label: 'SL ratchet',
        color: Colors.red,
        explained: 'The old ratchet stop-loss was hit.',
      );
    case 'liquidation':
      return (
        label: 'Liquidated',
        color: Colors.deepOrange,
        explained: 'Pionex liquidated the position.',
      );
    case 'terminated_by_user':
      return (
        label: 'Closed by user',
        color: Colors.orange,
        explained: 'Closed by you (the app or Pionex).',
      );
    case 'close_signal':
      return (
        label: 'Close signal',
        color: Colors.blue,
        explained: 'An opposite hybrid signal closed it.',
      );
    case 'never_filled':
      return (
        label: 'Never filled',
        color: Colors.amber,
        explained: 'No order ever filled - the app cancelled it.',
      );
  }
  final d = e.detail ?? '';
  if (d.contains('Stop Loss Lock')) {
    return (label: 'SLL', color: Colors.red, explained: 'The SLL stop-loss lock was hit.');
  }
  if (d.contains('Stopped from the app.') ||
      d.contains('Stopped manually via the gear menu.') ||
      d.contains('Canceled directly on Pionex/TradingView')) {
    return (
      label: 'Closed by user',
      color: Colors.orange,
      explained: 'Closed by you (the app or Pionex).',
    );
  }
  if (d.contains('Take-profit triggered')) {
    return (label: 'Take profit', color: Colors.green, explained: "Pionex hit the bot's take-profit.");
  }
  if (d.contains('Position liquidated')) {
    return (label: 'Liquidated', color: Colors.deepOrange, explained: 'Pionex liquidated the position.');
  }
  return (
    label: e.kind.label,
    color: Colors.grey,
    explained: 'Close reason not recorded.',
  );
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  _HistoryFilter _filter = _HistoryFilter.all;

  Future<void> _confirmClearAll(EngineControlRepository repo) async {
    final ok = await _confirm(
      'Delete all history?',
      'This permanently deletes every history record. This cannot be undone.',
    );
    if (ok) {
      repo.clearHistory();
      ref.invalidate(botHistoryProvider);
    }
  }

  Future<void> _confirmDeleteOne(
    EngineControlRepository repo,
    BotHistoryEntry e,
  ) async {
    final ok = await _confirm(
      'Delete this record?',
      '${e.pairKey}${e.buOrderId == null ? '' : ' (${e.buOrderId})'} will be '
          'permanently removed from history.',
    );
    if (ok) {
      repo.deleteHistoryEntry(e.id);
      ref.invalidate(botHistoryProvider);
    }
  }

  Future<bool> _confirm(String title, String body) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(controlRepositoryProvider);
    final historyAsync = ref.watch(botHistoryProvider);
    final scheme = Theme.of(context).colorScheme;
    final pnl = repo.pnlSummary();
    final favorites = repo.favoriteBotIds();

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete all history',
            onPressed: () => _confirmClearAll(repo),
          ),
        ],
      ),
      body: historyAsync.when(
        loading: () => const ReuseLoadingIndicator(),
        error: (err, st) => ReuseError(message: '$err'),
        data: (entries) {
          if (entries.isEmpty) {
            return const Center(
              child: ReuseEmptyState(
                message:
                    'No history yet - a bot shows up here once it closes, '
                    'is retired, or is converted to manual.',
                icon: Icons.history,
              ),
            );
          }
          final shown = entries
              .where(
                (e) => switch (_filter) {
                  _HistoryFilter.all => true,
                  _HistoryFilter.wins => (e.realizedProfit ?? 0) > 0,
                  _HistoryFilter.losses => (e.realizedProfit ?? 0) < 0,
                },
              )
              .toList();
          final since = pnl.since;
          // Newest first: the "P&L since" line sits before the first entry
          // older than the marker (or at the end if none is older).
          final markerIndex = since == null
              ? -1
              : () {
                  final i = shown.indexWhere((e) => e.ts.isBefore(since));
                  return i == -1 ? shown.length : i;
                }();
          return Column(
            children: [
              _TotalsBar(
                entries: entries,
                filter: _filter,
                onFilter: (f) => setState(() => _filter = f),
              ),
              _ReasonSummaryBar(entries: entries),
              const Divider(height: 1),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    const gap = 10.0;
                    final usable = constraints.maxWidth - 24;
                    final cols = (usable / 360).floor().clamp(1, 3);
                    final cardWidth = (usable - gap * (cols - 1)) / cols;
                    final rows = <Object>[];
                    var group = <BotHistoryEntry>[];
                    void flush() {
                      for (var i = 0; i < group.length; i += cols) {
                        rows.add(
                          group.sublist(i, (i + cols).clamp(0, group.length)),
                        );
                      }
                      group = [];
                    }

                    for (var i = 0; i < shown.length; i++) {
                      if (i == markerIndex) {
                        flush();
                        rows.add('marker');
                      }
                      group.add(shown[i]);
                    }
                    flush();
                    if (markerIndex == shown.length && markerIndex >= 0) {
                      rows.add('marker');
                    }
                    if (shown.isEmpty) {
                      return const Center(
                        child: ReuseEmptyState(
                          message: 'Nothing matches this filter.',
                          icon: Icons.filter_alt_off_outlined,
                        ),
                      );
                    }
                    return ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: rows.length,
                      itemBuilder: (context, i) {
                        final row = rows[i];
                        if (row is! List<BotHistoryEntry>) {
                          return _PnlDividerLine(since: since!, net: pnl.net);
                        }
                        return Padding(
                          padding: const EdgeInsets.only(bottom: gap),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (var c = 0; c < row.length; c++) ...[
                                if (c > 0) const SizedBox(width: gap),
                                SizedBox(
                                  width: cardWidth,
                                  child: _HistoryCard(
                                    entry: row[c],
                                    scheme: scheme,
                                    favorite: row[c].buOrderId != null &&
                                        favorites.contains(row[c].buOrderId),
                                    onDetails: () => context.push(
                                      '/history-details',
                                      extra: row[c],
                                    ),
                                    onDelete: () =>
                                        _confirmDeleteOne(repo, row[c]),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// "42 closed · win 26 · loss 16 · net +18.40" plus All / Wins / Losses.
class _TotalsBar extends StatelessWidget {
  const _TotalsBar({
    required this.entries,
    required this.filter,
    required this.onFilter,
  });

  final List<BotHistoryEntry> entries;
  final _HistoryFilter filter;
  final ValueChanged<_HistoryFilter> onFilter;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trading = context.tradingColors;
    final wins = entries.where((e) => (e.realizedProfit ?? 0) > 0).length;
    final losses = entries.where((e) => (e.realizedProfit ?? 0) < 0).length;
    final net = entries.fold<double>(0, (s, e) => s + (e.realizedProfit ?? 0));
    final netColor = net > 0
        ? trading.profit
        : net < 0
        ? trading.loss
        : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                children: [
                  TextSpan(
                    text:
                        '${entries.length} records  ·  win $wins  ·  loss $losses  ·  net ',
                  ),
                  TextSpan(
                    text: '${net >= 0 ? '+' : ''}${net.toStringAsFixed(2)}',
                    style: TextStyle(
                      color: netColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SegmentedButton<_HistoryFilter>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: _HistoryFilter.all, label: Text('All')),
              ButtonSegment(value: _HistoryFilter.wins, label: Text('Wins')),
              ButtonSegment(
                value: _HistoryFilter.losses,
                label: Text('Losses'),
              ),
            ],
            selected: {filter},
            onSelectionChanged: (s) => onFilter(s.first),
          ),
        ],
      ),
    );
  }
}

/// "Close signal (13): -12.40   SLL (4): +60.00 ..." - every record grouped
/// by close reason, with its count and total realized P&L.
class _ReasonSummaryBar extends StatelessWidget {
  const _ReasonSummaryBar({required this.entries});

  final List<BotHistoryEntry> entries;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trading = context.tradingColors;
    final counts = <String, int>{};
    final sums = <String, double>{};
    for (final e in entries) {
      final label = historyReason(e).label;
      counts[label] = (counts[label] ?? 0) + 1;
      sums[label] = (sums[label] ?? 0) + (e.realizedProfit ?? 0);
    }
    if (counts.isEmpty) return const SizedBox.shrink();
    final labels = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 16,
        runSpacing: 4,
        children: [
          for (final label in labels)
            Text.rich(
              TextSpan(
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                children: [
                  TextSpan(text: '$label (${counts[label]}): '),
                  TextSpan(
                    text:
                        '${sums[label]! >= 0 ? '+' : ''}${sums[label]!.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: sums[label]! < 0
                          ? trading.loss
                          : sums[label]! > 0
                          ? trading.profit
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// "P&L since <time>: +12.40" across the list, where the Dashboard's P&L
/// summary starts counting.
class _PnlDividerLine extends StatelessWidget {
  const _PnlDividerLine({required this.since, required this.net});

  final DateTime since;
  final double net;

  @override
  Widget build(BuildContext context) {
    final trading = context.tradingColors;
    final color = net < 0
        ? trading.loss
        : net > 0
        ? trading.profit
        : Colors.amber;
    final l = since.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final when =
        '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Divider(color: color.withValues(alpha: 0.6), thickness: 1.5),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              'P&L since $when: ${net >= 0 ? '+' : ''}${net.toStringAsFixed(2)}',
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Divider(color: color.withValues(alpha: 0.6), thickness: 1.5),
          ),
        ],
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({
    required this.entry,
    required this.scheme,
    required this.favorite,
    required this.onDetails,
    required this.onDelete,
  });

  final BotHistoryEntry entry;
  final ColorScheme scheme;
  final bool favorite;
  final VoidCallback onDetails;
  final VoidCallback onDelete;

  static String _short(DateTime? dt) {
    if (dt == null) return '—';
    final l = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  static String _duration(DateTime? start, DateTime? end) {
    if (start == null || end == null) return '—';
    final d = end.difference(start);
    if (d.inDays > 0) return '${d.inDays}d ${d.inHours % 24}h';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inSeconds}s';
  }

  /// Hybrid decision labels, same as the Auto cards.
  static String _signal(String? type, DateTime? at) {
    if (type == null) return '—';
    final label = switch (type) {
      'buyOpen1' => 'LL',
      'sellOpen1' => 'HH',
      'zigzagBuy' => 'Buy',
      'zigzagSell' => 'Sell',
      _ => type,
    };
    return '$label ${_short(at)}'.trim();
  }

  static String _price(double? v) =>
      (v == null || v == 0) ? '—' : UtilString.price(v);

  Widget _label(String text) => Text(
    text,
    style: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      color: scheme.onSurfaceVariant,
    ),
  );

  Widget _value(String text, {Color? color}) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(fontSize: 12, color: color),
  );

  Widget _cell(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [_label(label), const SizedBox(height: 1), _value(value)],
    ),
  );

  Widget _badge(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final trading = context.tradingColors;
    final profit = entry.realizedProfit;
    final tint = profit == null || profit == 0
        ? null
        : (profit > 0 ? trading.profit : trading.loss);
    final reason = historyReason(entry);
    final isLong = entry.direction == GridDirection.long;
    final pct = entry.profitPercent;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: tint?.withValues(alpha: 0.08) ?? scheme.surfaceContainerLow,
        border: Border.all(
          color: tint?.withValues(alpha: 0.7) ?? scheme.outlineVariant,
          width: tint == null ? 1 : 1.4,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text(
                        entry.pairKey,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    if (favorite)
                      const Tooltip(
                        message: 'Favorite trade',
                        child: Icon(Icons.star, size: 16, color: Colors.amber),
                      ),
                    if (entry.direction != null)
                      _badge(
                        isLong ? 'LONG' : 'SHORT',
                        isLong ? trading.profit : trading.loss,
                      ),
                    if (entry.leverage != null)
                      _badge(
                        '${entry.leverage!.toStringAsFixed(0)}x',
                        scheme.outline,
                      ),
                    _badge(reason.label, reason.color),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'More',
                onSelected: (v) => v == 'details' ? onDetails() : onDelete(),
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'details',
                    child: Row(
                      children: [
                        Icon(Icons.info_outline, size: 20),
                        SizedBox(width: 10),
                        Text('Details'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline, size: 20, color: Colors.red),
                        SizedBox(width: 10),
                        Text(
                          'Delete record',
                          style: TextStyle(color: Colors.red),
                        ),
                      ],
                    ),
                  ),
                ],
                child: Icon(
                  Icons.more_vert,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Wrap(
            children: [
              if (entry.buOrderId != null)
                SelectableText(
                  '#${entry.buOrderId}',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              Text(
                '  ·  ${entry.category?.label ?? 'Manual'}  ·  '
                '${_duration(entry.startTime, entry.endTime ?? entry.ts)}',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _label('Investment'),
                          _value(
                            entry.initialInvestment == null
                                ? '—'
                                : UtilString.usd(entry.initialInvestment!),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      color: (tint ?? scheme.outline).withValues(alpha: 0.12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _label('Realized P&L'),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              profit == null
                                  ? '—'
                                  : '${profit >= 0 ? '+' : ''}${profit.toStringAsFixed(2)}'
                                        '${pct == null ? '' : ' (${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(2)}%)'}',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: tint ?? scheme.onSurface,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _cell('Opened', _short(entry.startTime)),
                      _cell('Entry', _price(entry.entryPrice)),
                      _cell(
                        'Open signal',
                        _signal(entry.openSignalType, entry.openSignalAt),
                      ),
                    ],
                  ),
                ),
                VerticalDivider(width: 14, color: scheme.outlineVariant),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _cell('Closed', _short(entry.endTime ?? entry.ts)),
                      _cell('Close price', _price(entry.exitPrice)),
                      _cell(
                        'Close signal',
                        _signal(entry.closeSignalType, entry.closeSignalAt),
                      ),
                    ],
                  ),
                ),
                VerticalDivider(width: 14, color: scheme.outlineVariant),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _cell(
                        'Range',
                        (entry.bottom == null || entry.top == null)
                            ? '—'
                            : '${_price(entry.bottom)}–${_price(entry.top)}',
                      ),
                      _cell('Grids', entry.gridCount?.toString() ?? '—'),
                      _cell(
                        'Extra margin',
                        entry.extraMargin == null
                            ? '—'
                            : UtilString.usd(entry.extraMargin!),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _label('Remarks'),
                const SizedBox(height: 2),
                Text(reason.explained, style: const TextStyle(fontSize: 12)),
                if (entry.detail != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    entry.detail!,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (entry.liquidationPrice != null &&
                    entry.liquidationPrice != 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Liquidation: ${_price(entry.liquidationPrice)}',
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
