import 'dart:io';

import 'package:trading_pionex/data/technique/worm10_decision.dart';
import 'package:trading_pionex/data/tradingview/cdp_client.dart';
import 'package:trading_pionex/data/tradingview/chart_state.dart';
import 'package:trading_pionex/data/tradingview/signals_reader.dart';

// Read-only check of the Worm10 reader against the chart as it stands: never
// switches symbol or changes anything, and never touches Pionex.
// Usage: dart run tool/worm10_check.dart [port]   (default 9222)
Future<void> main(List<String> args) async {
  final port = args.isEmpty ? 9222 : int.parse(args.first);
  final cdp = await connectToChart('127.0.0.1', port);
  final state = await getChartState(cdp);
  final symbol = state.symbol;
  print('chart: $symbol ${state.resolution}');
  if (symbol == null) exit(1);

  final check = await readWorm10Bars(
    cdp,
    symbol,
    customScripts[0].scriptIdPart,
    customScripts[1].scriptIdPart,
    onDebugError: (msg) => print('reader error: $msg'),
  );
  print('bars: ${check.bars.length}  latest bar: ${_at(check.latestBarTime)}');

  final zones = <String?, int>{};
  for (final b in check.bars) {
    zones[b.rsiZone] = (zones[b.rsiZone] ?? 0) + 1;
  }
  print('RSI zones: $zones');
  for (final b in check.bars.skip(check.bars.length > 5 ? check.bars.length - 5 : 0)) {
    print(
      '  ${_at(b.time)} zone=${b.rsiZone} hh=${b.hh} ll=${b.ll} '
      'BUY=${b.zigzagBuy} SELL=${b.zigzagSell} stBuy=${b.stBuy} stSell=${b.stSell}',
    );
  }

  final events = deriveWorm10Events(check.bars);
  print('events: ${events.length}, newest last:');
  for (final e in events.skip(events.length > 8 ? events.length - 8 : 0)) {
    print('  ${e.type.name} @ ${_at(e.time)}');
  }

  final wrong = await readWorm10Bars(
    cdp,
    'NOTTHISSYMBOLUSDT',
    customScripts[0].scriptIdPart,
    customScripts[1].scriptIdPart,
    onDebugError: (msg) => print('guard refused as expected: $msg'),
  );
  print('wrong-symbol read returned ${wrong.bars.length} bars (must be 0)');
  exit(0);
}

String _at(int? sec) => sec == null
    ? 'none'
    : DateTime.fromMillisecondsSinceEpoch(sec * 1000, isUtc: true)
          .toIso8601String()
          .substring(0, 16);
