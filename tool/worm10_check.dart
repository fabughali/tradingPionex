import 'dart:io';

import 'package:trading_pionex/data/models/signal.dart';
import 'package:trading_pionex/data/technique/worm10_decision.dart';
import 'package:trading_pionex/data/tradingview/cdp_client.dart';
import 'package:trading_pionex/data/tradingview/chart_state.dart';
import 'package:trading_pionex/data/tradingview/signals_reader.dart';

// Read-only check of the Hybrid Decision reader (tradingMT5's
// readWorm10Signals) against this app's own chart tab as it stands: never
// switches symbol or changes anything, and never touches Pionex.
// Usage: dart run tool/worm10_check.dart [port]   (default 9222)
Future<void> main(List<String> args) async {
  final port = args.isEmpty ? 9222 : int.parse(args.first);
  final cdp = await connectToChart('127.0.0.1', port);
  final state = await getChartState(cdp);
  final symbol = state.symbol;
  print('chart: $symbol ${state.resolution}');
  if (symbol == null) exit(1);

  final check = await readWorm10Signals(
    cdp,
    symbol,
    customScripts[0].scriptIdPart,
    customScripts[1].scriptIdPart,
    onDebugError: (msg) => print('reader error: $msg'),
  );
  print('zigzag signals: ${check.zigzag.signals.length}  '
      'supertrend signals: ${check.supertrend.signals.length}  '
      'RSI bars: ${check.rsiZones.length}  latest bar: ${_at(check.latestBarTime)}');
  final zones = <RsiZone, int>{};
  for (final z in check.rsiZones) {
    zones[z.zone] = (zones[z.zone] ?? 0) + 1;
  }
  print('RSI zones: ${zones.map((k, v) => MapEntry(k.name, v))}');

  final events = deriveWorm10Events(check);
  print('events: ${events.length}, newest last:');
  for (final e in events.skip(events.length > 8 ? events.length - 8 : 0)) {
    print('  ${worm10EventKindToWire(e.kind)} @ ${_at(e.time)}');
  }

  final wrong = await readWorm10Signals(
    cdp,
    'NOTTHISSYMBOLUSDT',
    customScripts[0].scriptIdPart,
    customScripts[1].scriptIdPart,
    onDebugError: (msg) => print('guard refused as expected: $msg'),
  );
  print('wrong-symbol read returned ${wrong.zigzag.signals.length} signals (must be 0)');
  cdp.close();
  exit(0);
}

String _at(int? t) => t == null
    ? 'none'
    : DateTime.fromMillisecondsSinceEpoch(t * 1000, isUtc: true)
          .toIso8601String()
          .substring(0, 16);
