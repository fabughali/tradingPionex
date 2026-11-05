import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/core_spacing.dart';
import '../core/core_theme.dart';
import '../data/models/grid_bot.dart';
import '../utilities/util_string.dart';
import 'grid_range_diagram.dart';
import 'reuse_chip.dart';

/// A single running grid bot, shown Pionex-style: header (pair/direction/
/// status), the range diagram, then every numeric field Pionex itself
/// reports for the bot. Used on the Dashboard for auto (app-initiated)
/// grids, where the extra detail earns its space — the Controls screen's
/// plain table is enough for quick stop actions. Tapping the card opens
/// [BotDetailsScreen] with the same full-detail view the manual bots table
/// links to.
class GridBotCard extends StatelessWidget {
  const GridBotCard({super.key, required this.bot, this.isRetired = false});

  final GridBot bot;

  /// True once this bot's base has been sent through the "Last" flow
  /// (retired): it keeps running and shows here like any other auto bot
  /// until it closes on its own, but the engine will never auto-recreate
  /// it afterward. Surfaced as a chip so this isn't a silent state.
  final bool isRetired;

  @override
  Widget build(BuildContext context) {
    final trading = context.tradingColors;
    final textTheme = Theme.of(context).textTheme;
    final profit = bot.profitAmount;
    final profitColor = profit == null
        ? null
        : (profit >= 0 ? trading.profit : trading.loss);

    return Card(
      margin: const EdgeInsets.only(bottom: CoreSpacing.md),
      child: InkWell(
        onTap: () => context.push('/bot-details', extra: bot),
        child: Padding(
          padding: const EdgeInsets.all(CoreSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(bot.pairKey, style: textTheme.titleMedium),
                  const SizedBox(width: CoreSpacing.sm),
                  if (bot.trend != null)
                    ReuseChip(
                      label: bot.trend!.wireValue.toUpperCase(),
                      tone: bot.trend == GridDirection.long
                          ? ReuseChipTone.success
                          : ReuseChipTone.danger,
                    ),
                  const SizedBox(width: CoreSpacing.xs),
                  ReuseChip(
                    label: bot.status,
                    tone: bot.status.toLowerCase() == 'running'
                        ? ReuseChipTone.neutral
                        : ReuseChipTone.warning,
                  ),
                  if (isRetired) ...[
                    const SizedBox(width: CoreSpacing.xs),
                    const ReuseChip(label: 'Last', tone: ReuseChipTone.warning),
                  ],
                  const Spacer(),
                  if (profit != null)
                    Text(
                      '${profit >= 0 ? '+' : ''}${UtilString.usd(profit)}${bot.profitPercent != null ? ' (${bot.profitPercent!.toStringAsFixed(1)}%)' : ''}',
                      style: textTheme.titleMedium?.copyWith(
                        color: profitColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: CoreSpacing.sm),
              if (bot.top != null && bot.bottom != null)
                GridRangeDiagram(
                  top: bot.top!,
                  bottom: bot.bottom!,
                  entry: bot.entryPrice,
                  current: bot.currentPrice,
                  liquidation: bot.liquidationPrice,
                ),
              const SizedBox(height: CoreSpacing.sm),
              Wrap(
                spacing: CoreSpacing.lg,
                runSpacing: CoreSpacing.xs,
                children: [
                  _Stat(
                    'Initial investment',
                    bot.initialInvestment == null
                        ? null
                        : UtilString.usd(bot.initialInvestment!),
                  ),
                  _Stat(
                    'Actual investment',
                    bot.actualInvestment == null
                        ? null
                        : UtilString.usd(bot.actualInvestment!),
                  ),
                  _Stat(
                    'Extra margin',
                    bot.extraMargin == null
                        ? null
                        : UtilString.usd(bot.extraMargin!),
                  ),
                  _Stat(
                    'Current price',
                    bot.currentPrice == null
                        ? null
                        : UtilString.price(bot.currentPrice!),
                  ),
                  _Stat(
                    'Liquidation price',
                    (bot.liquidationPrice == null || bot.liquidationPrice == 0)
                        ? null
                        : UtilString.price(bot.liquidationPrice!),
                  ),
                  _Stat(
                    'Leverage',
                    bot.leverage == null
                        ? null
                        : '${bot.leverage!.toStringAsFixed(0)}x',
                  ),
                  _Stat('Grids', bot.row?.toString()),
                  _Stat('Grid type', bot.gridType),
                  _Stat(
                    'Realized P&L',
                    bot.totalRealizedProfit == null
                        ? null
                        : UtilString.usd(bot.totalRealizedProfit!),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          Text(
            value ?? '—',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
