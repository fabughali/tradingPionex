import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/core_spacing.dart';
import '../data/control/engine_control_repository.dart';
import '../data/models/grid_bot.dart';
import '../data/providers/app_providers.dart';
import '../utilities/util_string.dart';
import 'reuse_button.dart';

/// Stop confirmation from the gear menu (2026-09-18, per the user - matches
/// Pionex's own "Stop" confirmation dialog). Routes through
/// [EngineControlRepository.stopSelected] for an app-initiated bot (same
/// path/bookkeeping the existing bulk-Stop button already uses) or
/// [EngineControlRepository.stopManualBotExplicit] for a manual one -
/// picked automatically from [GridBot.appInitiated], since the user
/// explicitly asked for this menu on both auto AND manual bots.
Future<void> showStopBotSheet(BuildContext context, {required GridBot bot}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _StopBotSheet(bot: bot),
  );
}

class _StopBotSheet extends ConsumerStatefulWidget {
  const _StopBotSheet({required this.bot});

  final GridBot bot;

  @override
  ConsumerState<_StopBotSheet> createState() => _StopBotSheetState();
}

class _StopBotSheetState extends ConsumerState<_StopBotSheet> {
  bool _busy = false;
  String? _error;

  GridBot get bot => widget.bot;

  Future<void> _confirm() async {
    final repo = ref.read(controlRepositoryProvider);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (bot.appInitiated) {
        await repo.stopSelected([bot.buOrderId]);
      } else {
        await repo.stopManualBotExplicit(bot);
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${bot.pairKey} stopped.')),
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
    final pnl = bot.profitAmount;
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
            Text('Stop ${bot.tickerSymbol}', style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
            const SizedBox(height: CoreSpacing.md),
            Text(
              'Are you sure you want to terminate the futures grid trading strategy for ${bot.pairKey}? '
              'After stopping, all pending orders will be cancelled and positions will be closed at the best market price.',
            ),
            const SizedBox(height: CoreSpacing.md),
            _InfoRow(label: 'Current PnL', value: pnl == null ? '—' : UtilString.usd(pnl)),
            if (_error != null) ...[
              const SizedBox(height: CoreSpacing.sm),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: CoreSpacing.md),
            Row(
              children: [
                Expanded(
                  child: ReuseButton(
                    label: 'Discard',
                    tone: ReuseButtonTone.neutral,
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: CoreSpacing.sm),
                Expanded(
                  child: ReuseButton(
                    label: 'Confirm',
                    tone: ReuseButtonTone.danger,
                    loading: _busy,
                    onPressed: _confirm,
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

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          Text(value, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}
