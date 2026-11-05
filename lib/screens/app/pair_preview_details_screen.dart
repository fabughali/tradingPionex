import 'package:flutter/material.dart';

import '../../core/core_layout.dart';
import '../../core/core_spacing.dart';
import '../../core/core_theme.dart';
import '../../data/models/grid_bot.dart';
import '../../data/models/preview_grid_pair.dart';
import '../../utilities/util_string.dart';
import '../../widgets/grid_range_diagram.dart';
import '../../widgets/reuse_card.dart';
import '../../widgets/reuse_chip.dart';

/// Full-detail, read-only view of a single "Last report" candidate — a
/// preview of what a NEW bot would look like if started on this pair right
/// now, computed by the engine (never the GUI) using the exact same signal/
/// range/leverage/grid-count logic it would use for a real open. These
/// numbers are a guide, not a lock-in: the engine re-runs this calculation
/// for real the moment you actually press Start, so a fast-moving market can
/// make the real numbers differ slightly from this preview.
class PairPreviewDetailsScreen extends StatelessWidget {
  const PairPreviewDetailsScreen({super.key, required this.preview});

  final PreviewGridPair preview;

  @override
  Widget build(BuildContext context) {
    final trading = context.tradingColors;
    final textTheme = Theme.of(context).textTheme;
    final isLong = preview.direction == GridDirection.long;

    return Scaffold(
      appBar: AppBar(
        title: Text(preview.pairKey),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: CoreSpacing.md),
            child: Center(
              child: ReuseChip(label: 'Preview', tone: ReuseChipTone.neutral),
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
                      Text(preview.pairKey, style: textTheme.headlineSmall),
                      const SizedBox(width: CoreSpacing.sm),
                      ReuseChip(
                        label: preview.direction.wireValue.toUpperCase(),
                        tone: isLong
                            ? ReuseChipTone.success
                            : ReuseChipTone.danger,
                      ),
                      const Spacer(),
                      Text(
                        UtilString.price(preview.entryPrice),
                        style: textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text('Anticipated entry price', style: textTheme.labelSmall),
                  const SizedBox(height: CoreSpacing.md),
                  GridRangeDiagram(
                    top: preview.top,
                    bottom: preview.bottom,
                    entry: preview.entryPrice,
                    liquidation: preview.liquidationPrice,
                  ),
                ],
              ),
            ),
            ReuseCard(
              title: 'Price range',
              child: Wrap(
                spacing: CoreSpacing.lg,
                runSpacing: CoreSpacing.sm,
                children: [
                  _Stat('Range top', UtilString.price(preview.top)),
                  _Stat('Range bottom', UtilString.price(preview.bottom)),
                  _Stat(
                    '60/40 model',
                    preview.widenApplied
                        ? 'Adjusted (TP edge pulled in)'
                        : (preview.stable ? 'Stable, unchanged' : 'Unchanged'),
                  ),
                  _Stat(
                    'Take profit',
                    UtilString.price(preview.takeProfitPrice),
                  ),
                  _Stat(
                    'Stop loss (fixed edge)',
                    UtilString.price(preview.stopLossPrice),
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
                  _Stat('Grids', preview.gridCount.toString()),
                  _Stat('Leverage', '${preview.leverage.toStringAsFixed(0)}x'),
                  _Stat(
                    'Max leverage (Pionex)',
                    '${preview.maxLeverage.toStringAsFixed(0)}x',
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
                    preview.initialInvestment == null
                        ? 'Unavailable'
                        : UtilString.usd(preview.initialInvestment!),
                  ),
                  _Stat(
                    'Actual investment',
                    preview.actualInvestment == null
                        ? 'Unavailable'
                        : UtilString.usd(preview.actualInvestment!),
                  ),
                  _Stat(
                    'Extra margin',
                    preview.extraMargin == null
                        ? 'Unavailable'
                        : UtilString.usd(preview.extraMargin!),
                  ),
                ],
              ),
            ),
            ReuseCard(
              title: 'Risk',
              child: Wrap(
                spacing: CoreSpacing.lg,
                runSpacing: CoreSpacing.sm,
                children: [
                  _Stat(
                    'Expected liquidation price',
                    (preview.liquidationPrice == null ||
                            preview.liquidationPrice == 0)
                        ? 'Unavailable'
                        : UtilString.price(preview.liquidationPrice!),
                    color: trading.loss,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: CoreSpacing.sm),
              child: Text(
                'These numbers are a preview only — the engine recalculates for real the moment you press Start, '
                'so a fast-moving market can change the actual result slightly.',
                style: textTheme.bodySmall,
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
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          Text(
            value,
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
