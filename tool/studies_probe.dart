import 'dart:convert';
import 'dart:io';

import 'package:trading_pionex/data/tradingview/cdp_client.dart';

// READ-ONLY: lists every study on THIS app's chart tab (tag "tradingpionex")
// as TradingView's chart API reports it - id, name, study id. Changes nothing.
// Usage: dart run tool/studies_probe.dart
const _expr = r'''(function(){try{var ac=window.TradingViewApi.activeChart();var out=[];
ac.getAllStudies().forEach(function(s){var sid='';try{sid=ac.getStudyById(s.id).getStudyId();}catch(e){sid='ERR '+e;}out.push({id:s.id,name:s.name,studyId:sid});});
return JSON.stringify(out);}catch(e){return 'error '+e;}})()''';

Future<void> main() async {
  final http = HttpClient();
  final req = await http.getUrl(Uri.parse('http://127.0.0.1:9222/json/list'));
  final body = await (await req.close()).transform(utf8.decoder).join();
  http.close(force: true);
  for (final t in (jsonDecode(body) as List).cast<Map<String, dynamic>>()) {
    if (t['type'] != 'page' || !'${t['url']}'.contains('tradingview.com/chart')) continue;
    final c = CdpClient(await WebSocket.connect('${t['webSocketDebuggerUrl']}'));
    try {
      final tag = await c.evaluate('sessionStorage.getItem("tvTabOwner")');
      if (tag != pionexTabOwner) continue;
      stdout.writeln('${t['id']}: ${await c.evaluate(_expr)}');
    } finally {
      c.close();
    }
  }
  exit(0);
}
