import 'dart:convert';
import 'dart:io';

// Read-only: prints owner tag, symbol, resolution and URL of every TradingView
// chart tab on the port. Never changes, claims or navigates anything.
// Usage: dart run tool/tab_snapshot.dart [port]   (default 9222)
const _expr = '''(function(){try{var t=sessionStorage.getItem("tvTabOwner");
var wv=window.TradingViewApi&&window.TradingViewApi._activeChartWidgetWV;
var c=wv&&wv.value();return JSON.stringify({tag:t,symbol:c&&c.symbol?c.symbol():null,
res:c&&c.resolution?c.resolution():null,url:location.href});}catch(e){return "error "+e;}})()''';

Future<void> main(List<String> args) async {
  final port = args.isEmpty ? 9222 : int.parse(args.first);
  final http = HttpClient();
  final req = await http.getUrl(Uri.parse('http://127.0.0.1:$port/json/list'));
  final body = await (await req.close()).transform(utf8.decoder).join();
  http.close();
  for (final t in (jsonDecode(body) as List).cast<Map<String, dynamic>>()) {
    if (t['type'] != 'page' || !(t['url'] as String).contains('/chart/')) continue;
    final ws = await WebSocket.connect(t['webSocketDebuggerUrl'] as String)
        .timeout(const Duration(seconds: 5));
    ws.add(jsonEncode({
      'id': 1,
      'method': 'Runtime.evaluate',
      'params': {'expression': _expr, 'returnByValue': true},
    }));
    final reply = await ws.first.timeout(const Duration(seconds: 5));
    await ws.close();
    final value = (jsonDecode(reply as String) as Map)['result']?['result']?['value'];
    print('${t['id']}  $value');
  }
}
