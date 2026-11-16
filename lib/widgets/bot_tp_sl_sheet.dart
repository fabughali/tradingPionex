import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/core_spacing.dart';
import '../data/models/grid_bot.dart';
import '../data/providers/app_providers.dart';
import '../utilities/util_string.dart';
import 'reuse_button.dart';

enum TpSlMode { pnlPercent, pnlUsd, price }

/// Manual TP/SL (2026-11-16, per the user): set from the card's More menu,
/// in one of three ways. Setting either side turns SLL off for this trade;
/// clearing both hands it back to SLL.
Future<void> showTpSlSheet(BuildContext context, {required GridBot bot}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _TpSlSheet(bot: bot),
  );
}

/// The user's rules, checked against the bot's live figures. Returns an
/// error message, or null when [value] is allowed.
///
/// - P&L %: TP above the current P&L %, SL below it (either may be negative).
/// - P&L $: TP above the current P&L $, SL below it.
/// - Price: long - TP above the current price, SL below; short - opposite.
String? validateTpSl({
  required TpSlMode mode,
  required bool isTakeProfit,
  required double value,
  required bool long,
  double? currentPnlPercent,
  double? currentPnlUsd,
  double? currentPrice,
}) {
  final side = isTakeProfit ? 'TP' : 'SL';
  switch (mode) {
    case TpSlMode.pnlPercent:
      final now = currentPnlPercent;
      if (now == null) return 'Current P&L % is not known yet.';
      if (isTakeProfit && value <= now) {
        return '$side must be more than the current P&L (${now.toStringAsFixed(2)}%).';
      }
      if (!isTakeProfit && value >= now) {
        return '$side must be less than the current P&L (${now.toStringAsFixed(2)}%).';
      }
    case TpSlMode.pnlUsd:
      final now = currentPnlUsd;
      if (now == null) return 'Current P&L \$ is not known yet.';
      if (isTakeProfit && value <= now) {
        return '$side must be more than the current P&L (${UtilString.usd(now)}).';
      }
      if (!isTakeProfit && value >= now) {
        return '$side must be less than the current P&L (${UtilString.usd(now)}).';
      }
    case TpSlMode.price:
      final now = currentPrice;
      if (now == null) return 'Current price is not known yet.';
      if (value <= 0) return '$side price must be above 0.';
      final above = isTakeProfit == long;
      if (above && value <= now) {
        return '$side must be above the current price (${UtilString.price(now)}).';
      }
      if (!above && value >= now) {
        return '$side must be below the current price (${UtilString.price(now)}).';
      }
  }
  return null;
}

class _TpSlSheet extends ConsumerStatefulWidget {
  const _TpSlSheet({required this.bot});

  final GridBot bot;

  @override
  ConsumerState<_TpSlSheet> createState() => _TpSlSheetState();
}

class _TpSlSheetState extends ConsumerState<_TpSlSheet> {
  TpSlMode _mode = TpSlMode.pnlPercent;
  final _tp = TextEditingController();
  final _sl = TextEditingController();
  bool _busy = false;
  String? _error;

  GridBot get bot => widget.bot;
  bool get _long => bot.trend != GridDirection.short;

  @override
  void dispose() {
    _tp.dispose();
    _sl.dispose();
    super.dispose();
  }

  String get _unit => switch (_mode) {
    TpSlMode.pnlPercent => '%',
    TpSlMode.pnlUsd => 'USDT',
    TpSlMode.price => 'USDT price',
  };

  String get _stopType => switch (_mode) {
    TpSlMode.pnlPercent => 'profit_ratio',
    TpSlMode.pnlUsd => 'profit_amount',
    TpSlMode.price => 'price',
  };

  /// What Pionex receives: a ratio for %, the plain number otherwise.
  String _wire(double v) =>
      _mode == TpSlMode.pnlPercent ? '${v / 100}' : '$v';

  Future<void> _submit() async {
    final tpText = _tp.text.trim();
    final slText = _sl.text.trim();
    double? tp;
    double? sl;
    if (tpText.isNotEmpty) {
      tp = double.tryParse(tpText);
      if (tp == null) return setState(() => _error = 'TP is not a number.');
    }
    if (slText.isNotEmpty) {
      sl = double.tryParse(slText);
      if (sl == null) return setState(() => _error = 'SL is not a number.');
    }
    for (final (value, isTp) in [(tp, true), (sl, false)]) {
      if (value == null) continue;
      final error = validateTpSl(
        mode: _mode,
        isTakeProfit: isTp,
        value: value,
        long: _long,
        currentPnlPercent: bot.profitPercent,
        currentPnlUsd: bot.profitAmount,
        currentPrice: bot.currentPrice,
      );
      if (error != null) return setState(() => _error = error);
    }
    final summary = (tp == null && sl == null)
        ? 'Clear TP and SL on ${bot.pairKey}. SLL takes this trade back.'
        : '${bot.pairKey}\n'
              'TP: ${tp == null ? 'blank' : '$tp $_unit'}\n'
              'SL: ${sl == null ? 'blank' : '$sl $_unit'}\n\n'
              'SLL will be off for this trade.';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Set TP / SL'),
        content: Text(summary),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(controlRepositoryProvider)
          .setManualTpSl(
            bot: bot,
            stopType: _stopType,
            takeProfit: tp == null ? null : _wire(tp),
            stopLoss: sl == null ? null : _wire(sl),
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            (tp == null && sl == null)
                ? 'TP/SL cleared for ${bot.pairKey} - SLL is back on.'
                : 'TP/SL set for ${bot.pairKey} - SLL is off for this trade.',
          ),
        ),
      );
    } catch (e) {
      setState(() {
        _error = 'Pionex refused it: $e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pct = bot.profitPercent;
    final usd = bot.profitAmount;
    final now = switch (_mode) {
      TpSlMode.pnlPercent =>
        pct == null ? '—' : '${pct.toStringAsFixed(2)}%',
      TpSlMode.pnlUsd => usd == null ? '—' : UtilString.usd(usd),
      TpSlMode.price =>
        bot.currentPrice == null ? '—' : UtilString.price(bot.currentPrice!),
    };
    final (tpHint, slHint) = switch (_mode) {
      TpSlMode.pnlPercent => ('more than $now', 'less than $now'),
      TpSlMode.pnlUsd => ('more than $now', 'less than $now'),
      TpSlMode.price =>
        _long
            ? ('above $now', 'below $now')
            : ('below $now', 'above $now'),
    };
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: EdgeInsets.only(
          left: CoreSpacing.lg,
          right: CoreSpacing.lg,
          top: CoreSpacing.md,
          bottom: MediaQuery.of(context).viewInsets.bottom + CoreSpacing.lg,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'TP / SL  ${bot.pairKey} ${_long ? 'LONG' : 'SHORT'}',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: CoreSpacing.md),
              SegmentedButton<TpSlMode>(
                segments: const [
                  ButtonSegment(value: TpSlMode.pnlPercent, label: Text('P&L %')),
                  ButtonSegment(value: TpSlMode.pnlUsd, label: Text('P&L \$')),
                  ButtonSegment(value: TpSlMode.price, label: Text('Price')),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() {
                  _mode = s.first;
                  _error = null;
                }),
              ),
              const SizedBox(height: CoreSpacing.sm),
              Text(
                'Now: $now',
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: CoreSpacing.md),
              TextField(
                controller: _tp,
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Take profit ($_unit)',
                  helperText: '$tpHint - leave blank for none',
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() => _error = null),
              ),
              const SizedBox(height: CoreSpacing.md),
              TextField(
                controller: _sl,
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Stop loss ($_unit)',
                  helperText: '$slHint - leave blank for none',
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() => _error = null),
              ),
              const SizedBox(height: CoreSpacing.sm),
              Text(
                'Setting TP or SL turns SLL off for this trade. Leave both '
                'blank to clear them and give the trade back to SLL.',
                style: theme.textTheme.bodySmall,
              ),
              if (_error != null) ...[
                const SizedBox(height: CoreSpacing.sm),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
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
                    child: ReuseButton(
                      label: 'Confirm',
                      loading: _busy,
                      onPressed: _busy ? null : _submit,
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
