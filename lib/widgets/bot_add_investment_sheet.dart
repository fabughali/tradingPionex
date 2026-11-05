import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/core_spacing.dart';
import '../data/models/grid_bot.dart';
import '../data/providers/app_providers.dart';
import '../utilities/util_string.dart';
import 'reuse_button.dart';

/// Add investment sheet (2026-09-18, per the user, matching Pionex's own
/// "Add investment" screen) - "Instant" mode only for now (confirmed live:
/// `type: invest_in` with a positive `quoteInvestment`). Pionex's own
/// "Price" tab (triggered add via `invest_in_trigger`) is a separate,
/// more complex conditional-order mechanism not yet verified - left out
/// rather than shipping a guessed request shape for a real-money action.
Future<void> showAddInvestmentSheet(BuildContext context, {required GridBot bot}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _AddInvestmentSheet(bot: bot),
  );
}

class _AddInvestmentSheet extends ConsumerStatefulWidget {
  const _AddInvestmentSheet({required this.bot});

  final GridBot bot;

  @override
  ConsumerState<_AddInvestmentSheet> createState() => _AddInvestmentSheetState();
}

class _AddInvestmentSheetState extends ConsumerState<_AddInvestmentSheet> {
  final _amountController = TextEditingController();
  bool _busy = false;
  String? _error;

  GridBot get bot => widget.bot;

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final repo = ref.read(controlRepositoryProvider);
    final parsed = double.tryParse(_amountController.text.trim());
    if (parsed == null || parsed <= 0) {
      setState(() => _error = 'Enter an amount greater than 0.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final check = await repo.checkAddInvestment(bot: bot, quoteInvestment: parsed);
      if (check['checkResult'] != true) {
        setState(() {
          _error = 'Pionex refused this: ${check['reason'] ?? 'unknown reason'}';
          _busy = false;
        });
        return;
      }
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Confirm add investment'),
          content: Text('${bot.pairKey}: add ${UtilString.usd(parsed)} to this bot\'s investment?'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Confirm')),
          ],
        ),
      );
      if (confirmed != true) {
        setState(() => _busy = false);
        return;
      }
      await repo.addInvestment(bot: bot, quoteInvestment: parsed);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Investment added for ${bot.pairKey}.')),
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
    return SafeArea(
      child: Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.88),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: EdgeInsets.only(
          left: CoreSpacing.lg,
          right: CoreSpacing.lg,
          top: CoreSpacing.sm,
          bottom: MediaQuery.of(context).viewInsets.bottom + CoreSpacing.lg,
        ),
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
            Text('Add investment ${bot.tickerSymbol}', style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
            const SizedBox(height: CoreSpacing.md),
            TextField(
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
              decoration: const InputDecoration(
                labelText: 'Investment (USDT)',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: CoreSpacing.md),
            _InfoRow(label: 'Last Price', value: bot.currentPrice == null ? '—' : UtilString.price(bot.currentPrice!)),
            _InfoRow(
              label: 'Current investment',
              value: bot.actualInvestment == null ? '—' : UtilString.usd(bot.actualInvestment!),
            ),
            if (_error != null) ...[
              const SizedBox(height: CoreSpacing.sm),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: CoreSpacing.md),
            Row(
              children: [
                Expanded(
                  child: ReuseButton(
                    label: 'Cancel',
                    tone: ReuseButtonTone.neutral,
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: CoreSpacing.sm),
                Expanded(
                  child: ReuseButton(label: 'Confirm', loading: _busy, onPressed: _submit),
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
