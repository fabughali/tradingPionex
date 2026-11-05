import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/core_spacing.dart';
import '../data/models/grid_bot.dart';
import '../data/providers/app_providers.dart';
import '../utilities/util_string.dart';
import 'reuse_button.dart';

/// Adjust margin sheet (2026-09-18, per the user, matching Pionex's own
/// "Adjust margin" screen): Add margin / Withdraw margin tabs, confirmed
/// live both directions work via the SAME `adjust_params` call with a
/// signed `extraMarginAmount` (positive = add, negative = withdraw).
Future<void> showAdjustMarginSheet(BuildContext context, {required GridBot bot}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _AdjustMarginSheet(bot: bot),
  );
}

class _AdjustMarginSheet extends ConsumerStatefulWidget {
  const _AdjustMarginSheet({required this.bot});

  final GridBot bot;

  @override
  ConsumerState<_AdjustMarginSheet> createState() => _AdjustMarginSheetState();
}

class _AdjustMarginSheetState extends ConsumerState<_AdjustMarginSheet> {
  bool _isAdd = true;
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
    final signed = _isAdd ? parsed : -parsed;
    if (!_isAdd && bot.extraMargin != null && parsed > bot.extraMargin!) {
      setState(() => _error = 'Only ${UtilString.usd(bot.extraMargin!)} extra margin is available to withdraw.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final check = await repo.checkAdjustMargin(bot: bot, extraMarginAmount: signed);
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
          title: Text(_isAdd ? 'Confirm add margin' : 'Confirm withdraw margin'),
          content: Text('${bot.pairKey}: ${_isAdd ? 'add' : 'withdraw'} ${UtilString.usd(parsed)} margin?'),
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
      await repo.adjustMargin(bot: bot, extraMarginAmount: signed);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Margin ${_isAdd ? 'added' : 'withdrawn'} for ${bot.pairKey}.')),
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
            Text('Adjust margin ${bot.tickerSymbol}', style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
            const SizedBox(height: CoreSpacing.md),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Add margin')),
                ButtonSegment(value: false, label: Text('Withdraw margin')),
              ],
              selected: {_isAdd},
              onSelectionChanged: (s) => setState(() {
                _isAdd = s.first;
                _error = null;
              }),
            ),
            const SizedBox(height: CoreSpacing.sm),
            Text(
              _isAdd
                  ? 'Adding margin will make the Est. Liq price farther away from the market price.'
                  : 'Withdrawing margin will make the Est. Liq price closer to the market price - please be aware of the risks.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: _isAdd ? null : Theme.of(context).colorScheme.error,
              ),
            ),
            const SizedBox(height: CoreSpacing.md),
            TextField(
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
              decoration: InputDecoration(
                labelText: _isAdd ? 'Input additional margin USDT' : 'Input reduced margin USDT',
                border: const OutlineInputBorder(),
                suffixText: (!_isAdd && bot.extraMargin != null) ? 'Max ${bot.extraMargin!.toStringAsFixed(2)}' : null,
              ),
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: CoreSpacing.md),
            _InfoRow(
              label: _isAdd ? 'Available margin' : 'Withdrawable margin',
              value: bot.extraMargin == null ? '—' : UtilString.usd(bot.extraMargin!),
            ),
            _InfoRow(label: 'Current price', value: bot.currentPrice == null ? '—' : UtilString.price(bot.currentPrice!)),
            _InfoRow(
              label: 'Current Est. Liq Price',
              value: (bot.liquidationPrice == null || bot.liquidationPrice == 0) ? '—' : UtilString.price(bot.liquidationPrice!),
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
                  child: ReuseButton(label: 'Submit', loading: _busy, onPressed: _submit),
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
