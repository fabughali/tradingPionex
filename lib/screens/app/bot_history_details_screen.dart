import 'package:flutter/material.dart';

import '../../core/core_layout.dart';
import '../../core/core_spacing.dart';
import '../../core/core_theme.dart';
import '../../data/models/bot_history_entry.dart';
import '../../data/models/grid_bot.dart';
import '../../utilities/util_date.dart';
import '../../utilities/util_string.dart';
import '../../widgets/reuse_card.dart';
import '../../widgets/reuse_chip.dart';

/// Full-detail, read-only view of one History record — reached by tapping a
/// row on [HistoryScreen]. Shows whatever snapshot was captured at the
/// moment the event was recorded (see `BotHistoryEntry`); fields the
/// recording site didn't have on hand at that moment are shown as "—"
/// rather than guessed.
class BotHistoryDetailsScreen extends StatelessWidget {
  const BotHistoryDetailsScreen({super.key, required this.entry});

  final BotHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final trading = context.tradingColors;
    final textTheme = Theme.of(context).textTheme;
    final profit = entry.realizedProfit;
    final profitColor = profit == null
        ? null
        : (profit >= 0 ? trading.profit : trading.loss);
    final duration = (entry.startTime != null && entry.endTime != null)
        ? entry.endTime!.difference(entry.startTime!)
        : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(entry.pairKey),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: CoreSpacing.md),
            child: Center(
              child: ReuseChip(
                label: entry.kind.label,
                tone: switch (entry.kind) {
                  BotHistoryKind.last => ReuseChipTone.neutral,
                  BotHistoryKind.terminated => ReuseChipTone.danger,
                  BotHistoryKind.convertedToManual => ReuseChipTone.warning,
                },
              ),
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) => ListView(
          padding: CoreLayout.edgeMargin(constraints),
          children: [
            ReuseCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(entry.pairKey, style: textTheme.headlineSmall),
                      const SizedBox(width: CoreSpacing.sm),
                      if (entry.direction != null)
                        ReuseChip(
                          label: entry.direction!.wireValue.toUpperCase(),
                          tone: entry.direction == GridDirection.long
                              ? ReuseChipTone.success
                              : ReuseChipTone.danger,
                        ),
                      const Spacer(),
                      if (profit != null)
                        Text(
                          '${profit >= 0 ? '+' : ''}${UtilString.usd(profit)}${entry.profitPercent != null ? ' (${entry.profitPercent!.toStringAsFixed(1)}%)' : ''}',
                          style: textTheme.headlineSmall?.copyWith(
                            color: profitColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                    ],
                  ),
                  if (entry.detail != null) ...[
                    const SizedBox(height: CoreSpacing.sm),
                    Text(entry.detail!, style: textTheme.bodyMedium),
                  ],
                ],
              ),
            ),
            ReuseCard(
              title: 'Timing',
              child: Wrap(
                spacing: CoreSpacing.lg,
                runSpacing: CoreSpacing.sm,
                children: [
                  _Stat(
                    'Started',
                    entry.startTime == null
                        ? null
                        : UtilDate.dateTime(entry.startTime!),
                  ),
                  _Stat(
                    entry.kind == BotHistoryKind.terminated
                        ? 'Stopped'
                        : 'Event time',
                    entry.endTime == null
                        ? UtilDate.dateTime(entry.ts)
                        : UtilDate.dateTime(entry.endTime!),
                  ),
                  _Stat(
                    'Duration',
                    duration == null ? null : _formatDuration(duration),
                  ),
                  _Stat('Recorded', UtilDate.dateTime(entry.ts)),
                ],
              ),
            ),
            ReuseCard(
              title: 'Position',
              child: Wrap(
                spacing: CoreSpacing.lg,
                runSpacing: CoreSpacing.sm,
                children: [
                  _Stat(
                    'Entry price',
                    entry.entryPrice == null
                        ? null
                        : UtilString.price(entry.entryPrice!),
                  ),
                  _Stat(
                    'Exit price',
                    entry.exitPrice == null
                        ? null
                        : UtilString.price(entry.exitPrice!),
                  ),
                  _Stat(
                    'Leverage',
                    entry.leverage == null
                        ? null
                        : '${entry.leverage!.toStringAsFixed(0)}x',
                  ),
                  _Stat(
                    'Liquidation price',
                    entry.liquidationPrice == null
                        ? null
                        : UtilString.price(entry.liquidationPrice!),
                  ),
                  _Stat(
                    'Range top',
                    entry.top == null ? null : UtilString.price(entry.top!),
                  ),
                  _Stat(
                    'Range bottom',
                    entry.bottom == null
                        ? null
                        : UtilString.price(entry.bottom!),
                  ),
                  _Stat('Grids', entry.gridCount?.toString()),
                ],
              ),
            ),
            ReuseCard(
              title: 'Investment',
              child: Wrap(
                spacing: CoreSpacing.lg,
                runSpacing: CoreSpacing.sm,
                children: [
                  _Stat(
                    'Initial investment',
                    entry.initialInvestment == null
                        ? null
                        : UtilString.usd(entry.initialInvestment!),
                  ),
                  _Stat(
                    'Actual investment',
                    entry.actualInvestment == null
                        ? null
                        : UtilString.usd(entry.actualInvestment!),
                  ),
                  _Stat(
                    'Extra margin',
                    entry.extraMargin == null
                        ? null
                        : UtilString.usd(entry.extraMargin!),
                  ),
                  _Stat(
                    'Realized P&L',
                    profit == null
                        ? null
                        : '${profit >= 0 ? '+' : ''}${UtilString.usd(profit)}',
                    color: profitColor,
                  ),
                ],
              ),
            ),
            ReuseCard(
              title: 'Record',
              child: Wrap(
                spacing: CoreSpacing.lg,
                runSpacing: CoreSpacing.sm,
                children: [
                  _Stat('Order ID', entry.buOrderId),
                  _Stat('Base', entry.base),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatDuration(Duration d) {
    if (d.inDays > 0) return '${d.inDays}d ${d.inHours % 24}h';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inSeconds}s';
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, {this.color});

  final String label;
  final String? value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 160,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          Text(
            value ?? '—',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
