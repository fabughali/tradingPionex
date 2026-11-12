import 'package:flutter/material.dart';

import '../core/core_spacing.dart';
import '../data/models/grid_bot.dart';
import 'bot_add_investment_sheet.dart';
import 'bot_margin_sheet.dart';
import 'bot_stop_sheet.dart';

/// Gear-icon "More" menu (2026-09-18, per the user: "for auto bots and
/// manual bots, i want you to add gear icon per each pair, once it is
/// clicked, it will show page view wrapped menu where user can choose what
/// to do") - matches Pionex's own per-bot "More" bottom sheet (same icons,
/// same grid layout). Scoped to the 3 actions CONFIRMED end-to-end (real
/// submit + immediate re-read against a live bot, not just a dry-run
/// "checkResult: true"): Adjust margin, Add investment, Stop.
///
/// Take Profit / Stop Loss removed from this menu 2026-09-18, same day,
/// after the user reported a real attempt silently didn't work: confirmed
/// live that `adjustParams` accepts `profitStopType`/`profitStop`/
/// `stopProfitEnabled` (and the loss-side equivalents), always answers
/// `result: true, data: "success"`, but the bot's own stored
/// `profitStop`/`stopProfitEnabled` never actually change - re-read
/// immediately and again 45s later, both unchanged. Ruled out an async
/// settlement delay (unlike the P&L-settlement bug from the day before,
/// this genuinely never changes, ever). Tried omitting `top`/`bottom`/
/// `row` (rejected outright - they're required), pairing with
/// `extraMarginAmount: 0` and explicit `disableChangeTp: false` (both
/// still silently no-op), and 7 plausible alternate `type` values
/// (`set_stop`, `stop_profit`, etc. - all rejected as invalid types, same
/// as the Reduce Investment search the day before). Margin and investment
/// changes through the SAME `adjust_params` call structure DID persist
/// (verified: DOT's real `extraMargin` moved 9.69→10.19, `quoteInvestment`
/// moved 0.31→0.81) - the gap is isolated specifically to the TP/SL
/// fields, not the mechanism itself. Most likely explanation: Pionex
/// gates real TP/SL writes to first-party (web/app) auth only, and a
/// third-party API key's write is silently accepted but dropped rather
/// than rejected. The sheet itself (`bot_tp_sl_sheet.dart`) is left in the
/// codebase, unwired, in case a working mechanism is found later - same
/// "omit rather than ship broken" call as Reduce Investment.
Future<void> showBotActionsMenu(BuildContext context, {required GridBot bot}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => _BotActionsMenu(bot: bot, callerContext: context),
  );
}

/// The Auto cards' "more" button (2026-11-12, per the user): three
/// horizontal dots that open a dropdown list - not the bottom sheet - with
/// the same actions as [showBotActionsMenu].
class BotMoreMenuButton extends StatelessWidget {
  const BotMoreMenuButton({super.key, required this.bot});

  final GridBot bot;

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(Icons.more_horiz, size: 20),
      padding: EdgeInsets.zero,
      onSelected: (v) {
        switch (v) {
          case 'margin':
            showAdjustMarginSheet(context, bot: bot);
          case 'invest':
            showAddInvestmentSheet(context, bot: bot);
          case 'stop':
            showStopBotSheet(context, bot: bot);
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'margin',
          child: Row(
            children: [
              Icon(Icons.shield_outlined, size: 20),
              SizedBox(width: 10),
              Text('Adjust margin'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'invest',
          child: Row(
            children: [
              Icon(Icons.add_circle_outline, size: 20),
              SizedBox(width: 10),
              Text('Add investment'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'stop',
          child: Row(
            children: [
              Icon(Icons.power_settings_new, size: 20, color: error),
              const SizedBox(width: 10),
              Text('Stop', style: TextStyle(color: error)),
            ],
          ),
        ),
      ],
    );
  }
}

class _BotActionsMenu extends StatelessWidget {
  const _BotActionsMenu({required this.bot, required this.callerContext});

  final GridBot bot;

  /// The screen's own context (e.g. the row that opened this menu) -
  /// deliberately NOT this widget's own `build(context)` context, which
  /// unmounts the instant this sheet pops itself. Reopening the next sheet
  /// against the caller's still-mounted context is what lets one tap close
  /// this menu and open, say, the Take Profit sheet right after.
  final BuildContext callerContext;

  void _openThen(BuildContext context, Future<void> Function(BuildContext) open) {
    Navigator.of(context).pop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (callerContext.mounted) open(callerContext);
    });
  }

  @override
  Widget build(BuildContext context) {
    final items = <_MenuItem>[
      _MenuItem(
        icon: Icons.shield_outlined,
        label: 'Adjust margin',
        onTap: (ctx) => showAdjustMarginSheet(ctx, bot: bot),
      ),
      _MenuItem(
        icon: Icons.add_circle_outline,
        label: 'Add investment',
        onTap: (ctx) => showAddInvestmentSheet(ctx, bot: bot),
      ),
      _MenuItem(
        icon: Icons.power_settings_new,
        label: 'Stop',
        color: Theme.of(context).colorScheme.error,
        onTap: (ctx) => showStopBotSheet(ctx, bot: bot),
      ),
    ];
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(CoreSpacing.lg, CoreSpacing.sm, CoreSpacing.lg, CoreSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: CoreSpacing.md),
              decoration: BoxDecoration(
                color: Theme.of(context).dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Text(bot.tickerSymbol, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: CoreSpacing.md),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: CoreSpacing.md,
              children: [
                for (final item in items)
                  InkWell(
                    onTap: () => _openThen(context, item.onTap),
                    borderRadius: BorderRadius.circular(12),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(item.icon, color: item.color, size: 28),
                        const SizedBox(height: CoreSpacing.xs),
                        Text(
                          item.label,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: item.color),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: CoreSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuItem {
  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final Color? color;
  final Future<void> Function(BuildContext) onTap;
}
