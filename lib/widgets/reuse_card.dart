import 'package:flutter/material.dart';

import '../core/core_spacing.dart';

/// A titled card section — the base building block for every dashboard
/// panel (status, balance, grids table, log viewer).
class ReuseCard extends StatelessWidget {
  const ReuseCard({
    super.key,
    this.title,
    this.titleLeading,
    this.trailing,
    required this.child,
    this.padding,
    this.color,
  });

  final String? title;

  /// An optional small widget shown immediately before the title text (e.g.
  /// a live/alive indicator dot) - 2026-09-11, per the user.
  final Widget? titleLeading;
  final Widget? trailing;
  final Widget child;
  final EdgeInsetsGeometry? padding;

  /// Optional background tint (2026-09-19, per the user - History card
  /// coloring by P&L: green/red/yellow) - null keeps the theme's normal
  /// card color, unchanged for every other caller.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: CoreSpacing.md),
      color: color,
      child: Padding(
        padding: padding ?? const EdgeInsets.all(CoreSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.only(bottom: CoreSpacing.sm),
                child: Row(
                  // Bug fixed 2026-09-15, per the user ("why the title auto
                  // bot shifted below??"): this Row defaulted to
                  // CrossAxisAlignment.center, so its height always matched
                  // its TALLEST child - fine while every `trailing` was a
                  // single line, but PnlSummaryView grew a 3rd line the
                  // same day (the reset timestamp), making `trailing`
                  // taller than the title and visually shoving the
                  // (center-aligned) title text down to match. Top-aligning
                  // keeps the title pinned to the row's top edge regardless
                  // of how tall `trailing` grows.
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      // Reverted 2026-09-10: wrapping `trailing` in
                      // `Flexible` (to fix an overflow-clip bug) gave it an
                      // equal flex share against this title - since both
                      // default to flex:1, a short title like "Engine"
                      // still only got HALF the row, shoving every trailing
                      // widget (Free balance, the P&L summary) away from
                      // the card's right edge toward the middle. Reverted
                      // trailing back to unwrapped (its natural size,
                      // pinned flush right since Expanded absorbs all
                      // remaining slack) and added ellipsis here instead -
                      // the title shrinks/truncates first if a wide
                      // trailing genuinely needs the space, which is what
                      // actually prevents the overflow without breaking
                      // right-alignment for the normal case.
                      child: Row(
                        children: [
                          if (titleLeading != null) ...[
                            titleLeading!,
                            const SizedBox(width: CoreSpacing.sm),
                          ],
                          Expanded(
                            child: Text(
                              title!,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (trailing != null) trailing!,
                  ],
                ),
              ),
            child,
          ],
        ),
      ),
    );
  }
}
