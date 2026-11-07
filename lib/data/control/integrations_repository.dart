import 'dart:convert';

import '../../core/core_storage.dart';
import '../config/config_loader.dart';
import '../models/app_config.dart';
import '../pionex/pionex_client.dart';
import '../tradingview/launch.dart';

class ConnectionTestResult {
  const ConnectionTestResult({required this.ok, required this.message});
  final bool ok;
  final String message;
}

/// Backs the Settings screen's two integration panels (TradingView Desktop,
/// Pionex). Every field shown here is read from the same config.json/.env
/// the engine itself reads — editing here writes back to those same files,
/// so a save takes effect on the engine's next restart (or immediately for
/// the GUI, which re-reads on demand).
class IntegrationsRepository {
  IntegrationsRepository(this._storage);

  final CoreStorage _storage;

  // ---------------------------------------------------------------- Pionex
  ({String apiKey, String apiSecret}) readPionexCredentials() {
    final env = _storage.readEnvFile();
    return (
      apiKey: env['PIONEX_API_KEY'] ?? '',
      apiSecret: env['PIONEX_API_SECRET'] ?? '',
    );
  }

  void savePionexCredentials({
    required String apiKey,
    required String apiSecret,
  }) {
    final existing = _storage.readEnvFile();
    final merged = {
      ...existing,
      'PIONEX_API_KEY': apiKey,
      'PIONEX_API_SECRET': apiSecret,
    };
    final buffer = StringBuffer();
    for (final entry in merged.entries) {
      buffer.writeln('${entry.key}=${entry.value}');
    }
    _storage.writeString(_storage.envFile, buffer.toString());
  }

  Future<ConnectionTestResult> testPionex({
    required String apiKey,
    required String apiSecret,
  }) async {
    if (apiKey.trim().isEmpty || apiSecret.trim().isEmpty) {
      return const ConnectionTestResult(
        ok: false,
        message: 'API key and secret are required.',
      );
    }
    final client = PionexClient(apiKey: apiKey, apiSecret: apiSecret);
    try {
      final balance = await client.getBalance('USDT');
      return ConnectionTestResult(
        ok: true,
        message: 'Connected. USDT free: ${balance.free.toStringAsFixed(2)}',
      );
    } catch (e) {
      return ConnectionTestResult(ok: false, message: 'Failed: $e');
    } finally {
      client.close();
    }
  }

  // ----------------------------------------------------------- TradingView
  CdpConfig readCdpConfig() => loadOrInitConfig(_storage).cdp;

  void saveCdpConfig({required String host, required int port}) {
    final config = loadOrInitConfig(_storage);
    final updated = AppConfig(
      pollIntervalSec: config.pollIntervalSec,
      autoReserve: config.autoReserve,
      cdp: CdpConfig(host: host, port: port),
      gridPairs: config.gridPairs,
      technique: config.technique,
      risk: config.risk,
      heartbeatAlertEveryMin: config.heartbeatAlertEveryMin,
    );
    _storage.writeString(
      _storage.configFile,
      '${const JsonEncoder.withIndent('  ').convert(updated.toJson())}\n',
    );
  }

  /// Checks TradingView Desktop's debug port. Never launches or kills it:
  /// it's shared with tradingMT5 (see launch.dart).
  Future<ConnectionTestResult> testTradingView({
    required String host,
    required int port,
  }) async {
    final up = await isCdpUp(host, port);
    return ConnectionTestResult(
      ok: up,
      message: up
          ? 'TradingView Desktop is reachable on $host:$port.'
          : 'TradingView Desktop is not reachable on $host:$port — open it with --remote-debugging-port=$port.',
    );
  }

  /// Read-only status check — never launches or kills anything.
  Future<bool> isTradingViewUp({required String host, required int port}) =>
      isCdpUp(host, port);
}
