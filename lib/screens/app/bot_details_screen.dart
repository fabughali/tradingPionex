import 'package:flutter/material.dart';

import '../../core/core_layout.dart';
import '../../core/core_spacing.dart';
import '../../core/core_theme.dart';
import '../../data/models/grid_bot.dart';
import '../../utilities/util_string.dart';
import '../../widgets/grid_range_diagram.dart';
import '../../widgets/reuse_card.dart';
import '../../widgets/reuse_chip.dart';

/// Full-detail, read-only view of a single grid bot (auto or manual) —
/// Pionex-style: every field grouped the way Pionex's own bot-detail page
/// groups them. Reached by tapping a row in [GridsTable] or a card in
/// [GridBotCard]. Never offers a stop/cancel action here — that stays on the
/// originating screen so it's obvious whether the bot is app- or
/// manually-initiated before acting on it.
class BotDetailsScreen extends StatelessWidget {
  const BotDetailsScreen({super.key, required this.bot});

  final GridBot bot;

  @override
  Widget build(BuildContext context) {
    final trading = context.tradingColors;
    final textTheme = Theme.of(context).textTheme;
    final profit = bot.profitAmount;
    final profitColor = profit == null
        ? null
        : (profit >= 0 ? trading.profit : trading.loss);

    return Scaffold(
      appBar: AppBar(
        title: Text(bot.pairKey),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: CoreSpacing.md),
            child: Center(
              child: ReuseChip(
                label: bot.appInitiated ? 'Auto' : 'Manual',
                tone: bot.appInitiated
                    ? ReuseChipTone.success
                    : ReuseChipTone.neutral,
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
                      Text(bot.pairKey, style: textTheme.headlineSmall),
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
                      const Spacer(),
                      if (profit != null)
                        Text(
                          '${profit >= 0 ? '+' : ''}${UtilString.usd(profit)}${bot.profitPercent != null ? ' (${bot.profitPercent!.toStringAsFixed(1)}%)' : ''}',
                          style: textTheme.headlineSmall?.copyWith(
                            color: profitColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                    ],
                  ),
                  if (bot.top != null && bot.bottom != null) ...[
                    const SizedBox(height: CoreSpacing.md),
                    GridRangeDiagram(
                      top: bot.top!,
                      bottom: bot.bottom!,
                      entry: bot.entryPrice,
                      current: bot.currentPrice,
                      liquidation: bot.liquidationPrice,
                    ),
                  ],
                ],
              ),
            ),
            ReuseCard(
              title: 'Position',
              child: Wrap(
                spacing: CoreSpacing.lg,
                runSpacing: CoreSpacing.sm,
                children: [
                  _Stat('Direction', bot.trend?.wireValue.toUpperCase()),
                  _Stat(
                    'Entry price',
                    bot.entryPrice == null
                        ? null
                        : UtilString.price(bot.entryPrice!),
                  ),
                  _Stat(
                    'Current price',
                    bot.currentPrice == null
                        ? null
                        : UtilString.price(bot.currentPrice!),
                  ),
                  _Stat('Position size', bot.positionSize?.toString()),
                  _Stat(
                    'Leverage',
                    bot.leverage == null
                        ? null
                        : '${bot.leverage!.toStringAsFixed(0)}x',
                  ),
                  _Stat(
                    'Liquidation price',
                    (bot.liquidationPrice == null || bot.liquidationPrice == 0)
                        ? null
                        : UtilString.price(bot.liquidationPrice!),
                  ),
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
                    'Margin balance',
                    bot.marginBalance == null
                        ? null
                        : UtilString.usd(bot.marginBalance!),
                  ),
                ],
              ),
            ),
            ReuseCard(
              title: 'Profit & loss',
              child: Wrap(
                spacing: CoreSpacing.lg,
                runSpacing: CoreSpacing.sm,
                children: [
                  _Stat(
                    'Total P&L',
                    profit == null
                        ? null
                        : '${profit >= 0 ? '+' : ''}${UtilString.usd(profit)}',
                    color: profitColor,
                  ),
                  _Stat(
                    'P&L %',
                    bot.profitPercent == null
                        ? null
                        : '${bot.profitPercent!.toStringAsFixed(2)}%',
                    color: profitColor,
                  ),
                  _Stat(
                    'Realized profit',
                    bot.totalRealizedProfit == null
                        ? null
                        : UtilString.usd(bot.totalRealizedProfit!),
                  ),
                  _Stat(
                    'Grid profit',
                    bot.gridProfit == null
                        ? null
                        : UtilString.usd(bot.gridProfit!),
                  ),
                  _Stat(
                    'Total fee',
                    bot.totalFee == null ? null : UtilString.usd(bot.totalFee!),
                  ),
                  _Stat(
                    'Funding fee',
                    bot.totalFundingFee == null
                        ? null
                        : UtilString.usd(bot.totalFundingFee!),
                  ),
                ],
              ),
            ),
            ReuseCard(
              title: 'Grid configuration',
              child: Wrap(
                spacing: CoreSpacing.lg,
                runSpacing: CoreSpacing.sm,
                children: [
                  _Stat('Grids', bot.row?.toString()),
                  _Stat('Grid type', bot.gridType),
                  _Stat(
                    'Range top',
                    bot.top == null ? null : UtilString.price(bot.top!),
                  ),
                  _Stat(
                    'Range bottom',
                    bot.bottom == null ? null : UtilString.price(bot.bottom!),
                  ),
                ],
              ),
            ),
            ReuseCard(
              title: 'Order',
              child: Wrap(
                spacing: CoreSpacing.lg,
                runSpacing: CoreSpacing.sm,
                children: [
                  _Stat('Order ID', bot.buOrderId),
                  _Stat('Status', bot.status),
                  _Stat(
                    'Origin',
                    bot.appInitiated ? 'Auto (app-initiated)' : 'Manual',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
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
