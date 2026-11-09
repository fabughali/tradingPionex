import 'dart:io';

import 'package:trading_pionex/core/core_storage.dart';
import 'package:trading_pionex/data/identity/created_bots_store.dart';
import 'package:trading_pionex/data/pionex/pionex_client.dart';

// Live check of the SLL $ SL trigger (`profit_amount` through
// updateTriggerProfitLoss) on ONE running Auto bot: reads its SL, sets a
// -$100 $ SL (cannot fire on a small bot), reads it back from Pionex, then
// sets the SL back to blank and reads it again. Never prints keys.
// Usage: dart run tool/sll_dollar_trigger_check.dart
Future<void> main() async {
  final storage = CoreStorage.instance;
  final env = storage.readEnvFile();
  final pionex = PionexClient(
    apiKey: env['PIONEX_API_KEY'] ?? '',
    apiSecret: env['PIONEX_API_SECRET'] ?? '',
    onLog: (_) {},
  );
  final created = CreatedBotsStore(storage)..load();
  Map<String, dynamic>? target;
  for (final o in await pionex.getActiveGrids()) {
    final id = '${o['buOrderId']}';
    if (created.isAppInitiated(id)) {
      target = o;
      break;
    }
  }
  if (target == null) {
    stdout.writeln('No running Auto bot found.');
    exit(1);
  }
  final id = '${target['buOrderId']}';

  Future<void> show(String label) async {
    final o = await pionex.getBotOrderByBuOrderId(id);
    final d = (o?['buOrderData'] as Map?) ?? const {};
    stdout.writeln(
      '$label: base=${o?['base']} lossStopType=${d['lossStopType']} '
      'lossStop=${d['lossStop']} profitStopType=${d['profitStopType']} '
      'profitStop=${d['profitStop']}',
    );
  }

  stdout.writeln('Bot $id');
  await show('BEFORE');
  final set = await pionex.updateTriggerProfitLoss(
    buOrderId: id,
    lossStopType: 'profit_amount',
    lossStopValue: '-100',
  );
  stdout.writeln('SET \$-100 response: $set');
  await Future<void>.delayed(const Duration(seconds: 3));
  await show('AFTER SET');
  final clear = await pionex.updateTriggerProfitLoss(
    buOrderId: id,
    lossStopType: 'profit_amount',
    lossStopValue: '',
  );
  stdout.writeln('CLEAR response: $clear');
  await Future<void>.delayed(const Duration(seconds: 3));
  await show('AFTER CLEAR');
  pionex.close();
  exit(0);
}
