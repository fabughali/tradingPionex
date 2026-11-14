import 'dart:io';

import 'package:trading_pionex/core/core_storage.dart';
import 'package:trading_pionex/data/models/grid_bot.dart';
import 'package:trading_pionex/data/pionex/pionex_client.dart';

// Prints one bot's money fields as Pionex reports them (amounts only, never
// keys). Read-only. Usage: dart run tool/closed_bot_check.dart <buOrderId>
Future<void> main(List<String> args) async {
  final env = CoreStorage.instance.readEnvFile();
  final pionex = PionexClient(
    apiKey: env['PIONEX_API_KEY'] ?? '',
    apiSecret: env['PIONEX_API_SECRET'] ?? '',
    onLog: (_) {},
  );
  final rec = await pionex.getBotOrderByBuOrderId(args.first);
  if (rec == null) {
    stdout.writeln('not found');
  } else {
    final bot = GridBot.fromPionexOrder(rec, appInitiated: true);
    stdout.writeln(
      'status=${rec['status']} actual=${bot.actualInvestment} '
      'extra=${bot.extraMargin} realized=${bot.totalRealizedProfit} '
      'grid=${bot.gridProfit} fee=${bot.totalFee} profit=${bot.profitAmount} '
      'position=${bot.positionSize}',
    );
  }
  pionex.close();
  exit(0);
}
