import 'package:flutter/material.dart';

import '../core/core_theme.dart';
import '../utilities/util_string.dart';

/// Auto bots card's profit/loss summary (2026-09-10, per the user) —
/// total profit (green) - total loss (red) = net total (green/red by
/// sign), each summed from `EngineControlRepository.pnlSummary()` across
/// every closed auto bot since the last reset. The reset icon moves the
/// cutoff forward without touching the underlying History screen's
/// permanent record — see `pnlSummary`'s own doc for why.
///
/// Reordered 2026-09-21, per the user ("i want you to check sum too and
/// also change it to green - red = sum") — was `-loss + profit = net`
/// (loss first); now leads with profit (green) minus loss (red), reading
/// left-to-right the way the expression's name implies.
///
/// Bug fixed 2026-09-10, after the user repeatedly reported the sum
/// "never updates" despite the underlying data being independently
/// verified correct (recomputed straight from bot-history.jsonl and
/// diffed against real close events - it changed exactly as expected
/// every time). Root cause: this rendered as a fixed-width `Row` inside
/// `ReuseCard`'s title row, which gives its `trailing` slot whatever space
/// is left over after the title's `Expanded` text - on a narrow enough
/// window, `Row(mainAxisSize: min)` still overflows that leftover space
/// (`mainAxisSize` only affects sizing when there's slack, not when
/// squeezed), and Flutter's release builds clip overflow silently with no
/// error - the numbers COULD be changing every 5s exactly as designed and
/// still look "frozen" because they were fully or partially clipped off
/// screen the whole time. Switched to `Wrap`, which degrades to a second
/// line instead of clipping, so the content is always fully visible
/// regardless of available width.
class PnlSummaryView extends StatelessWidget {
  const PnlSummaryView({
    super.key,
    required this.profit,
    required this.loss,
    required this.net,
    required this.profitCount,
    required this.lossCount,
    required this.neutralCount,
    required this.successRatePercent,
    required this.since,
    required this.onReset,
    required this.onSummaryTap,
  });

  final double profit;
  final double loss;
  final double net;

  /// When this summary's cutoff last moved (`EngineControlRepository
  /// .pnlSummary()`'s own `since`) - null means "since the beginning of
  /// bot-history.jsonl" (never explicitly reset). Shown under the reset
  /// icon (2026-09-15, per the user).
  final DateTime? since;

  /// Counts of the same closed-since-reset entries the sum above is drawn
  /// from, split by sign (2026-09-11, per the user) - strictly positive,
  /// strictly negative, and exactly zero respectively.
  final int profitCount;
  final int lossCount;
  final int neutralCount;

  /// `profitCount / (profitCount + lossCount) * 100` - neutral entries
  /// excluded from both sides, per the user's explicit choice. Null when
  /// there's no profit or loss entry yet (nothing to compute a rate from).
  final double? successRatePercent;

  final VoidCallback onReset;

  /// Opens the per-pair breakdown screen (2026-09-13, per the user: "add
  /// summary for each pair" - "once user click on summary in auto card,
  /// app navigates to this screen"). A visible, labeled tap target rather
  /// than the whole widget silently being tappable - per the user's own
  /// correction mid-implementation ("once user click on summary in auto
  /// card"), it's specifically this link, not the surrounding area.
  final VoidCallback onSummaryTap;

  @override
  Widget build(BuildContext context) {
    final trading = context.tradingColors;
    final style = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700);
    final netSign = net < 0 ? '-' : '+';
    final netColor = net >= 0 ? trading.profit : trading.loss;

    // Three-row layout (2026-09-19, redesigned per the user): timestamp +
    // reset icon share the top row (timestamp left, icon right); the sum
    // expression is its own row below that; the up/down counts (plus
    // neutral/success rate) are the last row.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: 'When this summary last reset',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.history,
                    size: 14,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    since == null
                        ? 'Since app start'
                        : 'Since ${UtilString.dateTime12h(since!)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Tooltip(
              message: 'Reset this summary',
              child: IconButton(
                icon: const Icon(Icons.restart_alt, size: 18),
                onPressed: onReset,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 32,
                  minHeight: 32,
                ),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
        Wrap(
          // Bug fixed 2026-09-10: Wrap fills its whole allocated box (the
          // Flexible slot ReuseCard now gives it) and left-aligns content
          // within that box by default - since the box starts right after
          // the card title, the content visibly drifted toward the middle
          // of the card instead of staying pinned to the right edge where
          // it sat before the overflow fix. `alignment: end` right-aligns
          // the content within whatever width it's given, keeping it flush
          // with the card's right edge in the normal (non-wrapped) case.
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          children: [
            Tooltip(
              message: 'Total profit',
              child: Text(
                UtilString.usd(profit),
                style: style?.copyWith(color: trading.profit),
              ),
            ),
            const Text('-'),
            Tooltip(
              message: 'Total loss',
              child: Text(
                UtilString.usd(loss),
                style: style?.copyWith(color: trading.loss),
              ),
            ),
            const Text('='),
            Tooltip(
              message: 'Net total since last reset',
              child: Text(
                '$netSign${UtilString.usd(net.abs())}',
                // Per the user (2026-09-11): green at/above zero, red below
                // - was always the neutral "warning" color regardless of
                // sign.
                style: style?.copyWith(color: netColor),
              ),
            ),
          ],
        ),
        Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          runSpacing: 2,
          children: [
            Tooltip(
              message: 'Bots that closed in profit since last reset',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.arrow_upward, size: 15, color: trading.profit),
                  const SizedBox(width: 2),
                  Text(
                    '$profitCount',
                    style: style?.copyWith(color: trading.profit),
                  ),
                ],
              ),
            ),
            Tooltip(
              message: 'Bots that closed at a loss since last reset',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.arrow_downward, size: 15, color: trading.loss),
                  const SizedBox(width: 2),
                  Text(
                    '$lossCount',
                    style: style?.copyWith(color: trading.loss),
                  ),
                ],
              ),
            ),
            Tooltip(
              message: 'Bots that closed exactly breakeven since last reset',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle, size: 10, color: trading.warning),
                  const SizedBox(width: 4),
                  Text(
                    '$neutralCount',
                    style: style?.copyWith(color: trading.warning),
                  ),
                ],
              ),
            ),
            Tooltip(
              message:
                  'Success rate: profit bots / (profit + loss bots), '
                  'breakeven excluded',
              child: Text(
                successRatePercent == null
                    ? 'Success: —'
                    : 'Success: ${successRatePercent!.round()}%',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: InkWell(
            onTap: onSummaryTap,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Summary',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      decoration: TextDecoration.underline,
                    ),
                  ),
                  const SizedBox(width: 2),
                  const Icon(Icons.chevron_right, size: 14),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
