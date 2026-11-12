import 'dart:io';

import 'package:trading_pionex/core/core_storage.dart';
import 'package:trading_pionex/data/models/grid_bot.dart';
import 'package:trading_pionex/data/pionex/pionex_client.dart';

// Prints, per running bot, Pionex's money fields and what the app computes,
// to check the dashboard's "Pionex balance" (wallet) sum. Amounts only -
// never keys. Usage: dart run tool/wallet_check.dart
Future<void> main() async {
  final storage = CoreStorage.instance;
  final env = storage.readEnvFile();
  final pionex = PionexClient(
    apiKey: env['PIONEX_API_KEY'] ?? '',
    apiSecret: env['PIONEX_API_SECRET'] ?? '',
    onLog: (_) {},
  );
  final bal = await pionex.getBalance('USDT');
  stdout.writeln('trading account: free=${bal.free} total=${bal.total}');
  var appSum = bal.total > bal.free ? bal.total : bal.free;
  for (final raw in await pionex.getActiveGrids()) {
    final data = (raw['buOrderData'] as Map?)?.cast<String, dynamic>() ?? {};
    final base = '${raw['base']}'.replaceAll('.PERP', '');
    final price = await pionex.getTickerPrice('${base}_USDT_PERP');
    final bot = GridBot.fromPionexOrder(raw, appInitiated: true)
        .copyWith(currentPrice: price);
    final money = bot.marginBalance ??
        ((bot.actualInvestment ?? 0) + (bot.extraMargin ?? 0));
    appSum += money + (bot.profitAmount ?? 0);
    stdout.writeln(
      '$base: initial=${bot.initialInvestment} actual=${bot.actualInvestment} '
      'extra=${bot.extraMargin} profit=${bot.profitAmount}',
    );
    final moneyKeys = data.keys.where(
      (k) => RegExp(
        r'invest|margin|balance|equity|value|profit|usdt|amount',
        caseSensitive: false,
      ).hasMatch(k),
    );
    stdout.writeln('  raw: ${{for (final k in moneyKeys) k: data[k]}}');
  }
  stdout.writeln('app wallet sum: $appSum');
  pionex.close();
  exit(0);
}
