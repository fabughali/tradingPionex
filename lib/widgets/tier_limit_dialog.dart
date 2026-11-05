import 'dart:async';

import 'package:flutter/material.dart';

/// Confirms bumping a pair's investment past Pionex's own account-tier
/// minimum (2026-09-16, per the user - confirmed live via Pionex's own
/// "Creation failed" dialog: once an account holds more than 20 total
/// bots, Pionex requires every NEW bot's investment to exceed $50). Shown
/// when the engine refuses an Ignite for exactly this reason.
///
/// Per the user's exact spec: a dialog with OK/Cancel, auto-dismissed as
/// a decline if not answered within 5 seconds (the bot then simply stays
/// in Waiting for its next cycle, same as any other declined/failed
/// attempt - nothing forces the investment change without an explicit,
/// timely yes). Returns true only if OK was pressed inside that window.
Future<bool> showTierLimitInvestmentDialog(
  BuildContext context, {
  required String symbol,
  required int wouldBeBotNumber,
  required double bumpedInvestment,
}) async {
  const timeoutSeconds = 5;
  var remaining = timeoutSeconds;
  Timer? ticker;
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        ticker ??= Timer.periodic(const Duration(seconds: 1), (t) {
          remaining--;
          if (remaining <= 0) {
            t.cancel();
            Navigator.of(context).pop(false);
          } else {
            setState(() {});
          }
        });
        return AlertDialog(
          title: const Text('Investment too low for this account'),
          content: Text(
            '$symbol would be bot #$wouldBeBotNumber on this Pionex account. '
            'Pionex requires investment above \$50 once an account holds more '
            'than 20 bots.\n\n'
            'Set $symbol\'s investment to \$${bumpedInvestment.toStringAsFixed(0)} and open it now?\n\n'
            'Auto-declining in ${remaining}s - it will stay in Waiting.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('OK, use \$${bumpedInvestment.toStringAsFixed(0)}'),
            ),
          ],
        );
      },
    ),
  );
  ticker?.cancel();
  return result ?? false;
}
