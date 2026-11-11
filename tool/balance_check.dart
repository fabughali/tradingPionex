import 'dart:io';

import 'package:trading_pionex/core/core_storage.dart';
import 'package:trading_pionex/data/pionex/pionex_client.dart';

// Prints what Pionex returns for USDT in /api/v1/account/balances (amounts
// only - never keys). Usage: dart run tool/balance_check.dart
Future<void> main() async {
  final storage = CoreStorage.instance;
  final env = storage.readEnvFile();
  final pionex = PionexClient(
    apiKey: env['PIONEX_API_KEY'] ?? '',
    apiSecret: env['PIONEX_API_SECRET'] ?? '',
    onLog: (_) {},
  );
  for (final b in await pionex.getBalances()) {
    final coin = '${b['coin'] ?? b['symbol']}';
    if (coin == 'USDT') stdout.writeln('USDT raw: $b');
  }
  final bal = await pionex.getBalance('USDT');
  stdout.writeln('app reads: free=${bal.free} total=${bal.total}');
  pionex.close();
  exit(0);
}
