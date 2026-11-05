import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/core_sound.dart';
import '../../core/core_storage.dart';
import '../config/config_loader.dart';
import '../control/engine_control_repository.dart';
import '../control/integrations_repository.dart';
import '../logging/app_logger.dart';
import '../models/app_config.dart';
import '../models/bot_history_entry.dart';
import '../models/trade_start_event.dart';
import '../pionex/pionex_client.dart';

final storageProvider = Provider<CoreStorage>((ref) => CoreStorage.instance);

final configProvider = Provider<AppConfig>(
  (ref) => loadOrInitConfig(ref.watch(storageProvider)),
);

final pionexClientProvider = Provider<PionexClient>((ref) {
  final storage = ref.watch(storageProvider);
  final env = storage.readEnvFile();
  // Per the user (2026-09-10): every Pionex call, from either process, must
  // be traceable (latency + outcome) in the one shared engine.log.
  final logger = AppLogger(storage);
  final client = PionexClient(
    apiKey: env['PIONEX_API_KEY'] ?? '',
    apiSecret: env['PIONEX_API_SECRET'] ?? '',
    onLog: logger.log,
  );
  ref.onDispose(client.close);
  return client;
});

final controlRepositoryProvider = Provider<EngineControlRepository>(
  (ref) => EngineControlRepository(
    ref.watch(storageProvider),
    ref.watch(pionexClientProvider),
  ),
);

final integrationsRepositoryProvider = Provider<IntegrationsRepository>(
  (ref) => IntegrationsRepository(ref.watch(storageProvider)),
);

/// Polls the file-based engine status + Pionex snapshot every 5s — the same
/// cadence as the engine's own poll loop, so the dashboard never feels far
/// behind reality. A manual `ref.invalidateSelf()` after any control action
/// (pause/resume/etc.) forces an immediate refresh instead of waiting.
///
/// Backs off past the fixed 5s once Pionex starts rate-limiting (2026-09-11,
/// per the user - see [EngineControlRepository.statusPollInterval]'s doc for
/// the full incident) - reading the interval AFTER each `status()` call
/// means it reacts to what THAT call just found, not the previous one.
final statusReportProvider = StreamProvider.autoDispose<StatusReport>((
  ref,
) async* {
  final repo = ref.watch(controlRepositoryProvider);
  while (true) {
    yield await repo.status();
    await Future<void>.delayed(repo.statusPollInterval);
  }
});

/// Tails the engine's log file, refreshed on the same cadence as the status.
final logTailProvider = StreamProvider.autoDispose<List<String>>((ref) async* {
  final storage = ref.watch(storageProvider);
  while (true) {
    final file = File(storage.logFile);
    if (!file.existsSync()) {
      yield const [];
    } else {
      final lines = await file.readAsLines();
      yield lines.length > 300 ? lines.sublist(lines.length - 300) : lines;
    }
    await Future<void>.delayed(const Duration(seconds: 3));
  }
});

/// History screen's data — polled on the same cadence as the status/log
/// providers, since both the engine and the GUI repository can append to
/// it independently.
final botHistoryProvider = StreamProvider.autoDispose<List<BotHistoryEntry>>((
  ref,
) async* {
  final repo = ref.watch(controlRepositoryProvider);
  while (true) {
    yield repo.history();
    await Future<void>.delayed(const Duration(seconds: 5));
  }
});

/// Voice-alert feed (2026-09-17, per the user) — every real
/// TradingView-driven open/close decision, engine-written only, polled on
/// the same cadence as [botHistoryProvider].
final tradeStartEventsProvider =
    StreamProvider.autoDispose<List<TradeStartEvent>>((ref) async* {
      final repo = ref.watch(controlRepositoryProvider);
      while (true) {
        yield repo.tradeStartEvents();
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    });

final soundServiceProvider = Provider<SoundService>(
  (ref) => SoundService(ref.watch(storageProvider)),
);

/// Per-tone mute state for the sound-alert feature (2026-09-17, per the
/// user), backed by [EngineControlRepository.soundMuteState]/
/// [EngineControlRepository.setSoundMuted] — same "own tiny file" pattern
/// as [ThemeModeNotifier], just reusing the repo's file-storage plumbing
/// instead of writing to `gui-prefs.json` directly since this feature
/// already carries a dedicated file.
class SoundMuteNotifier extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => ref.read(controlRepositoryProvider).soundMuteState();

  void setMuted(String tone, bool muted) {
    state = {...state, tone: muted};
    ref.read(controlRepositoryProvider).setSoundMuted(tone, muted);
  }
}

final soundMuteProvider = NotifierProvider<SoundMuteNotifier, Map<String, bool>>(
  SoundMuteNotifier.new,
);

enum AppThemeMode { system, light, dark }

extension AppThemeModeX on AppThemeMode {
  ThemeMode get flutterThemeMode => switch (this) {
    AppThemeMode.system => ThemeMode.system,
    AppThemeMode.light => ThemeMode.light,
    AppThemeMode.dark => ThemeMode.dark,
  };
}

/// Persisted to a small local prefs file (not a real "core_storage" runtime
/// concern like config.json, so it gets its own tiny file) so the theme
/// choice survives restarts without pulling in a full settings framework.
class ThemeModeNotifier extends Notifier<AppThemeMode> {
  late final String _prefsFile =
      '${ref.read(storageProvider).rootDir}/gui-prefs.json';

  @override
  AppThemeMode build() {
    final storage = ref.read(storageProvider);
    final json = storage.readJsonObject(_prefsFile);
    final raw = json?['theme_mode'] as String?;
    return AppThemeMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => AppThemeMode.system,
    );
  }

  void setMode(AppThemeMode mode) {
    state = mode;
    ref.read(storageProvider).writeJson(_prefsFile, {'theme_mode': mode.name});
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, AppThemeMode>(
  ThemeModeNotifier.new,
);
