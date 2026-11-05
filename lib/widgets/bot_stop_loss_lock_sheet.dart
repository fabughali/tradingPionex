import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/core_spacing.dart';
import '../data/control/engine_control_repository.dart';
import '../data/models/auto_category.dart';
import '../data/models/grid_bot.dart';
import '../data/providers/app_providers.dart';
import 'reuse_button.dart';

/// "Stop Loss Lock" toggle from the gear menu (2026-09-22, per the user's
/// exact spec): tags/untags one bot for the Stop Loss Lock engine, which
/// takes over as the sole stop-loss authority for that pair once floating
/// P&L clears +100% (below that the normal flat -50% baseline SL still
/// leads, untouched). Auto bots resolve their own timeframe automatically
/// (the category they're already running under); a manual bot has no
/// inherent category, so enabling one asks which chart timeframe to watch.
Future<void> showStopLossLockSheet(
  BuildContext context, {
  required GridBot bot,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _StopLossLockSheet(bot: bot),
  );
}

class _StopLossLockSheet extends ConsumerStatefulWidget {
  const _StopLossLockSheet({required this.bot});

  final GridBot bot;

  @override
  ConsumerState<_StopLossLockSheet> createState() => _StopLossLockSheetState();
}

class _StopLossLockSheetState extends ConsumerState<_StopLossLockSheet> {
  bool _busy = false;
  String? _error;
  AutoCategory _manualCategory = AutoCategory.oneHour;

  GridBot get bot => widget.bot;

  bool _isTagged(EngineControlRepository repo) {
    if (bot.appInitiated) {
      final category = repo.botCategories.categoryOf(bot.buOrderId) ?? AutoCategory.oneHour;
      final bareBase = bot.base
          .toUpperCase()
          .replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '');
      return repo.stopLossLock.isTaggedAuto(bareBase, category);
    }
    return repo.stopLossLock.manualCategory(bot.buOrderId) != null;
  }

  Future<void> _toggle(EngineControlRepository repo, {required bool enable}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await repo.stopLossLockSelect(
        [bot.buOrderId],
        enable: enable,
        manualCategory: bot.appInitiated ? null : _manualCategory,
      );
      if (!mounted) return;
      if (result['ok'] != true) {
        setState(() {
          _error = 'Failed: could not update ${bot.tickerSymbol}.';
          _busy = false;
        });
        return;
      }
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            enable
                ? 'Stop Loss Lock enabled for ${bot.tickerSymbol}.'
                : 'Stop Loss Lock disabled for ${bot.tickerSymbol}.',
          ),
        ),
      );
    } catch (e) {
      setState(() {
        _error = 'Failed: $e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(controlRepositoryProvider);
    final tagged = _isTagged(repo);
    return SafeArea(
      child: Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.88),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(CoreSpacing.lg, CoreSpacing.sm, CoreSpacing.lg, CoreSpacing.lg),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: CoreSpacing.md),
                  decoration: BoxDecoration(
                    color: Theme.of(context).dividerColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                'Stop Loss Lock ${bot.tickerSymbol}',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: CoreSpacing.md),
              Text(
                tagged
                    ? 'Stop Loss Lock is ON for this bot - the normal TP/SL '
                          'ratchet AND the -50% baseline are both disabled, but '
                          'this bot can still be closed by the normal open/close '
                          'signal rule at any time, same as an untagged bot. On '
                          'top of that, this bot has NO extra stop-loss floor '
                          'until P&L clears +100%; above that, a faster (every 3 '
                          'minutes, versus the normal signal read\'s own cadence) '
                          'check locks SL to P&L-10 the moment a reversal signal '
                          'appears - a real safety net that can end the bot '
                          'sooner than waiting for the normal read. Once P&L '
                          'clears +200%, actual investment is rounded up to the '
                          'next whole USDT and SL locks to a flat +100%, then +1 '
                          'USDT is added every 9 minutes for as long as P&L stays '
                          '>=200% and no reversal signal has appeared yet - the '
                          'moment it does, investment additions stop for good and '
                          'only the P&L-10 lock continues.'
                    : 'Once ON, Stop Loss Lock disables the normal TP/SL ratchet '
                          'and the -50% baseline stop-loss for this pair - but the '
                          'bot can still close via the normal open/close signal '
                          'rule at any time, exactly like an untagged bot. It '
                          'also gets NO extra stop-loss floor until P&L clears '
                          '+100%. Once it does, a faster check (every 3 minutes) '
                          'locks the stop-loss to P&L-10 the instant a reversal '
                          'signal appears - genuinely useful even though the '
                          'normal rule can also close the bot, since this check '
                          'runs far more often and can end it sooner. Once P&L '
                          'clears +200%, actual investment is rounded up to the '
                          'next whole USDT and SL locks to a flat +100%, then +1 '
                          'USDT is added every 9 minutes for as long as P&L stays '
                          '>=200% and no reversal signal has appeared - the '
                          'moment it does, investment additions stop for good. '
                          'Untagging restores the -50% baseline only if nothing '
                          'was ever locked - any real locked-in floor is never '
                          'loosened.',
                style: tagged
                    ? null
                    : TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              if (!bot.appInitiated && !tagged) ...[
                const SizedBox(height: CoreSpacing.md),
                Text('Chart timeframe to watch', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: CoreSpacing.xs),
                DropdownButtonFormField<AutoCategory>(
                  initialValue: _manualCategory,
                  items: [
                    for (final c in allAutoCategories)
                      DropdownMenuItem(value: c, child: Text(c.label)),
                  ],
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _manualCategory = v ?? _manualCategory),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: CoreSpacing.sm),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: CoreSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: ReuseButton(
                      label: 'Close',
                      tone: ReuseButtonTone.neutral,
                      onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    ),
                  ),
                  const SizedBox(width: CoreSpacing.sm),
                  Expanded(
                    child: ReuseButton(
                      label: tagged ? 'Disable' : 'Enable',
                      tone: tagged ? ReuseButtonTone.danger : ReuseButtonTone.primary,
                      loading: _busy,
                      onPressed: () => _toggle(repo, enable: !tagged),
                    ),
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
