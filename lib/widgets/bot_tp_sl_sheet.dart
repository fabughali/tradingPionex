import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/core_spacing.dart';
import '../data/models/grid_bot.dart';
import '../data/providers/app_providers.dart';
import '../utilities/util_string.dart';
import 'reuse_button.dart';

enum _TpSlInputMode { price, pnl, pnlPercent }

/// Take Profit / Stop Loss sheet (2026-09-18, per the user's own detailed
/// spec, matched against Pionex's real screens): 3 input modes (Price/
/// PnL/PnL%), sign-convention validation that mirrors Pionex's own app
/// (confirmed live the API itself does NOT enforce this - every value
/// tried was accepted - so it's replicated here client-side to match the
/// UX the user described and is used to). Shared between Take Profit and
/// Stop Loss since the two screens are structurally identical - only the
/// sign rules and field names differ.
Future<void> showTpSlSheet(
  BuildContext context, {
  required GridBot bot,
  required bool isTakeProfit,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _TpSlSheet(bot: bot, isTakeProfit: isTakeProfit),
  );
}

class _TpSlSheet extends ConsumerStatefulWidget {
  const _TpSlSheet({required this.bot, required this.isTakeProfit});

  final GridBot bot;
  final bool isTakeProfit;

  @override
  ConsumerState<_TpSlSheet> createState() => _TpSlSheetState();
}

class _TpSlSheetState extends ConsumerState<_TpSlSheet> {
  _TpSlInputMode _mode = _TpSlInputMode.pnlPercent;
  final _valueController = TextEditingController();
  bool _delayEnabled = false;
  final _delayController = TextEditingController(text: '5');
  bool _busy = false;
  String? _error;

  GridBot get bot => widget.bot;
  bool get isTp => widget.isTakeProfit;

  /// Current P/L, matching what [GridsTable]'s own P&L column already
  /// shows - the same real basis Pionex's app itself displays this
  /// screen's rules against.
  double get _currentRatio => (bot.profitPercent ?? 0) / 100;
  double get _currentAmount => bot.profitAmount ?? 0;

  bool get _long => bot.trend != GridDirection.short;

  @override
  void dispose() {
    _valueController.dispose();
    _delayController.dispose();
    super.dispose();
  }

  /// Sign-convention validation per the user's own spec: TP is always a
  /// plain positive magnitude in the "good" direction. SL must always sit
  /// strictly further from breakeven than the bot's CURRENT P/L - positive
  /// (but less than current) while in profit, negative (but more negative
  /// than current) once in loss. Price mode instead compares against the
  /// bot's own direction (long: TP above/SL below current price; short:
  /// reversed) - the user's own wording ("TP more than current, SL less
  /// than current") matches exactly for the long bot they were looking at;
  /// generalized here for short too.
  String? _validate(double value) {
    switch (_mode) {
      case _TpSlInputMode.price:
        final top = bot.top, bottom = bot.bottom, price = bot.currentPrice;
        if (top != null && bottom != null && (value > top || value < bottom)) {
          return 'Must be within the grid range (${UtilString.price(bottom)}–${UtilString.price(top)}).';
        }
        if (price != null) {
          final wantsAbove = isTp ? _long : !_long;
          if (wantsAbove && value <= price) {
            return 'Must be above the current price (${UtilString.price(price)}).';
          }
          if (!wantsAbove && value >= price) {
            return 'Must be below the current price (${UtilString.price(price)}).';
          }
        }
        return null;
      case _TpSlInputMode.pnl:
        if (isTp) {
          if (value <= 0) return 'Take profit must be a positive amount.';
          return null;
        }
        if (_currentAmount >= 0) {
          if (value <= 0) {
            return 'Bot is currently in profit (+${UtilString.usd(_currentAmount)}) - stop loss must be a positive amount less than that.';
          }
          if (value >= _currentAmount) {
            return 'Must be less than the current profit (${UtilString.usd(_currentAmount)}).';
          }
        } else {
          if (value >= 0) {
            return 'Bot is currently at a loss (${UtilString.usd(_currentAmount)}) - stop loss must be a negative amount, further down than that.';
          }
          if (value <= _currentAmount) {
            return 'Must be less negative loss than the current one (${UtilString.usd(_currentAmount)}) - i.e. a smaller magnitude.';
          }
        }
        return null;
      case _TpSlInputMode.pnlPercent:
        if (isTp) {
          if (value <= 0) return 'Take profit must be a positive percentage.';
          return null;
        }
        if (_currentRatio >= 0) {
          if (value <= 0) {
            return 'Bot is currently in profit (+${(_currentRatio * 100).toStringAsFixed(2)}%) - stop loss must be positive and less than that.';
          }
          if (value >= _currentRatio) {
            return 'Must be less than the current profit ratio (${(_currentRatio * 100).toStringAsFixed(2)}%).';
          }
        } else {
          if (value >= 0) {
            return 'Bot is currently at a loss (${(_currentRatio * 100).toStringAsFixed(2)}%) - stop loss must be negative.';
          }
          if (value <= _currentRatio) {
            return 'Must be a smaller-magnitude loss than the current one (${(_currentRatio * 100).toStringAsFixed(2)}%).';
          }
        }
        return null;
    }
  }

  Map<String, String?> _fields(double value) {
    final type = switch (_mode) {
      _TpSlInputMode.price => 'price',
      _TpSlInputMode.pnl => 'profit_amount',
      _TpSlInputMode.pnlPercent => 'profit_ratio',
    };
    final raw = switch (_mode) {
      _TpSlInputMode.price => value.toString(),
      _TpSlInputMode.pnl => value.toString(),
      _TpSlInputMode.pnlPercent => (value / 100).toString(),
    };
    return {'type': type, 'raw': raw};
  }

  Future<void> _submit({required bool enable}) async {
    final repo = ref.read(controlRepositoryProvider);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      String? type;
      String? raw;
      if (enable) {
        final parsed = double.tryParse(_valueController.text.trim());
        if (parsed == null) {
          setState(() {
            _error = 'Enter a value.';
            _busy = false;
          });
          return;
        }
        final validation = _validate(parsed);
        if (validation != null) {
          setState(() {
            _error = validation;
            _busy = false;
          });
          return;
        }
        final f = _fields(parsed);
        type = f['type'];
        raw = f['raw'];
      }
      final delaySec = _delayEnabled
          ? int.tryParse(_delayController.text.trim())
          : null;
      final check = await (isTp
          ? repo.checkAdjustTpSl(
              bot: bot,
              profitStopType: enable ? type : null,
              profitStop: enable ? raw : null,
              stopProfitEnabled: enable,
            )
          : repo.checkAdjustTpSl(
              bot: bot,
              lossStopType: enable ? type : null,
              lossStop: enable ? raw : null,
              stopLossEnabled: enable,
            ));
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
          title: Text(enable ? 'Confirm ${isTp ? 'Take Profit' : 'Stop Loss'}' : 'Cancel ${isTp ? 'Take Profit' : 'Stop Loss'}'),
          content: Text(
            enable
                ? '${bot.pairKey}: set ${isTp ? 'take profit' : 'stop loss'} to $raw ($type)${delaySec != null ? ', $delaySec s delay' : ''}?'
                : '${bot.pairKey}: turn off the current ${isTp ? 'take profit' : 'stop loss'} setting?',
          ),
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
      await (isTp
          ? repo.adjustTpSl(
              bot: bot,
              profitStopType: enable ? type : null,
              profitStop: enable ? raw : null,
              stopProfitEnabled: enable,
            )
          : repo.adjustTpSl(
              bot: bot,
              lossStopType: enable ? type : null,
              lossStop: enable ? raw : null,
              stopLossEnabled: enable,
            ));
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${isTp ? 'Take profit' : 'Stop loss'} updated for ${bot.pairKey}.')),
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
    final title = isTp ? 'Take Profit' : 'Stop Loss';
    final currentlyEnabled = isTp ? bot.stopProfitEnabled : bot.stopLossEnabled;
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
            Text('$title ${bot.tickerSymbol}', style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
            const SizedBox(height: CoreSpacing.md),
            SegmentedButton<_TpSlInputMode>(
              segments: const [
                ButtonSegment(value: _TpSlInputMode.price, label: Text('Price')),
                ButtonSegment(value: _TpSlInputMode.pnl, label: Text('PnL')),
                ButtonSegment(value: _TpSlInputMode.pnlPercent, label: Text('PnL%')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() {
                _mode = s.first;
                _error = null;
              }),
            ),
            const SizedBox(height: CoreSpacing.md),
            TextField(
              controller: _valueController,
              keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
              decoration: InputDecoration(
                labelText: switch (_mode) {
                  _TpSlInputMode.price => '$title Trigger Price (USDT)',
                  _TpSlInputMode.pnl => 'Profit/loss trigger value (USDT)',
                  _TpSlInputMode.pnlPercent => 'Profit/loss ratio trigger (%)',
                },
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: CoreSpacing.sm),
            Text(
              'Tip: the profit/loss trigger does not deduct the closing fee - the actual result will be slightly '
              '${isTp ? 'lower' : 'higher'} than this setting.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: CoreSpacing.md),
            Row(
              children: [
                Expanded(child: Text('$title delay', style: Theme.of(context).textTheme.bodyMedium)),
                Switch(
                  value: _delayEnabled,
                  onChanged: (v) => setState(() => _delayEnabled = v),
                ),
              ],
            ),
            if (_delayEnabled)
              TextField(
                controller: _delayController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Delay time (sec, 5-30)',
                  border: OutlineInputBorder(),
                ),
              ),
            const SizedBox(height: CoreSpacing.md),
            _InfoRow(label: 'Last Price', value: bot.currentPrice == null ? '—' : UtilString.price(bot.currentPrice!)),
            _InfoRow(
              label: 'Price range',
              value: (bot.bottom == null || bot.top == null) ? '—' : '${UtilString.price(bot.bottom!)}-${UtilString.price(bot.top!)}',
            ),
            _InfoRow(
              label: 'Est. Liq. Price',
              value: (bot.liquidationPrice == null || bot.liquidationPrice == 0) ? '—' : UtilString.price(bot.liquidationPrice!),
            ),
            _InfoRow(label: 'Break-even Price', value: bot.entryPrice == null ? '—' : UtilString.price(bot.entryPrice!)),
            if (_error != null) ...[
              const SizedBox(height: CoreSpacing.sm),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            if (currentlyEnabled) ...[
              const SizedBox(height: CoreSpacing.md),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _busy ? null : () => _submit(enable: false),
                  child: const Text('Cancel current settings'),
                ),
              ),
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
                    onPressed: () => _submit(enable: true),
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
