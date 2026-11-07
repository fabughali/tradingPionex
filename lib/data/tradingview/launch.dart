import 'dart:io';

/// TradingView Desktop on Windows is shared with tradingMT5: one TradingView,
/// one chart tab per app (see cdp_client.dart's tab-owner rule). So this app
/// never starts, restarts or kills TradingView - doing so would also take
/// tradingMT5's tab down. It only checks whether the debug port answers, and
/// tells the user when TradingView needs opening.

/// Whether TradingView's debug port answers on [host]:[port].
Future<bool> isCdpUp(String host, int port) async {
  final client = HttpClient();
  try {
    final request = await client
        .getUrl(Uri.parse('http://$host:$port/json/version'))
        .timeout(const Duration(seconds: 8));
    final response = await request.close().timeout(const Duration(seconds: 8));
    return response.statusCode == 200;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}
