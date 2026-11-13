import 'dart:convert';
import 'dart:io';

import 'package:trading_pionex/data/tradingview/cdp_client.dart';

// READ-ONLY: lists the buttons in TradingView Desktop's window frame (the
// tab bar page, app/window/index.html) - labels only. Clicks nothing.
// Usage: dart run tool/shell_probe.dart [port]
const _expr = '''(function(){var out=[];document.querySelectorAll('button,[role=button],[data-qa-id],[aria-label],[title]').forEach(function(el){
var l=(el.getAttribute('aria-label')||el.getAttribute('title')||el.getAttribute('data-qa-id')||el.textContent||'').trim();
if(l&&l.length<60)out.push(el.tagName+' | '+l);});return JSON.stringify(out.slice(0,80));})()''';

Future<void> main(List<String> args) async {
  final port = args.isEmpty ? 9222 : int.parse(args.first);
  final http = HttpClient();
  final req = await http.getUrl(Uri.parse('http://127.0.0.1:$port/json/list'));
  final body = await (await req.close()).transform(utf8.decoder).join();
  http.close(force: true);
  for (final t in (jsonDecode(body) as List).cast<Map<String, dynamic>>()) {
    final url = '${t['url']}';
    if (t['type'] != 'page' || !url.contains('/app/window/index.html')) continue;
    final socket = await WebSocket.connect('${t['webSocketDebuggerUrl']}');
    final client = CdpClient(socket);
    try {
      stdout.writeln('${t['id']}: ${await client.evaluate(_expr)}');
    } finally {
      client.close();
    }
  }
  exit(0);
}
