import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/core_router.dart';
import 'core/core_storage.dart';
import 'core/core_theme.dart';
import 'data/providers/app_providers.dart';
import 'l10n/app_localizations.dart';

void main() {
  runApp(const ProviderScope(child: TradingPionexApp()));
}

/// "GUI off == engine is off" (2026-10-20, per the user) - see
/// `CoreStorage.guiHeartbeatFile`'s doc and `EngineService._checkGuiHeartbeat` for the engine-side half).
/// Touches the heartbeat file every few seconds for as long as this widget
/// (i.e. the whole app) is alive - an ungraceful GUI exit (crash, `kill -9`,
/// the machine going down) simply stops updating it, which is exactly the
/// signal the engine watches for; a graceful close doesn't need its own
/// explicit "I'm closing now" write, since the engine's own staleness
/// window already covers both cases identically.
class TradingPionexApp extends ConsumerStatefulWidget {
  const TradingPionexApp({super.key});

  @override
  ConsumerState<TradingPionexApp> createState() => _TradingPionexAppState();
}

class _TradingPionexAppState extends ConsumerState<TradingPionexApp> {
  Timer? _heartbeatTimer;

  @override
  void initState() {
    super.initState();
    _tickGuiHeartbeat();
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _tickGuiHeartbeat(),
    );
  }

  void _tickGuiHeartbeat() {
    try {
      CoreStorage.instance.writeString(
        CoreStorage.instance.guiHeartbeatFile,
        DateTime.now().toUtc().toIso8601String(),
      );
    } catch (_) {
      // Best-effort only - a transient write failure just means the engine
      // sees one more stale check before the next tick 5s later recovers it.
    }
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
      debugShowCheckedModeBanner: false,
      theme: CoreTheme.light(),
      darkTheme: CoreTheme.dark(),
      themeMode: themeMode.flutterThemeMode,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: CoreRouter.router,
    );
  }
}
