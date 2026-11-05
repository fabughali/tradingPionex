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

  /// Toggles [AppConfig.remoteSession] - see its own doc comment for why
  /// this is a manual setting rather than something auto-detected.
  void saveRemoteSession(bool remoteSession) {
    final config = loadOrInitConfig(_storage);
    final updated = AppConfig(
      pollIntervalSec: config.pollIntervalSec,
      autoReserve: config.autoReserve,
      remoteSession: remoteSession,
      cdp: config.cdp,
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

  void saveCdpConfig({required String host, required int port}) {
    final config = loadOrInitConfig(_storage);
    final updated = AppConfig(
      pollIntervalSec: config.pollIntervalSec,
      autoReserve: config.autoReserve,
      remoteSession: config.remoteSession,
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

  /// Mirrors the auto-launch the engine already does in its own `_connect()`
  /// (lib/data/engine/engine_service.dart) — if TradingView Desktop isn't
  /// reachable, power it up with the debug port open instead of just
  /// reporting failure, so this button recovers from "TradingView wasn't
  /// running" (e.g. after a machine restart) on its own.
  Future<ConnectionTestResult> testTradingView({
    required String host,
    required int port,
  }) async {
    if (await isCdpUp(host, port)) {
      return ConnectionTestResult(
        ok: true,
        message: 'TradingView Desktop is reachable on $host:$port.',
      );
    }
    final home = _storage.expandHome('~');
    final launched = await launchTradingView(
      host,
      port,
      LaunchConfig.defaultForHome(home.isNotEmpty ? home : _storage.rootDir),
      remoteSession: loadOrInitConfig(_storage).remoteSession,
    );
    return ConnectionTestResult(
      ok: launched,
      message: launched
          ? 'TradingView Desktop wasn\'t running — launched it and confirmed $host:$port is reachable.'
          : 'TradingView Desktop wasn\'t running and couldn\'t be launched automatically — start it manually with --remote-debugging-port=$port.',
    );
  }

  /// Read-only status check for the Settings screen's power toggle — unlike
  /// [testTradingView], never launches or kills anything.
  Future<bool> isTradingViewUp({required String host, required int port}) =>
      isCdpUp(host, port);

  Future<ConnectionTestResult> powerOffTradingView({
    required String host,
    required int port,
  }) async {
    if (!canControlTradingView) {
      return ConnectionTestResult(
        ok: false,
        message:
            'This app doesn\'t power off TradingView Desktop on Windows — close it yourself.',
      );
    }
    final home = _storage.expandHome('~');
    final stopped = await stopTradingView(
      host,
      port,
      LaunchConfig.defaultForHome(home.isNotEmpty ? home : _storage.rootDir),
    );
    return ConnectionTestResult(
      ok: stopped,
      message: stopped
          ? 'TradingView Desktop powered off.'
          : 'Could not confirm TradingView Desktop powered off — it may still be shutting down.',
    );
  }
}
