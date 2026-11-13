import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app_tray.dart';
import 'core/core_router.dart';
import 'core/core_storage.dart';
import 'core/core_theme.dart';
import 'core/gui_instance_lock.dart';
import 'data/control/engine_control_repository.dart';
import 'data/logging/app_logger.dart';
import 'data/providers/app_providers.dart';
import 'l10n/app_localizations.dart';
import 'widgets/power_off_confirm.dart';

/// Kept in a top-level variable so it isn't garbage-collected the moment
/// [main] returns - [AppLifecycleListener] only fires while something holds it.
// ignore: unused_element
AppLifecycleListener? _exitListener;

late final ProviderContainer _container;
EngineControlRepository get _controlRepo =>
    _container.read(controlRepositoryProvider);

/// Power works exactly like tradingMT5's: the app opens with Power OFF, Power
/// OFF turns everything off, and closing the app turns everything off.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = CoreStorage.instance;

  // MUST stay first: a second copy of the app would otherwise run the
  // "Power OFF on launch" below and stop the engine under the first window.
  if (!GuiInstanceLock.acquire(storage)) {
    AppLogger(storage).log(
      'App already running - this second launch is exiting without touching '
      'Power/engine state (focusing the existing window instead).',
      level: 'WARNING',
    );
    await GuiInstanceLock.focusExisting(storage);
    exit(0);
  }

  _container = ProviderContainer();
  runApp(
    UncontrolledProviderScope(
      container: _container,
      child: const TradingPionexApp(),
    ),
  );

  // The app's icon next to the clock (per the user, 2026-11-14).
  unawaited(AppTray(isPowerOn: () => _controlRepo.isPowerOn).start());

  // The engine watches this file: while it's fresh the engine runs; once the
  // app is gone (closed, crashed, killed) it stops going fresh and the engine
  // stops itself (EngineService._checkGuiHeartbeat).
  storage.touchFile(storage.guiHeartbeatFile);
  Timer.periodic(const Duration(seconds: 5), (_) {
    try {
      storage.touchFile(storage.guiHeartbeatFile);
    } catch (_) {}
  });

  // Every launch first stops an engine left running from before (a crash, a
  // forced close); the Dashboard then powers on by itself (per the user,
  // 2026-11-13: app open == Power on, e.g. after a Windows restart).
  EngineControlRepository.startupCleanup = _controlRepo.powerOff();

  // Engine watchdog: while Power is on, a dead engine is restarted.
  final watchdogLogger = AppLogger(storage);
  var watchdogBusy = false;
  Timer.periodic(const Duration(seconds: 15), (_) async {
    if (watchdogBusy) return;
    watchdogBusy = true;
    try {
      if (!_controlRepo.isPowerOn || await _controlRepo.isEngineRunning()) return;
      // Power may have been switched off while tasklist ran.
      if (!_controlRepo.isPowerOn) return;
      watchdogLogger.log(
        'ENGINE WATCHDOG: Power is on but the engine process isn\'t running - '
        'restarting it automatically.',
        level: 'WARNING',
      );
      await _controlRepo.launchEngineIfNeeded();
    } finally {
      watchdogBusy = false;
    }
  });

  // Closing the window turns everything off (asking first if Power is on).
  _exitListener = AppLifecycleListener(
    onExitRequested: () async {
      if (!await _confirmCloseWhilePowerOn()) return AppExitResponse.cancel;
      await _controlRepo.powerOff();
      GuiInstanceLock.release();
      return AppExitResponse.exit;
    },
  );
  // Ctrl+C / Ctrl+Break (the only signal Windows delivers).
  ProcessSignal.sigint.watch().listen((_) async {
    await _controlRepo.powerOff();
    GuiInstanceLock.release();
    exit(0);
  });
}

/// The prompt showing now, so a second close click waits on it instead of
/// stacking another dialog.
Future<bool>? _closePrompt;

/// True if the window may close. Power off needs no prompt, so the silent
/// installer's close still works.
Future<bool> _confirmCloseWhilePowerOn() {
  if (!_controlRepo.isPowerOn) return Future.value(true);
  return _closePrompt ??= () async {
    try {
      final context = CoreRouter.router.routerDelegate.navigatorKey.currentContext;
      if (context == null) return true;
      final confirmed = await confirmPowerOff(context, closingApp: true);
      AppLogger(CoreStorage.instance).log(
        confirmed
            ? '[USER] Window close confirmed with Power on.'
            : '[USER] Window close cancelled - Power stays on.',
      );
      return confirmed;
    } finally {
      _closePrompt = null;
    }
  }();
}

class TradingPionexApp extends ConsumerWidget {
  const TradingPionexApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
