import 'dart:async';
import 'dart:io';

import 'package:trading_pionex/core/core_constants.dart';
import 'package:trading_pionex/core/core_storage.dart';
import 'package:trading_pionex/core/engine_process.dart';
import 'package:trading_pionex/data/config/config_loader.dart';
import 'package:trading_pionex/data/engine/engine_service.dart';
import 'package:trading_pionex/data/logging/app_logger.dart';
import 'package:trading_pionex/data/models/app_config.dart';

// The long-lived engine process — the app brain (PRD §1). Normally launched
// BY the GUI's Power toggle (`EngineControlRepository.launchEngineIfNeeded`),
// not run standalone — the Flutter GUI never embeds this class, but it does
// control its lifecycle: Power off always stops it, and it self-terminates
// within ~60s if the GUI's own heartbeat file goes stale (see PRD §4.4,
// `EngineService._checkGuiHeartbeat`). A manual `dart run bin/engine.dart`
// with no GUI ever opened will self-exit the same way shortly after
// starting — the engine has no standalone/headless mode as of 2026-10-20,
// by design. Runs on the same machine as TradingView Desktop, since CDP +
// X11 access must stay local to that box.
//
// Configure the data directory with TRADING_PIONEX_HOME (defaults to
// ~/.tradingpionex).

void main() async {
  final storage = CoreStorage.instance;
  final logger = AppLogger(storage);

  // A malformed config.json/state.json (hand-edited, half-written, or from
  // an incompatible older version) previously crashed here with a bare,
  // unlogged TypeError before AppLogger had written a single line - the
  // operator would only ever see a stack trace on stderr/the systemd
  // journal, with nothing in engine.log explaining why. Both the config
  // parse (loadOrInitConfig) and the risk-state parse (inside EngineService's
  // constructor, via RiskGate) can throw the same way, so both are covered
  // by this one try/catch spanning all of startup's file parsing.
  final AppConfig config;
  final EngineService engine;
  try {
    config = loadOrInitConfig(storage);
    engine = EngineService(config: config, storage: storage, logger: logger);
  } catch (e, st) {
    logger.log(
      'CRITICAL: engine failed to start - could not load config.json or '
      'logs/state.json ($e). Check those files for corruption/bad hand-edits '
      'and fix or delete them, then restart.',
      level: 'CRITICAL',
    );
    logger.log(st.toString(), level: 'CRITICAL');
    exit(1);
  }

  // Single-instance lock: two engine processes running against the same
  // data directory would be two brains deciding on the same trades
  // independently - refuse to start a second one rather than silently
  // racing it. A leftover PID file from a crashed process (not actually
  // alive) is fine to take over.
  final existingPidRaw = storage.readString(storage.pidFile);
  final existingPid = int.tryParse((existingPidRaw ?? '').trim());
  if (existingPid != null &&
      existingPid != pid &&
      isEngineProcess(existingPid)) {
    logger.log(
      'REFUSING TO START: engine already running as PID $existingPid against this data directory '
      '(${storage.rootDir}). Stop it first if you really want to replace it.',
      level: 'CRITICAL',
    );
    exit(1);
  }

  // So the GUI can tell this process is actually alive (vs. just inferring
  // it from status.json freshness) before deciding whether Power-on needs to
  // launch a new one.
  storage.writeString(storage.pidFile, pid.toString());
  logger.log('engine ${CoreConstants.appVersion} starting (PID $pid)');
  // A request left over from before this run must never stop this run.
  storage.deleteFileIfExists(storage.engineShutdownRequestFile);

  engine.start();

  final done = Completer<void>();
  void shutdown(String signal) {
    logger.log('stopping engine ($signal)');
    engine.stop();
    storage.deleteFileIfExists(storage.pidFile);
    if (!done.isCompleted) done.complete();
  }

  ProcessSignal.sigint.watch().listen((_) => shutdown('SIGINT'));
  // Windows (2026-11-01): listening for SIGTERM there raises an unhandled
  // SignalException that kills this process right after engine.start(), and
  // nothing can send it one anyway. The GUI's Power off asks through a request
  // file instead, reaching the same shutdown() path.
  if (Platform.isWindows) {
    Timer.periodic(const Duration(seconds: 1), (_) {
      if (storage.fileExists(storage.engineShutdownRequestFile)) {
        storage.deleteFileIfExists(storage.engineShutdownRequestFile);
        shutdown('shutdown request');
      }
    });
  } else {
    ProcessSignal.sigterm.watch().listen((_) => shutdown('SIGTERM'));
  }
  // Per the user (2026-09-14): "i want engine stop when there is no auto
  // trade" - the engine can now decide to shut ITSELF down on its own (see
  // EngineService.onSelfExitRequested, which also covers the 2026-10-20
  // "GUI off == engine is off" heartbeat gate - the completed value is
  // whichever reason actually fired, logged verbatim below rather than a
  // single hardcoded label for every self-exit cause).
  // Goes through this exact same graceful shutdown() path as a real
  // signal, not a separate exit() call, so nothing about cleanup differs.
  engine.onSelfExitRequested.then(shutdown);

  await done.future;
  exit(0);
}
