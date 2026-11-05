import 'package:flutter/material.dart';

import '../core/core_theme.dart';
import '../utilities/util_string.dart';

/// A horizontal visualization of a grid bot's price range: bottom—top bounds,
/// with markers for entry, live price, and liquidation price plotted at
/// their fractional position along the span. This is the "diagram" view of
/// the same numbers shown in the stat grid next to it — not a substitute for
/// them, since a squashed diagram can't show precise values.
class GridRangeDiagram extends StatelessWidget {
  const GridRangeDiagram({
    super.key,
    required this.top,
    required this.bottom,
    this.entry,
    this.current,
    this.liquidation,
  });

  final double top;
  final double bottom;
  final double? entry;
  final double? current;
  final double? liquidation;

  double? _fractionOf(double? price) {
    if (price == null) return null;
    final span = top - bottom;
    if (span <= 0) return null;
    return ((price - bottom) / span).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trading = context.tradingColors;
    final textTheme = Theme.of(context).textTheme;

    final entryFrac = _fractionOf(entry);
    final currentFrac = _fractionOf(current);
    final liqFrac = liquidation != null && liquidation! > 0
        ? _fractionOf(liquidation)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 34,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              Widget marker(double? frac, Color color, String label) {
                if (frac == null) return const SizedBox.shrink();
                final x = (frac * width).clamp(6.0, width - 6.0);
                return Positioned(
                  left: x - 6,
                  top: 0,
                  child: Tooltip(
                    message: label,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.surface, width: 2),
                      ),
                    ),
                  ),
                );
              }

              return Stack(
                children: [
                  Positioned(
                    top: 12,
                    left: 0,
                    right: 0,
                    child: Container(
                      height: 8,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        gradient: LinearGradient(
                          colors: [
                            trading.loss.withValues(alpha: 0.5),
                            scheme.surfaceContainerHighest,
                            trading.profit.withValues(alpha: 0.5),
                          ],
                        ),
                      ),
                    ),
                  ),
                  marker(
                    liqFrac,
                    trading.loss,
                    'Liquidation ${liquidation != null ? UtilString.price(liquidation!) : ''}',
                  ),
                  marker(
                    entryFrac,
                    scheme.primary,
                    'Entry ${entry != null ? UtilString.price(entry!) : ''}',
                  ),
                  marker(
                    currentFrac,
                    scheme.onSurface,
                    'Current ${current != null ? UtilString.price(current!) : ''}',
                  ),
                ],
              );
            },
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(UtilString.price(bottom), style: textTheme.labelSmall),
            Text(UtilString.price(top), style: textTheme.labelSmall),
          ],
        ),
      ],
    );
  }
}
