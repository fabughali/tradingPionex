import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/core_api.dart';
import '../../core/core_storage.dart';
import '../../core/engine_process.dart';
import '../../core/windows_engine_stop.dart';
import '../config/config_loader.dart';
import '../identity/auto_managed_store.dart';
import '../identity/bot_category_store.dart';
import '../identity/created_bots_store.dart';
import '../identity/entry_signal_store.dart';
import '../identity/pair_category_store.dart';
import '../identity/pair_investment_store.dart';
import '../identity/stop_loss_lock_state_store.dart';
import '../identity/stop_loss_lock_store.dart';
import '../identity/widen_applied_store.dart';
import '../identity/retired_store.dart';
import '../logging/app_logger.dart';
import '../models/auto_category.dart';
import '../models/balance.dart';
import '../models/bot_history_entry.dart';
import '../models/trade_start_event.dart';
import '../models/engine_status.dart';
import '../models/grid_bot.dart';
import '../models/preview_grid_pair.dart';
import '../models/running_bots_report.dart';
import '../pionex/pionex_client.dart';
import '../risk/risk_gate.dart';

/// The reporter/operator surface — reads the engine's status and Pionex
/// state, and writes control files (PAUSE/STOP/CHECKNOW/pending-create) for
/// the running engine process to pick up. Ported from the combined behavior
/// of scripts/botctl.mjs + scripts/trading.mjs. Deliberately never calls
/// Pionex create/checkParams directly — only the EngineService (the app
/// brain) ever decides or places a trade. Every read-only diagnostic here
/// (balance, report, can-create) matches what the original helper scripts
/// did directly against Pionex without going through the engine's mainLoop.
class GridSnapshot {
  const GridSnapshot({required this.appRunning, required this.manualRunning});
  final List<GridBot> appRunning;
  final List<GridBot> manualRunning;
}

class StatusReport {
  const StatusReport({
    required this.paused,
    required this.killSwitchPresent,
    required this.balance,
    required this.canOpenNewGrid,
    required this.grids,
    required this.engineStatus,
    required this.availablePairs,
    required this.lastPowerDownAt,
    required this.pionexConfigured,
    required this.lastReport,
    required this.runningBotsReport,
    required this.availableBalance,
  });
  final bool paused;
  final bool killSwitchPresent;
  final Balance balance;
  final bool canOpenNewGrid;
  final GridSnapshot grids;
  final EngineStatus engineStatus;
  final List<String> availablePairs;
  final DateTime? lastPowerDownAt;
  final bool pionexConfigured;
  final LastReport lastReport;
  final RunningBotsReport runningBotsReport;

  /// Pionex's own reported `balance.free` minus the sum of every currently
  /// WAITING bot's booked initial investment (2026-09-11, per the user:
  /// "if there is any bot in waiting, it means the initial investment
  /// value is booked for this bot... the balance in the app should show
  /// pionex balance - sum of waiting bots"). Covers both halves the user
  /// explicitly confirmed: bases the app itself is trying to
  /// recycle-reopen, AND bases the user just Started that haven't opened
  /// yet - both come from the same `waitingBases()` list. This is what
  /// the Free-balance display and the Start button's own pre-check use
  /// from here on - `balance.free` itself is left untouched as the
  /// honest, raw Pionex-reported value, in case anything else ever needs
  /// it.
  final double availableBalance;

  /// Auto's own candle-gate anchor plus one hour - per the user
  /// (2026-09-05/06), Auto is the only track with a real recurring
  /// schedule (once per hour, auto-managed bases only); Checkup is
  /// on-demand only and has no "next" time to count down to.
  DateTime? get nextCheckupEta =>
      engineStatus.lastAutoCandleTime?.add(const Duration(hours: 1));

  /// Same idea as [nextCheckupEta], per [AutoCategory] - each of the 3 Auto
  /// engines has its own recurring schedule (2026-09-07).
  DateTime? nextCheckupEtaFor(AutoCategory c) {
    final anchor = engineStatus.statusFor(c).lastCandleTime;
    if (anchor == null) return null;
    return anchor.add(c.candlePeriod);
  }
}

class CancelOutcome {
  const CancelOutcome({
    required this.bot,
    required this.acted,
    this.refused = false,
    this.reason,
  });
  final GridBot bot;
  final bool acted;
  final bool refused;
  final String? reason;
}

class EngineControlRepository {
  EngineControlRepository(this._storage, this._pionex)
    : createdBots = CreatedBotsStore(_storage),
      widenApplied = WidenAppliedStore(_storage),
      retired = RetiredStore(_storage),
      autoManaged = AutoManagedStore(_storage),
      botCategories = BotCategoryStore(_storage),
      stopLossLock = StopLossLockStore(_storage),
      stopLossLockState = StopLossLockStateStore(_storage),
      entrySignals = EntrySignalStore(_storage),
      pairCategories = PairCategoryStore(_storage),
      pairInvestments = PairInvestmentStore(_storage),
      autoManagedByCategory = {
        for (final c in allAutoCategories)
          c: c == AutoCategory.oneHour
              ? AutoManagedStore(_storage)
              : AutoManagedStore(
                  _storage,
                  filePath: _storage.autoManagedBasesFileFor(c),
                ),
      },
      // GUI-side, deliberately separate RiskGate instance (2026-09-09) -
      // reads/writes the SAME shared state.json the engine uses. Needed so
      // an explicit Stop from here can decrement open_positions itself,
      // same class of bug as the engine's own _refreshActiveGrids fix (see
      // PRD §20/§10): this repository never held any RiskGate before, so
      // every GUI-initiated Stop leaked its symbol's counter permanently,
      // even though createdBots.forgetBot() already ran - by the time the
      // engine's own reconciliation pass might have caught it, the id was
      // already gone from created-bots.json, so it never got the chance.
      risk = RiskGate(_storage, loadOrInitConfig(_storage).risk),
      _logger = AppLogger(_storage);

  final CoreStorage _storage;
  final PionexClient _pionex;
  final RiskGate risk;
  final CreatedBotsStore createdBots;
  final WidenAppliedStore widenApplied;
  final RetiredStore retired;
  final AutoManagedStore autoManaged;

  /// buOrderId -> [AutoCategory] the bot belongs to - the source for the
  /// "(1m)"/"(1H)"/"(1D)" tag shown after a pair name wherever an auto bot
  /// appears (2026-09-07). Reload before reading, same as [createdBots] -
  /// this is the engine process's own file, written by it.
  final BotCategoryStore botCategories;

  /// Which pairs/bots are governed by "Stop Loss Lock" (2026-09-22, per the
  /// user) instead of the normal TP/SL ratchet - see [StopLossLockStore]'s
  /// own doc for the full design. Written here (by the GUI), read by the
  /// running engine, same shared-file convention as [retired].
  final StopLossLockStore stopLossLock;

  /// Per-buOrderId Stop Loss Lock state (highest profit-floor SL locked in
  /// so far) - the engine's own process writes this; read here only so the
  /// GUI can show it (e.g. on the bot details screen).
  final StopLossLockStateStore stopLossLockState;

  /// Per-buOrderId entry-signal record (2026-09-26, per the user: "the
  /// record should be one out of those 60 entries") - which of the user's
  /// 60 (signal, zone) entries opened this bot, and, once known, which one
  /// closed it. The engine process writes this; read here only so the GUI
  /// can show it. Always re-loaded fresh before reading (see
  /// [entrySignalFor]) - the whole point of this store is showing a value
  /// that changes the moment the engine records a close, so a cached read
  /// would go stale exactly when it matters most.
  final EntrySignalStore entrySignals;

  /// Fresh (never cached) read of one bot's entry-signal record, or null if
  /// it never got one (opened before this feature existed, or via a path
  /// with no confirmed signal on hand).
  EntrySignalRecord? entrySignalFor(String buOrderId) {
    entrySignals.load();
    return entrySignals.recordFor(buOrderId);
  }

  /// symbol -> [AutoCategory] the user picked via the per-pair "knob" -
  /// written here (by the GUI), read by the running engine.
  final PairCategoryStore pairCategories;

  /// symbol -> custom initial investment (USDT) the user picked via the
  /// per-pair text field (2026-09-09) - written here (by the GUI), read by
  /// the running engine only for that pair's very first real open.
  final PairInvestmentStore pairInvestments;

  /// Per-category auto-managed-bases list, 1H reusing the pre-existing
  /// single [autoManaged] instance/file for backward compat.
  final Map<AutoCategory, AutoManagedStore> autoManagedByCategory;
  final AppLogger _logger;

  /// Every operator action taken through this class logs an
  /// `[OPERATOR]`-prefixed line to the same engine.log the running engine
  /// writes to. Otherwise an action taken while the engine process isn't
  /// running (or between its polls) leaves no trace anywhere the user can
  /// see.
  void _log(String message) => _logger.log('[OPERATOR] $message');

  /// For UI-level outcomes that aren't already covered by a specific action
  /// method above (e.g. an action throwing, or an integration test result) —
  /// so every success/error surfaced to the user as a SnackBar also lands in
  /// the log the same way.
  void logUiOutcome(String message, {required bool success}) =>
      _log(success ? message : 'ERROR: $message');

  /// Last successfully-fetched balance/grids (2026-09-11) - used by
  /// [status] as a fallback when Pionex is unreachable, so a transient
  /// internet outage degrades to "showing slightly stale numbers" instead
  /// of throwing and blanking the whole status poll (which also meant the
  /// GUI's internet-down dialog never got a chance to show - the
  /// `StatusReport` that would have carried `engineStatus.internetHealthy`
  /// never made it out of [status] in the first place).
  Balance _lastBalance = Balance.zero;
  GridSnapshot _lastGrids = const GridSnapshot(
    appRunning: [],
    manualRunning: [],
  );
  bool _statusFetchFailureLogged = false;

  /// How many [status] calls in a row have failed on a [RateLimitException]
  /// specifically (2026-09-11, per the user, live account - confirmed via
  /// Pionex's own rate-limit docs: exceeding the limit gives a 60s ban, and
  /// - critically - "every request sent while still banned adds another 10
  /// seconds to the ban"). [statusPollInterval] backs off using this count.
  /// Reset to 0 the moment a poll succeeds.
  int _consecutiveRateLimitFailures = 0;

  /// How long [statusReportProvider] should wait before its NEXT poll -
  /// normally the fixed 5s cadence, but backs off hard once Pionex starts
  /// rate-limiting: 30s, 60s, 120s, 240s, capping at 480s (8 min).
  ///
  /// Bug fixed 2026-09-11, per the user ("what in app make this case???"),
  /// after a live, self-inflicted ~15-minute outage: [status] already
  /// degraded gracefully on a Pionex failure (falls back to last-known
  /// data, never crashes) but had NO backoff at all - the GUI's own
  /// `statusReportProvider` just called it again in another fixed 5s no
  /// matter how many times in a row it had failed. Since Pionex extends a
  /// rate-limit ban by 10s for every request it receives WHILE still
  /// banned, and this poll was sending one every 5s, the ban was
  /// mathematically GROWING faster than real time could pass (10s added
  /// per 5s elapsed) - it could never have cleared on its own as long as
  /// the app kept running normally. This breaks that feedback loop: once
  /// rate-limited, the poll backs off far enough that by its next attempt
  /// the ban has very likely already expired on its own, instead of
  /// re-triggering and extending it every single time.
  Duration get statusPollInterval {
    if (_consecutiveRateLimitFailures <= 0) return const Duration(seconds: 5);
    final steps = (_consecutiveRateLimitFailures - 1).clamp(0, 4);
    final seconds = 30 * (1 << steps);
    return Duration(seconds: seconds.clamp(30, 480));
  }

  bool get isPaused => _storage.fileExists(_storage.pauseFile);
  bool get isKillSwitched => _storage.fileExists(_storage.stopFile);

  EngineStatus readEngineStatus() {
    final json = _storage.readJsonObject(_storage.statusFile);
    return json == null ? EngineStatus.notRunning : EngineStatus.fromJson(json);
  }

  /// The engine's most recent per-cycle preview of actionable candidates
  /// (see `PreviewGridPair`) — backs the dashboard's "Last report" checklist.
  LastReport readLastReport() {
    final json = _storage.readJsonObject(_storage.lastReportFile);
    return json == null ? LastReport.empty : LastReport.fromJson(json);
  }

  /// The same checkup cycle's fresh signal read on every currently-running
  /// auto bot (see `RunningBotCheck`) — backs the "Auto Bots Report".
  RunningBotsReport readRunningBotsReport() {
    final json = _storage.readJsonObject(_storage.runningBotsReportFile);
    return json == null
        ? RunningBotsReport.empty
        : RunningBotsReport.fromJson(json);
  }

  Future<List<GridBot>> _runningGrids({bool withPrices = false}) async {
    if (!_pionex.available) return const [];
    final orders = await _pionex.getActiveGrids();
    createdBots.load();
    widenApplied.load();
    final bots = orders.map((o) {
      final id = (o['buOrderId'] ?? (o['buOrderData'] as Map?)?['buOrderId'])
          ?.toString();
      return GridBot.fromPionexOrder(
        o,
        appInitiated: createdBots.isAppInitiated(id),
        widenApplied: widenApplied.isWidenApplied(id),
      );
    }).toList();
    if (!withPrices || bots.isEmpty) return bots;
    return _withCurrentPrices(bots);
  }

  /// Attaches the live last-traded price to each bot via the public ticker
  /// endpoint, deduped by symbol — display only, never used in any trading
  /// decision.
  ///
  /// Bug fixed 2026-09-11, per the user ("did you fix [it] so it is not
  /// going to reach pionex api call limit"), after the rate-limit incident
  /// documented on [PionexClient]'s circuit breaker: this used to fire
  /// every symbol's ticker request via `Future.wait` - ALL of them, at the
  /// exact same instant, every single 5s status poll. With ~10-12 running
  /// bots (a normal night, not even the extra load from that incident),
  /// that alone is 10-12 requests landing in the same millisecond, on top
  /// of the same poll's balance/grid-list calls, sharing Pionex's 10 req/s
  /// PER-ACCOUNT limit with whatever the engine is doing at that same
  /// moment - enough to legitimately burst over the limit in completely
  /// normal operation, not just during a heavy one-off script. Now fetches
  /// sequentially with a small stagger between each - display prices don't
  /// need to be simultaneous, and this alone can never exceed a low,
  /// predictable rate, leaving real headroom under the limit for
  /// everything else sharing it.
  Future<List<GridBot>> _withCurrentPrices(List<GridBot> bots) async {
    final symbols = bots.map((b) => _tickerSymbol(b)).toSet();
    final prices = <String, double?>{};
    var first = true;
    for (final s in symbols) {
      if (!first) await Future<void>.delayed(const Duration(milliseconds: 150));
      first = false;
      try {
        prices[s] = await _pionex.getTickerPrice(s);
      } catch (_) {
        prices[s] = null;
      }
    }
    return bots
        .map((b) => b.copyWith(currentPrice: prices[_tickerSymbol(b)]))
        .toList();
  }

  String _tickerSymbol(GridBot b) =>
      '${b.base.replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '')}_${b.quote}_PERP';

  Future<GridSnapshot> _splitGrids({bool withPrices = false}) async {
    final all = await _runningGrids(withPrices: withPrices);
    return GridSnapshot(
      appRunning: all.where((g) => g.appInitiated).toList(),
      manualRunning: all.where((g) => !g.appInitiated).toList(),
    );
  }

  Future<Balance> balance() => _pionex.available
      ? _pionex.getBalance('USDT')
      : Future.value(Balance.zero);

  /// Every user-facing read/action below opens with [refreshSync] — Pionex is
  /// the source of truth, and the app must never reason from stale auto-bot
  /// memory (e.g. a bot the user paused/stopped manually in the Pionex UI).
  Future<StatusReport> status() async {
    // engineStatus is a pure local file read (status.json, written by the
    // engine process) - always safe regardless of Pionex reachability, and
    // the only source of `internetHealthy` the GUI's no-internet dialog
    // depends on. Read it unconditionally, BEFORE the Pionex-touching
    // calls below, so an outage there can never prevent it from reaching
    // the caller.
    final engineStatus = readEngineStatus();
    Balance bal;
    GridSnapshot grids;
    try {
      await refreshSync();
      bal = await balance();
      grids = await _splitGrids(withPrices: true);
      _lastBalance = bal;
      _lastGrids = grids;
      _statusFetchFailureLogged = false;
      _consecutiveRateLimitFailures = 0;
    } catch (e) {
      // Bug fixed 2026-09-11, per the user (tested by switching off
      // internet): this used to let a raw, uncaught Pionex timeout/DNS
      // failure propagate straight out of status() and into the GUI's
      // StreamProvider as an AsyncError - which the dashboard showed as a
      // generic error instead of the intended no-internet dialog (that
      // dialog reads `engineStatus.internetHealthy` off a SUCCESSFULLY
      // returned StatusReport, which never arrived). Falls back to the
      // last-known balance/grids instead - logged once per failure streak,
      // not every 5s poll.
      if (!_statusFetchFailureLogged) {
        logUiOutcome(
          'status: Pionex refresh failed (showing last-known data until it recovers) - $e',
          success: false,
        );
        _statusFetchFailureLogged = true;
      }
      // See [statusPollInterval]'s doc - only a genuine rate-limit failure
      // backs the poll off; a plain timeout/DNS blip keeps the normal 5s
      // cadence so a real internet hiccup still recovers quickly.
      _consecutiveRateLimitFailures = e is RateLimitException
          ? _consecutiveRateLimitFailures + 1
          : 0;
      bal = _lastBalance;
      grids = _lastGrids;
    }
    // Per the user (2026-09-11): every waiting bot's initial investment is
    // effectively already "booked" (spoken for), even though Pionex has no
    // idea about it yet since no order has been placed - deducted here so
    // the app never shows/allows spending money that's actually earmarked
    // for a pair still waiting to open. Covers both halves the user
    // confirmed: app-recycled waits and user-Started-but-not-yet-open
    // waits, since both already come from the one waitingBases() list.
    final bookedForWaiting = waitingBases(
      grids.appRunning,
    ).fold(0.0, (sum, w) => sum + w.investment);
    final availableBalance = (bal.free - bookedForWaiting)
        .clamp(0, double.infinity)
        .toDouble();
    return StatusReport(
      paused: isPaused,
      killSwitchPresent: isKillSwitched,
      balance: bal,
      availableBalance: availableBalance,
      // Bug fixed 2026-09-10, per the user ("i want balance green"): this
      // used to require the flat $10 new-pair floor
      // (CoreConstants.newPairMinFreeUsdt), which was accurate when every
      // pair used a uniform $10 investment but is now stale - confirmed
      // live this same session that real opens routinely succeed well
      // under $10 (as low as $0.365), both for recycling pairs (which
      // skip the $10 floor entirely - see "FUNDS X: old pair... no $10
      // floor" in the engine log) and for a custom low-investment
      // first-time pair. A flat $10 check colored the balance an
      // unwarranted warning yellow even when the app could, and regularly
      // did, open real grids under that amount. Any positive free balance
      // now shows green; only $0 (or paused) shows the warning color.
      // Updated 2026-09-11: now checks `availableBalance` (post-booking),
      // same reasoning as the balance display itself.
      canOpenNewGrid: !isPaused && availableBalance > 0,
      grids: grids,
      engineStatus: engineStatus,
      availablePairs: _availablePairsFrom(engineStatus),
      lastPowerDownAt: lastPowerDownAt,
      pionexConfigured: _pionex.available,
      lastReport: readLastReport(),
      runningBotsReport: readRunningBotsReport(),
    );
  }

  /// Every base currently on the engine's Red List, A-Z - unfiltered (no
  /// longer excludes already-running or retired bases; this is a plain
  /// listing of the Red List itself, not a "what could I start" filter).
  List<String> _availablePairsFrom(EngineStatus status) {
    final bases = status.redListSymbols.map((s) {
      final afterColon = s.split(':').last;
      return afterColon
          .split('/')
          .first
          .split('_')
          .first
          .replaceAll('USDT', '')
          .toUpperCase();
    }).toSet();
    return bases.toList()..sort();
  }

  String get _lastPowerDownFile => '${_storage.logsDir}/last-powerdown.json';

  /// The last time [pause] was called, persisted separately from the PAUSE
  /// file itself so the history survives a later [resume] (which deletes
  /// the PAUSE file). Null if the app has never been powered down.
  DateTime? get lastPowerDownAt {
    final json = _storage.readJsonObject(_lastPowerDownFile);
    final ms = (json?['at_ms'] as num?)?.toInt();
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// Auto OFF (the PAUSE file), as in tradingMT5: the engine reads nothing,
  /// opens nothing and closes nothing until Auto is on. Protection of bots
  /// already running keeps going. Independent of Power.
  void pause() {
    _storage.touchFile(_storage.pauseFile);
    _storage.writeJson(_lastPowerDownFile, {
      'at_ms': DateTime.now().millisecondsSinceEpoch,
    });
    _log('Auto turned OFF.');
  }

  /// Auto ON.
  bool resume() {
    final was = isPaused;
    _storage.deleteFileIfExists(_storage.pauseFile);
    _log(was ? 'Auto turned ON.' : 'Auto ON requested, but it was already on.');
    return was;
  }

  /// The compiled standalone engine executable, expected to sit next to
  /// whichever binary is currently running this code — built with
  /// `dart compile exe bin/engine.dart -o <path>` and deployed alongside the
  /// GUI bundle (see the redeploy step this project uses).
  String get _engineBinaryPath =>
      p.join(p.dirname(Platform.resolvedExecutable), engineBinaryFileName);

  /// Whether the engine process is actually alive right now — checked via
  /// its PID file (written by `bin/engine.dart` on startup, removed on clean
  /// shutdown), not just "status.json was updated recently", so a slow
  /// cycle never gets mistaken for a dead process. See [isEngineProcess] for
  /// why the PID alone is never trusted.
  bool get isEngineProcessAlive {
    final raw = _storage.readString(_storage.pidFile);
    final pid = int.tryParse((raw ?? '').trim());
    if (pid == null) return false;
    return isEngineProcess(pid);
  }

  /// Launches the compiled engine binary as a detached background process if
  /// it isn't already running. Safe to call repeatedly — a no-op whenever
  /// the engine is already alive, so it never risks starting a second
  /// "brain" racing the first one over the same trades.
  Future<bool> launchEngineIfNeeded() async {
    if (isEngineProcessAlive) return true;
    final binaryPath = _engineBinaryPath;
    if (!File(binaryPath).existsSync()) {
      _log(
        'ERROR: engine binary not found at $binaryPath — cannot auto-launch. Run bin/engine.dart manually.',
      );
      return false;
    }
    try {
      await Process.start(
        binaryPath,
        const [],
        mode: ProcessStartMode.detached,
        environment: {'TRADING_PIONEX_HOME': _storage.rootDir},
      );
      _log('Engine process launched ($binaryPath).');
      return true;
    } catch (e) {
      _log('ERROR: failed to launch engine process: $e');
      return false;
    }
  }

  /// Stops the engine process, tradingMT5's way ([WindowsEngineStopper]): ask
  /// it to shut down, wait up to 10s, then `taskkill /F`, and clean up its
  /// pid/heartbeat files. Returns true once no engine process is left.
  Future<bool> stopEngineProcess() async {
    final outcome = await WindowsEngineStopper(
      storage: _storage,
      isAlive: isEngineProcessAsync,
      forceKill: forceKillEngine,
      log: (message, {String level = 'INFO'}) =>
          _logger.log('[OPERATOR] $message', level: level),
    ).stop();
    switch (outcome) {
      case WindowsStopOutcome.notRunning:
        break;
      case WindowsStopOutcome.graceful:
        _log('Engine process stopped.');
      case WindowsStopOutcome.forceKilled:
        _log('Engine process force-stopped (taskkill /F).');
      case WindowsStopOutcome.stillAlive:
        _log('ERROR: engine process is still running after taskkill /F.');
        return false;
    }
    return true;
  }

  /// Whether the user has Power on (see [CoreStorage.powerOnFile]).
  bool get isPowerOn => _storage.fileExists(_storage.powerOnFile);

  /// Power ON succeeded: remember it, so the watchdog keeps the engine up.
  void markPowerOn() => _storage.touchFile(_storage.powerOnFile);

  /// Power OFF, tradingMT5's way: forgets Power and stops the engine process
  /// (graceful, then taskkill /F) - everything off. Auto is a separate
  /// switch and keeps its state, as in tradingMT5. Running bots stay open on
  /// Pionex, untouched.
  Future<bool> powerOff() async {
    _storage.deleteFileIfExists(_storage.powerOnFile);
    _log('Power OFF - stopping the engine.');
    return stopEngineProcess();
  }

  /// Async check for the GUI's engine watchdog - `tasklist` must not block
  /// the UI thread.
  Future<bool> isEngineRunning() async {
    final pid = int.tryParse((_storage.readString(_storage.pidFile) ?? '').trim());
    return pid != null && await isEngineProcessAsync(pid);
  }

  /// checknow: asks the running engine to do a full checkup on its next tick,
  /// bypassing the hourly candle gate once. Does not open/close anything itself.
  void checkNow() {
    _storage.touchFile(_storage.checknowFile);
    _log(
      'CHECKNOW triggered — next engine tick will run a full checkup regardless of the candle gate.',
    );
  }

  /// Tells the engine which pairs Check Now reads, in the table's order.
  /// [newRound] true for a Check Now press (read them all again); false for
  /// "Show more" (same round - only the newly shown pairs get read).
  void setCheckNowPairs(List<String> symbols, {required bool newRound}) {
    final current = _storage.readJsonObject(_storage.checkNowPairsFile);
    final round = (current?['round'] as num?)?.toInt() ?? 0;
    _storage.writeJson(_storage.checkNowPairsFile, {
      'round': newRound ? round + 1 : round,
      'symbols': symbols,
    });
  }

  /// Asks the running engine to run the Auto-checkup track right now,
  /// forcing its way ahead of a running full Checkup if one happens to be
  /// mid-sweep - Auto ON's own trigger, scoped to auto-managed bases only,
  /// never the whole Red list (that's checkNow's job).
  void triggerAutoCheckup() {
    _storage.touchFile(_storage.autoCheckNowFile);
    _log(
      'AUTO CHECKNOW triggered — Auto-checkup will run now, postponing a running checkup if there is one.',
    );
  }

  /// [triggerAutoCheckup]'s per-category equivalent (2026-09-07) - forces
  /// just that one Auto engine to run now, on its own auto-managed bases
  /// only.
  void triggerAutoCheckupFor(AutoCategory category) {
    _storage.touchFile(_storage.autoCheckNowFileFor(category));
    _log(
      'AUTO CHECKNOW[${category.label}] triggered — Auto[${category.label}] '
      'will run now, postponing whichever track currently holds the chart.',
    );
  }

  /// Each of the 3 Auto engines has its own independent on/off switch,
  /// separate from Power - presence of the per-category file means that
  /// category is paused (per the user, 2026-09-07).
  bool isCategoryPaused(AutoCategory category) =>
      _storage.fileExists(_storage.autoCategoryPausedFileFor(category));

  void pauseCategory(AutoCategory category) {
    _storage.touchFile(_storage.autoCategoryPausedFileFor(category));
    _log('Auto[${category.label}] switched off.');
  }

  bool resumeCategory(AutoCategory category) {
    final was = isCategoryPaused(category);
    _storage.deleteFileIfExists(_storage.autoCategoryPausedFileFor(category));
    _log(
      was
          ? 'Auto[${category.label}] switched on.'
          : 'Auto[${category.label}] switch-on requested, but it was already on.',
    );
    return was;
  }

  /// Sets the category (3m/5m/15m/1H/1D) the user picked via the per-pair
  /// "knob" - consulted by the engine the next time this pair is opened
  /// outside one of the 5 schedulers' own bases lists (a fresh Start/Check).
  ///
  /// Bug fixed 2026-09-12, per the user, after a live incident where three
  /// pairs' running bots got their category live-retagged several times in
  /// under 12 seconds: "whenever auto bot set to be in a certain interval
  /// it can't be shifted to another interval unless it is converted to
  /// manual first" / "nope.. that action is wrong..." (rejecting the
  /// 2026-09-09 design this used to have, which deliberately live-migrated
  /// a running bot's category the instant the knob changed). Still true
  /// today: a running bot's OWN category tag (`botCategories`, keyed by
  /// buOrderId) is never touched here, and a category with a real running
  /// bot for this base never loses its auto-managed membership from this
  /// method - changing what an ALREADY-RUNNING bot is tagged as still
  /// requires converting it to manual first, then back to auto under the
  /// new category ([convertManualToAuto]).
  ///
  /// Loosened 2026-09-19, per the user, after finding it silently blocked a
  /// genuinely different, valid case: starting the SAME base under a
  /// SECOND category while a different one is already running for it (each
  /// AutoCategory is a fully independent engine that can manage the same
  /// base in parallel - see the enum's own doc comment, and
  /// [EngineService._appGridForKey], which already keys "is this base
  /// running" by base+category, not base alone). Live case: BTCUSDT running
  /// under 1H, user picks 3m in the knob and clicks Start - the preference
  /// write used to be refused outright (since a DIFFERENT category had a
  /// running bot), so Start's own category lookup (`pairCategories
  /// .categoryOf`) still read 1H, found the real 1H bot via
  /// `_appGridForKey`, and reported "already running" for a category
  /// (3m) that had never actually opened anything. Now: the preference is
  /// only ever refused (no-op) when a real bot ALREADY runs under the
  /// EXACT category just picked (nothing to change) - a running bot under
  /// any OTHER category no longer blocks the write, and that other
  /// category's own auto-managed membership is left completely untouched
  /// (never removed) precisely because it still has a real position open.
  Future<void> setPairCategory(String symbol, AutoCategory category) async {
    final normalized = symbol.trim().toUpperCase();
    final base = normalized.endsWith('USDT')
        ? normalized.substring(0, normalized.length - 4)
        : normalized;
    final grids = await _splitGrids();
    // Same base/".PERP" mismatch fix as everywhere else this session -
    // `g.base` is Pionex's raw futures base, `base` above is bare. A base
    // can have one running app bot per category at once, so this is every
    // category with a real running bot for it, not a single value.
    final runningCategories = grids.appRunning
        .where(
          (g) =>
              g.base
                  .toUpperCase()
                  .replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '') ==
              base,
        )
        .map(
          (g) => botCategories.categoryOf(g.buOrderId) ?? AutoCategory.oneHour,
        )
        .toSet();
    if (runningCategories.contains(category)) {
      // A real bot already runs for this base under exactly the picked
      // category - a genuine no-op, nothing to persist or move.
      return;
    }
    pairCategories.setCategory(normalized, category);
    for (final entry in autoManagedByCategory.entries) {
      if (entry.key == category || !entry.value.isAutoManaged(base)) continue;
      // Never strip a category's auto-managed membership while it has a
      // real running bot for this base - see the doc comment above.
      if (runningCategories.contains(entry.key)) continue;
      entry.value.removeBase(base);
      autoManagedByCategory[category]!.addBase(base);
      _log(
        'Auto-managed base $base moved from ${entry.key.label} to '
        '${category.label} (category changed).',
      );
    }
    _log('Category for $symbol set to ${category.label}.');
  }

  /// Sets the initial investment (USDT) the user picked via the per-pair
  /// text field (2026-09-09) - consulted by the engine only for that pair's
  /// very first real open, never for an already-recycling bot's P&L-
  /// adjusted amount. No floor enforced - Pionex's own grid-sizing probe is
  /// what actually decides whether a too-small amount can open at all.
  void setPairInvestment(String symbol, double amount) {
    pairInvestments.setInvestment(symbol.trim().toUpperCase(), amount);
    _log('Initial investment for $symbol set to \$$amount.');
  }

  /// Asks the engine to connect to TradingView and re-read the Red List
  /// right now, independent of PAUSE - Power ON uses this so the Red List
  /// is fresh even while Auto is still off.
  void refreshRedList() {
    _storage.touchFile(_storage.refreshRedListFile);
    _log('Red list refresh requested.');
  }

  /// Controls screen's single-pair "Check"/"Add"/"Remove" actions — submits
  /// a request to the running engine (the only process with a live
  /// TradingView CDP session) and polls for its matching result. Scoped to
  /// one pair so it's normally quick, but the engine processes it strictly
  /// after any main sweep already in flight (single chart, can't navigate it
  /// from two places at once) — [timeout] bounds how long this waits before
  /// giving up and reporting a timeout rather than hanging the button
  /// forever.
  Future<Map<String, dynamic>> requestPairAction(
    String action,
    String rawSymbol, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    // Per the user (2026-09-06): use exactly what the caller already
    // resolved - no qualifySymbol rebuilding here either, which was
    // silently re-adding "BINANCE:" AFTER the Controls screen had
    // already correctly resolved a bare symbol, undoing that fix.
    final symbol = rawSymbol.trim().toUpperCase();
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    _storage.writeJson(_storage.pairActionFile, {
      'id': id,
      'action': action,
      'symbol': symbol,
    });
    _log('PAIR ACTION requested: $action $symbol (id=$id).');
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      final result = _storage.readJsonObject(_storage.pairActionResultFile);
      if (result != null && '${result['id']}' == id) return result;
    }
    return {
      'ok': false,
      'symbol': symbol,
      'message':
          'Timed out waiting for the engine to respond — it may still be '
          'mid-sweep on the Red List. Try again shortly.',
    };
  }

  /// Editing a pair's Initial investment mid-Check-Now-sweep (2026-09-11,
  /// per the user) - a fast, Pionex-only re-price of [symbol]'s [category]
  /// row (actualInvestment/extraMargin/gridCount/liquidationPrice against
  /// the pair's CURRENT investment amount), never a TradingView signal
  /// recheck. Genuinely chart-free on the engine side, so - unlike
  /// [requestPairAction] - this never has to wait behind Check Now/Auto-
  /// checkup/another pair action; a much shorter default timeout reflects
  /// that. Caller is expected to only call this for a row that already has
  /// real data (an existing preview) - see the caller's own `hasData`
  /// check - the engine refuses gracefully otherwise anyway.
  Future<Map<String, dynamic>> requestReprice(
    String rawSymbol,
    AutoCategory category, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final symbol = rawSymbol.trim().toUpperCase();
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    _storage.writeJson(_storage.pairActionFile, {
      'id': id,
      'action': 'reprice',
      'symbol': symbol,
      'category': category.wireValue,
    });
    _log('REPRICE requested: $symbol[${category.label}] (id=$id).');
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final result = _storage.readJsonObject(_storage.pairActionResultFile);
      if (result != null && '${result['id']}' == id) return result;
    }
    return {
      'ok': false,
      'symbol': symbol,
      'message': 'Timed out waiting for the engine to reprice this pair.',
    };
  }

  /// Removes any active pair-selection restriction, so the engine evaluates
  /// every Red-list pair again (its normal, unrestricted behavior) — this is
  /// "start / auto-run everything", not writing an empty selection (which
  /// would instead mean "restrict creation to nothing", blocking all opens).
  void clearSelection() {
    _storage.deleteFileIfExists(_storage.pendingCreateFile);
    _log('Selection cleared — engine will evaluate every Red-list pair again.');
  }

  Future<Map<String, dynamic>> report() async {
    await refreshSync();
    final grids = await _splitGrids();
    final closed = _pionex.available
        ? await _pionex.getClosedGrids()
        : const <Map<String, dynamic>>[];
    createdBots.load();
    final closedAuto = closed
        .where((o) => createdBots.isAppInitiated(o['buOrderId']?.toString()))
        .length;
    final bal = await balance();
    return {
      'usdt_free': bal.free,
      'usdt_total': bal.total,
      'running_total': grids.appRunning.length + grids.manualRunning.length,
      'auto_running': grids.appRunning,
      'manual_running': grids.manualRunning,
      'auto_closed_count': closedAuto,
    };
  }

  /// Converts a currently-running MANUAL grid into an app-tracked ("auto")
  /// one: from its next checkup onward, the engine treats it exactly like a
  /// bot it created itself - it moves into the Auto Bots report, and
  /// becomes eligible for the opposite-signal auto-close. The bot itself is
  /// never touched on Pionex; this only changes which list the app
  /// considers it in. Refuses anything not verified as a currently-running
  /// manual bot right now (Pionex is the source of truth, same as every
  /// other action here).
  Future<Map<String, dynamic>> convertManualToAuto(
    String buOrderId,
    AutoCategory category,
  ) async {
    await refreshSync();
    final grids = await _splitGrids();
    final bot = grids.manualRunning.cast<GridBot?>().firstWhere(
      (g) => g?.buOrderId == buOrderId,
      orElse: () => null,
    );
    if (bot == null) {
      return {'ok': false, 'reason': 'not-a-running-manual-bot'};
    }
    createdBots.load();
    createdBots.rememberBot(buOrderId);
    botCategories.setCategory(buOrderId, category);
    // Bug fixed 2026-09-10 (same audit as _stopOne's matching fix above):
    // `bot.base` is Pionex's raw futures base ("GALA.PERP"), but
    // autoManagedByCategory/retired both store bare names ("GALA") - both
    // calls below silently never matched the real base, so a bot converted
    // from manual to auto never actually became eligible for auto-checkup
    // (wrong key on the managed list) and never cleared a real stale "Last"
    // mark either.
    final bareBase = bot.base.replaceAll(
      RegExp(r'\.PERP$', caseSensitive: false),
      '',
    );
    autoManagedByCategory[category]!.addBase(bareBase);
    // Clears any stale "Last" mark from a previous life as an auto bot -
    // converting it back in is an explicit re-enable, it should never stay
    // silently blocked from ever reopening.
    retired.removeRetiredBases([(base: bareBase, category: category)]);
    _log(
      'Converted manual bot ${bot.pairKey} ($buOrderId) to an auto bot '
      '(${category.label}) - triggering an immediate Auto[${category.label}] '
      'checkup (that category\'s auto-managed bases only, never the full '
      'Red list). If its current signal is already opposite its own '
      'direction, it will be closed and reopened fresh on the very next '
      'check.',
    );
    // Per the user (2026-09-05/06): this base is now that category's
    // responsibility, so converting it triggers that category's OWN track -
    // never checkNow() (the full Red-list Checkup), which would scan every
    // other pair too.
    triggerAutoCheckupFor(category);
    return {'ok': true, 'pairKey': bot.pairKey};
  }

  /// The reverse of [convertManualToAuto]: removes this bot from the app's
  /// own tracking, so it moves to the Manual bots table and Auto stops
  /// watching it for opposite-signal close. The bot itself is never touched
  /// on Pionex - this only changes which list the app considers it in.
  /// Refuses anything not verified as a currently-running app-initiated bot
  /// right now.
  Future<Map<String, dynamic>> convertAutoToManual(String buOrderId) async {
    await refreshSync();
    final grids = await _splitGrids();
    final bot = grids.appRunning.cast<GridBot?>().firstWhere(
      (g) => g?.buOrderId == buOrderId,
      orElse: () => null,
    );
    if (bot == null) {
      return {'ok': false, 'reason': 'not-a-running-auto-bot'};
    }
    createdBots.load();
    createdBots.forgetBot(buOrderId);
    botCategories.forget(buOrderId);
    _log('Converted auto bot ${bot.pairKey} ($buOrderId) to manual.');
    return {'ok': true, 'pairKey': bot.pairKey};
  }

  /// Cancel a specific app-initiated running bot. Refuses anything not
  /// verified both app-initiated AND still actually running right now.
  Future<CancelOutcome> _stopOne(GridBot bot) async {
    createdBots.load();
    if (!createdBots.isAppInitiated(bot.buOrderId)) {
      _log(
        'REFUSED to stop ${bot.pairKey} (${bot.buOrderId}) - not app-initiated, manual bots are never touched.',
      );
      return CancelOutcome(
        bot: bot,
        acted: false,
        refused: true,
        reason: 'NOT app-initiated - manual bots are never touched',
      );
    }
    final current = await _pionex.getActiveGrids();
    final stillRunning = current.any(
      (o) => o['buOrderId']?.toString() == bot.buOrderId,
    );
    if (!stillRunning) {
      createdBots.forgetBot(bot.buOrderId);
      _log(
        '${bot.pairKey} (${bot.buOrderId}) was already not running - forgot it from the auto list.',
      );
      return CancelOutcome(bot: bot, acted: false, reason: 'not-running');
    }
    await _pionex.cancelFuturesGrid(buOrderId: bot.buOrderId);
    createdBots.forgetBot(bot.buOrderId);
    // Bug fixed 2026-09-10, live (see engine_service.dart's matching
    // reconciliation-path fix for the full incident): `bot.base` is
    // Pionex's own raw futures base, which always carries a ".PERP" suffix
    // (e.g. "GALA.PERP") - both calls below used to build the wrong key
    // ("GALA.PERPUSDT" for RiskGate, "GALA.PERP" for the auto-managed
    // list) instead of the real "GALAUSDT"/"GALA", leaving the RiskGate
    // per-symbol counter permanently stuck and the base never actually
    // removed from its auto-managed list on an explicit Stop.
    final bareBase = bot.base.replaceAll(
      RegExp(r'\.PERP$', caseSensitive: false),
      '',
    );
    // Unlike a signal-flip close, an explicit Stop means "done with this
    // pair right now" - it stops being auto-managed immediately, no
    // automatic reopen on the next auto-checkup (that bot's own category
    // only - the other 2 categories are untouched).
    botCategories.load();
    final category =
        botCategories.categoryOf(bot.buOrderId) ?? AutoCategory.oneHour;
    risk.closePosition('$bareBase${bot.quote}'.toUpperCase(), category);
    autoManagedByCategory[category]!.removeBase(bareBase);
    botCategories.forget(bot.buOrderId);
    _log('Stopped ${bot.pairKey} (${bot.buOrderId}) - cancelled on Pionex.');
    // Bug fixed 2026-09-11, live (confirmed via the user's own Pionex
    // History showing a loss for a bot the app recorded as profitable):
    // `bot` above is the snapshot fetched BEFORE cancelFuturesGrid ran -
    // re-read the TRUE final P/L now that cancellation has actually
    // completed, same call (`getGridPnl`) the auto-close and reconciliation
    // paths already use for exactly this reason. Never fatal if it fails -
    // the entry just falls back to the pre-cancel snapshot rather than
    // losing the whole Stop action over a read error.
    double? finalPnl;
    try {
      // Settled-poll (2026-09-19, per the user's own real-data audit - see
      // PionexClient.getSettledGridPnl's doc): a single immediate read
      // here recorded two real manually-stopped bots as losses when they
      // were actually profits, since Pionex hadn't finished settling
      // `totalRealizedProfit` yet at the moment this ran.
      finalPnl = await _pionex.getSettledGridPnl(bot.buOrderId);
    } catch (e) {
      _log('Stop ${bot.buOrderId}: final P/L re-read failed ($e) - using the pre-cancel snapshot instead.');
    }
    // Per the user (2026-09-20): "also mention P&L is 0 if terminated
    // this way, also mention if the bot was last or not" - matches the
    // same termination-context tail the engine appends to every history
    // entry it records (see EngineService._withTerminationContext); this
    // is the GUI's own separate process/instance, hence the small
    // duplication rather than a shared function.
    var detail = 'Stopped from the app.';
    if (finalPnl == 0) detail += ' P&L: \$0.00.';
    if (retired.isRetiredBase(bareBase, category)) {
      detail += ' Marked Last - will not auto-recreate.';
    }
    _recordHistory(
      BotHistoryEntry.fromBot(
        bot,
        kind: BotHistoryKind.terminated,
        detail: detail,
        realizedProfitOverride: finalPnl,
        category: category,
      ).withEntrySignal(stopReason: 'terminated_by_user'),
    );
    return CancelOutcome(bot: bot, acted: true);
  }

  /// Appends to the History screen's log (see [CoreStorage.botHistoryFile]).
  ///
  /// Bug fixed 2026-09-14 (see the matching fix in engine_service.dart's
  /// own `_recordHistory` for the full incident) - this repository and
  /// the engine's own reconciliation are separate processes that can each
  /// independently detect and record the SAME bot's closure. Skips if
  /// this exact buOrderId+kind is already recorded anywhere in history;
  /// the existing PNL settlement sweep still corrects the VALUE later if
  /// needed, this only stops it being logged more than once.
  void _recordHistory(BotHistoryEntry entry) {
    final already = _storage
        .readJsonl(_storage.botHistoryFile)
        .any(
          (e) =>
              e['buOrderId'] == entry.buOrderId &&
              e['kind'] == entry.kind.wireValue,
        );
    if (already) return;
    _storage.appendJsonl(_storage.botHistoryFile, entry.toJson());
  }

  List<BotHistoryEntry> history() =>
      _storage
          .readJsonl(_storage.botHistoryFile)
          .map(BotHistoryEntry.fromJson)
          .toList()
        ..sort((a, b) => b.ts.compareTo(a.ts));

  void deleteHistoryEntry(String id) {
    final remaining = _storage
        .readJsonl(_storage.botHistoryFile)
        .where((e) => e['id'] != id)
        .toList();
    _storage.writeJsonl(_storage.botHistoryFile, remaining);
  }

  void clearHistory() => _storage.writeJsonl(_storage.botHistoryFile, const []);

  /// Voice-alert feed (2026-09-17): every real TradingView-driven
  /// open/close decision, engine-written only - see [TradeStartEvent].
  List<TradeStartEvent> tradeStartEvents() =>
      _storage
          .readJsonl(_storage.tradeStartEventsFile)
          .map(TradeStartEvent.fromJson)
          .toList()
        ..sort((a, b) => b.ts.compareTo(a.ts));

  /// The 2 real voice-alert triggers (2026-09-17, per the user: replaced an
  /// earlier 4-tone design - direction is now folded into the "start"
  /// phrase itself, e.g. "start long XRP" / "close XRP", so there's no
  /// separate short/long trigger to mute independently any more).
  static const _soundTones = ['start', 'stop'];

  /// Per-trigger mute state for the voice-alert feature - true means muted.
  /// A trigger missing from the file defaults to unmuted (fresh
  /// install/first run).
  Map<String, bool> soundMuteState() {
    final raw = _storage.readJsonObject(_storage.soundSettingsFile) ?? const {};
    return {for (final tone in _soundTones) tone: raw[tone] == true};
  }

  void setSoundMuted(String tone, bool muted) {
    final current = soundMuteState();
    current[tone] = muted;
    _storage.writeJson(_storage.soundSettingsFile, current);
  }

  /// Auto bots card's profit/loss summary (2026-09-10, per the user) - sums
  /// [BotHistoryEntry.realizedProfit] across every history entry recorded
  /// since the last reset (see [resetPnlSummary]), split into profit/loss
  /// rather than netted, so the card can color each half differently.
  /// `since` is null until the user resets it once - "since start" means
  /// "since the beginning of bot-history.jsonl" until then.
  ///
  /// Also counts how many of those SAME entries landed strictly positive,
  /// strictly negative, or exactly zero (2026-09-11, per the user) - for the
  /// up/down/neutral counters shown under the sum. `successRatePercent` is
  /// `profitCount / (profitCount + lossCount) * 100` (neutral entries
  /// excluded from both sides, per the user's explicit choice) - null when
  /// there's no profit or loss entry yet to compute a rate from.
  ({
    double profit,
    double loss,
    double net,
    DateTime? since,
    int profitCount,
    int lossCount,
    int neutralCount,
    double? successRatePercent,
  })
  pnlSummary() {
    final resetAtMs = _storage.readJsonObject(_storage.pnlResetFile)?['reset_at_ms'] as int?;
    final since = resetAtMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(resetAtMs);
    var profit = 0.0;
    var loss = 0.0;
    var profitCount = 0;
    var lossCount = 0;
    var neutralCount = 0;
    for (final entry in history()) {
      if (since != null && entry.ts.isBefore(since)) continue;
      final pnl = entry.realizedProfit;
      if (pnl == null) continue;
      if (pnl > 0) {
        profit += pnl;
        profitCount++;
      } else if (pnl < 0) {
        loss += -pnl;
        lossCount++;
      } else {
        neutralCount++;
      }
    }
    final rateDenominator = profitCount + lossCount;
    return (
      profit: profit,
      loss: loss,
      net: profit - loss,
      since: since,
      profitCount: profitCount,
      lossCount: lossCount,
      neutralCount: neutralCount,
      successRatePercent: rateDenominator == 0
          ? null
          : profitCount / rateDenominator * 100,
    );
  }

  /// Per-pair, per-category breakdown of the same closed-since-reset
  /// entries [pnlSummary] sums as one grand total (2026-09-13, per the
  /// user: "add summary for each pair ... xrp: 3m / 2 T / 20$ ... T
  /// refers to trades"). Drives the new Summary screen, reached by
  /// tapping [PnlSummaryView]. Skips any entry with no [BotHistoryEntry
  /// .category] - only entries recorded before that field existed lack
  /// one; every entry recorded going forward always carries it.
  List<({String base, AutoCategory category, int trades, double net})>
  pnlByPairSummary() {
    final resetAtMs = _storage.readJsonObject(_storage.pnlResetFile)?['reset_at_ms'] as int?;
    final since = resetAtMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(resetAtMs);
    final byKey = <String, ({String base, AutoCategory category, int trades, double net})>{};
    for (final entry in history()) {
      if (since != null && entry.ts.isBefore(since)) continue;
      final pnl = entry.realizedProfit;
      final category = entry.category;
      if (pnl == null || category == null) continue;
      final base = entry.base
          .toUpperCase()
          .replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '');
      final key = '$base|${category.wireValue}';
      final existing = byKey[key];
      byKey[key] = (
        base: base,
        category: category,
        trades: (existing?.trades ?? 0) + 1,
        net: (existing?.net ?? 0) + pnl,
      );
    }
    final result = byKey.values.toList()
      ..sort(
        (a, b) => a.base == b.base
            ? a.category.wireValue.compareTo(b.category.wireValue)
            : a.base.compareTo(b.base),
      );
    return result;
  }

  /// Moves the profit/loss summary's cutoff to now - never touches
  /// `bot-history.jsonl` itself, so the History screen's permanent record
  /// is unaffected; only the Auto bots card's running total starts over.
  void resetPnlSummary() {
    _storage.writeJson(_storage.pnlResetFile, {
      'reset_at_ms': DateTime.now().millisecondsSinceEpoch,
    });
    _log('Auto bots profit/loss summary reset.');
  }

  /// Auto bots card's "waiting" list (2026-09-10, per the user) - a base
  /// the app is responsible for (on its category's auto-managed list) that
  /// doesn't currently have a real running bot, so the next auto-checkup
  /// pass will attempt to (re)open it. `investment` is the pending
  /// recycled amount from [CoreStorage.pendingInvestmentsFile] when one
  /// exists (per the user: "initial investment here is the recycled
  /// investment") - falling back to the pair's configured default only
  /// when nothing is actually pending (a base never closed yet, or its
  /// pending amount already got consumed by a just-succeeded reopen).
  /// Takes the already-fetched `appRunning` list from the same `status()`
  /// poll the rest of the dashboard uses - deliberately synchronous, no
  /// extra Pionex API call just for this display.
  List<({String base, AutoCategory category, double investment})>
  waitingBases(
    List<GridBot> appRunning, {
    List<String> triedBases = const [],
  }) {
    final runningByCategory = <AutoCategory, Set<String>>{};
    for (final g in appRunning) {
      final category = botCategories.categoryOf(g.buOrderId) ?? AutoCategory.oneHour;
      final bareBase = g.base
          .toUpperCase()
          .replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '');
      (runningByCategory[category] ??= {}).add(bareBase);
    }
    final pending =
        _storage.readJsonObject(_storage.pendingInvestmentsFile) ?? const {};
    // REVERSED AGAIN 2026-09-20, per the user ("once bot check[ed] last =
    // this current running is last, if it become not running, it should
    // not go to waiting"): the 2026-09-14 change below (kept a retired
    // base showing in Waiting once it stopped running) is now explicitly
    // reversed - a retired base that has actually finished running is
    // fully done, not "waiting" for anything (the reopen-refusal check in
    // `EngineService._manageGridPair`, `SKIP $symbol: retired`, means it
    // NEVER reopens on its own), so showing it here as if it were about to
    // is misleading. A retired base STILL running is unaffected (already
    // excluded above via `running.contains`, same as always) - this only
    // changes what happens once it actually stops.
    //
    // Original 2026-09-14 reasoning, kept for context: "even if the bot is
    // retired... it should be shown in waiting list" - a retired base
    // staying in the auto-managed file (retiring never removes it, only
    // stops it being auto-retried) was being hidden from this list
    // entirely, so it silently vanished with no visible explanation. That
    // tradeoff (also affecting Next Trade's knob blocked/yellow state via
    // `dashboard_screen.dart`'s `_activeCategoriesFor`) is no longer what
    // the user wants.
    final result = <({String base, AutoCategory category, double investment})>[];
    for (final category in allAutoCategories) {
      final managed = autoManagedByCategory[category]!.loadAutoManagedBases();
      final running = runningByCategory[category] ?? const <String>{};
      for (final base in managed) {
        if (running.contains(base)) continue;
        if (retired.isRetiredBase(base, category)) continue;
        final key = '$base|${category.wireValue}';
        final pendingAmount = (pending[key] as num?)?.toDouble();
        final investment =
            pendingAmount ?? pairInvestments.investmentOf('${base}USDT');
        result.add((base: base, category: category, investment: investment));
      }
    }
    // Per the user (2026-09-11): a pair the user explicitly clicked Start
    // on, but hasn't actually opened yet (still being checked, or paused
    // waiting for an Auto category's turn - see the same day's Auto-vs-
    // Start priority fix), should show here too, not just recycled bases
    // waiting for their next auto-checkup attempt. Deduped against what's
    // already listed above (same base+category never appears twice).
    final alreadyListed = result.map((r) => '${r.base}|${r.category.wireValue}').toSet();
    final startSymbols =
        (_storage.readJsonObject(_storage.startInProgressFile)?['remaining']
                as List?) ??
        const [];
    for (final raw in startSymbols) {
      final symbol = '$raw';
      final base = symbol
          .split(':')
          .last
          .split('/')
          .first
          .split('_')
          .first
          .replaceAll('USDT', '')
          .toUpperCase();
      final category = pairCategories.categoryOf(symbol);
      final key = '$base|${category.wireValue}';
      if (alreadyListed.contains(key)) continue;
      alreadyListed.add(key);
      result.add((
        base: base,
        category: category,
        investment: pairInvestments.investmentOf(symbol),
      ));
    }
    // Per the user (2026-09-12): "i want to see xrpusdt (problem pair) at
    // the last of wrap too" - the engine's own waiting-engine retry queue
    // already checks a base with a past failed attempt last (see the
    // `retryable.sort` in `_runWaitingEngine`); this applies the exact
    // same ordering to the GUI's chip row, using the same tried-base keys
    // (`"CATEGORY_WIRE_VALUE|BASE"`) the engine reports via
    // `EngineStatus.waitingEngineTriedBases`. Stable sort - only reorders
    // by "has a failed attempt or not", never re-orders two bases within
    // the same group relative to each other.
    final tried = triedBases.toSet();
    result.sort((a, b) {
      final aTried = tried.contains(
        '${a.category.wireValue}|${a.base.toUpperCase()}',
      );
      final bTried = tried.contains(
        '${b.category.wireValue}|${b.base.toUpperCase()}',
      );
      if (aTried == bTried) return 0;
      return aTried ? 1 : -1;
    });
    return result;
  }

  /// Per-row "stop" toggle on the Waiting list (2026-09-15, per the user:
  /// "i want you to add a toggle per each waiting trade to stop it").
  /// Unlike [stopSelected]/[stopByBases], this base has no running bot to
  /// cancel on Pionex yet - it just stops being the app's responsibility,
  /// same principle an explicit Stop already applies to a running bot
  /// (see [_stopOne]'s matching `removeBase` call): done with this pair
  /// right now, no automatic (re)open on the next waiting-engine/
  /// auto-checkup pass. Also drops any pending recycled investment for
  /// this exact base+category so a future Start starts clean rather than
  /// silently reusing a stale amount.
  Future<void> stopWaitingBase(String base, AutoCategory category) async {
    final bareBase = base.toUpperCase();
    autoManagedByCategory[category]!.removeBase(bareBase);
    final pending = Map<String, dynamic>.from(
      _storage.readJsonObject(_storage.pendingInvestmentsFile) ?? const {},
    );
    final key = '$bareBase|${category.wireValue}';
    if (pending.remove(key) != null) {
      _storage.writeJson(_storage.pendingInvestmentsFile, pending);
    }
    _log('Stopped waiting: $bareBase/${category.label} - removed from auto-management, no more retry attempts.');
  }

  /// Per-row "thunder" toggle on the Waiting list (2026-09-15, per the
  /// user: "add thunder icon... once user click on it, it is started on
  /// spot and not waiting start signal to occur"). Routes through the
  /// same [requestPairAction] plumbing every other single-symbol pair
  /// action uses - the engine's own `_pairActionIgnite` does the real
  /// work (relaxed signal check, same open path as any other real open -
  /// once opened, this base is a completely normal auto-managed bot with
  /// no special tracking, per the user's explicit confirmation).
  Future<Map<String, dynamic>> igniteBase(
    String base,
    AutoCategory category,
  ) => requestPairAction('ignite', '${base.toUpperCase()}USDT');

  Future<List<CancelOutcome>> stopAll() async {
    final grids = await _splitGrids();
    _log(
      'Stop-all requested: ${grids.appRunning.length} app-initiated grid(s) targeted.',
    );
    final results = <CancelOutcome>[];
    for (final bot in grids.appRunning) {
      results.add(await _stopOne(bot));
    }
    return results;
  }

  /// Same as [stopSelected], but for callers that only have bases (like the
  /// Auto Bots report, which has no buOrderId of its own) - resolves each
  /// base to its currently-running app-initiated bot first.
  Future<List<CancelOutcome>> stopByBases(List<String> bases) async {
    final wanted = bases.map((b) => b.toUpperCase()).toSet();
    final grids = await _splitGrids();
    final ids = grids.appRunning
        .where((g) => wanted.contains(g.base.toUpperCase()))
        .map((g) => g.buOrderId)
        .toList();
    return stopSelected(ids);
  }

  Future<List<CancelOutcome>> stopSelected(List<String> buOrderIds) async {
    _log('Stop-selected requested: ${buOrderIds.join(', ')}.');
    final grids = await _splitGrids();
    final results = <CancelOutcome>[];
    for (final id in buOrderIds) {
      final bot =
          grids.appRunning.cast<GridBot?>().firstWhere(
            (g) => g?.buOrderId == id,
            orElse: () => null,
          ) ??
          grids.manualRunning.cast<GridBot?>().firstWhere(
            (g) => g?.buOrderId == id,
            orElse: () => null,
          );
      if (bot == null) continue;
      results.add(await _stopOne(bot));
    }
    return results;
  }

  /// Gear-menu bot actions (2026-09-18, per the user: "for auto bots and
  /// manual bots, i want you to add gear icon per each pair" - Adjust
  /// margin/Add investment/Take Profit/Stop Loss/Stop, matching Pionex's
  /// own per-bot "More" menu). Every action here is a direct, explicit,
  /// single-bot GUI action the user themselves tapped through a
  /// confirmation - NOT the app's own autonomous management, so (unlike
  /// [_stopOne]'s bulk-Stop path) these deliberately work on a manual bot
  /// too, per the user's explicit "auto bots and manual bots" scope. Every
  /// mutating call is preceded by its own dry-run check (Pionex's
  /// `adjustParamsCheck`), confirmed live to genuinely validate the
  /// request rather than rubber-stamp it.
  Future<String> _futuresSymbolFor(GridBot bot) async {
    final base = bot.base
        .toUpperCase()
        .replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '');
    return '${base}_${bot.quote.toUpperCase()}_PERP';
  }

  Future<double> _openPriceFor(GridBot bot) async {
    final symbol = await _futuresSymbolFor(bot);
    final price = await _pionex.getTickerPrice(symbol);
    return price ?? bot.currentPrice ?? bot.entryPrice ?? 0;
  }

  Future<Map<String, dynamic>> checkAdjustTpSl({
    required GridBot bot,
    String? profitStopType,
    String? profitStop,
    bool? stopProfitEnabled,
    String? lossStopType,
    String? lossStop,
    bool? stopLossEnabled,
  }) async => _pionex.checkAdjustFuturesGridParams(
    buOrderId: bot.buOrderId,
    openPrice: await _openPriceFor(bot),
    top: '${bot.top}',
    bottom: '${bot.bottom}',
    row: bot.row ?? 3,
    profitStopType: profitStopType,
    profitStop: profitStop,
    stopProfitEnabled: stopProfitEnabled,
    lossStopType: lossStopType,
    lossStop: lossStop,
    stopLossEnabled: stopLossEnabled,
  );

  Future<void> adjustTpSl({
    required GridBot bot,
    String? profitStopType,
    String? profitStop,
    bool? stopProfitEnabled,
    String? lossStopType,
    String? lossStop,
    bool? stopLossEnabled,
  }) async {
    await _pionex.adjustFuturesGridParams(
      buOrderId: bot.buOrderId,
      openPrice: await _openPriceFor(bot),
      top: '${bot.top}',
      bottom: '${bot.bottom}',
      row: bot.row ?? 3,
      profitStopType: profitStopType,
      profitStop: profitStop,
      stopProfitEnabled: stopProfitEnabled,
      lossStopType: lossStopType,
      lossStop: lossStop,
      stopLossEnabled: stopLossEnabled,
    );
    _log(
      'Gear menu: ${bot.pairKey} (${bot.buOrderId}) TP/SL updated - '
      '${profitStopType != null ? "profit=$profitStop ($profitStopType, enabled=$stopProfitEnabled) " : ""}'
      '${lossStopType != null ? "loss=$lossStop ($lossStopType, enabled=$stopLossEnabled)" : ""}',
    );
  }

  Future<Map<String, dynamic>> checkAdjustMargin({
    required GridBot bot,
    required double extraMarginAmount,
  }) async => _pionex.checkAdjustFuturesGridParams(
    buOrderId: bot.buOrderId,
    openPrice: await _openPriceFor(bot),
    top: '${bot.top}',
    bottom: '${bot.bottom}',
    row: bot.row ?? 3,
    extraMarginAmount: extraMarginAmount,
  );

  Future<void> adjustMargin({
    required GridBot bot,
    required double extraMarginAmount,
  }) async {
    await _pionex.adjustFuturesGridParams(
      buOrderId: bot.buOrderId,
      openPrice: await _openPriceFor(bot),
      top: '${bot.top}',
      bottom: '${bot.bottom}',
      row: bot.row ?? 3,
      extraMarginAmount: extraMarginAmount,
    );
    _log(
      'Gear menu: ${bot.pairKey} (${bot.buOrderId}) margin ${extraMarginAmount >= 0 ? "added" : "withdrawn"}: ${extraMarginAmount.abs()} USDT.',
    );
  }

  Future<Map<String, dynamic>> checkAddInvestment({
    required GridBot bot,
    required double quoteInvestment,
  }) async => _pionex.checkInvestInFuturesGrid(
    buOrderId: bot.buOrderId,
    openPrice: await _openPriceFor(bot),
    quoteInvestment: quoteInvestment,
  );

  Future<void> addInvestment({
    required GridBot bot,
    required double quoteInvestment,
  }) async {
    await _pionex.investInFuturesGrid(
      buOrderId: bot.buOrderId,
      openPrice: await _openPriceFor(bot),
      quoteInvestment: quoteInvestment,
    );
    _log(
      'Gear menu: ${bot.pairKey} (${bot.buOrderId}) investment added: $quoteInvestment USDT.',
    );
  }

  /// Explicit, single-bot manual-bot Stop from the gear menu - deliberately
  /// NOT [_stopOne] (which refuses anything not app-initiated, and does
  /// auto-managed-list/RiskGate bookkeeping that doesn't apply to a bot the
  /// app never tracked). Manual bots never touch [createdBots]/
  /// [autoManagedByCategory]/[botCategories] in the first place, so a
  /// manual Stop is just the raw cancel, matching what tapping "Stop" in
  /// Pionex's own app would do.
  Future<void> stopManualBotExplicit(GridBot bot) async {
    await _pionex.cancelFuturesGrid(buOrderId: bot.buOrderId);
    double? finalPnl;
    try {
      // Settled-poll, same fix and reason as stopSelected's own re-read
      // above (2026-09-19, per the user's real-data audit).
      finalPnl = await _pionex.getSettledGridPnl(bot.buOrderId);
    } catch (_) {}
    _recordHistory(
      BotHistoryEntry.fromBot(
        bot,
        kind: BotHistoryKind.terminated,
        detail: 'Stopped manually via the gear menu.',
        realizedProfitOverride: finalPnl,
      ).withEntrySignal(stopReason: 'terminated_by_user'),
    );
    _log('Gear menu: manually stopped ${bot.pairKey} (${bot.buOrderId}).');
  }

  /// select: after picking which pairs to create, write the selection so the
  /// running engine creates grids ONLY for those pairs next cycle (given a
  /// valid signal + funds), then triggers an immediate checkup.
  Future<Map<String, dynamic>> select(List<String> bases) async {
    await refreshSync();
    final pairs = <String>[];
    final seen = <String>{};
    for (final raw in bases) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      final normalized =
          RegExp(r'\.PERP$', caseSensitive: false).hasMatch(trimmed)
          ? trimmed.toUpperCase()
          : '${trimmed.toUpperCase()}.PERP';
      if (seen.add(normalized)) pairs.add(normalized);
    }
    _storage.writeJson(_storage.pendingCreateFile, pairs);
    _log(
      'Selection saved: restricting next creation to ${pairs.isEmpty ? '(none)' : pairs.join(', ')}.',
    );
    checkNow();
    return {'selected_pairs': pairs, 'trigger_engine': true};
  }

  /// Start (2026-09-05 correction): does NOT run a full Red-list checkup -
  /// it's an on-spot check of ONLY the given base(s), fired as a
  /// Controls-screen-style pair action so the engine borrows the chart
  /// briefly and automatically resumes whatever Checkup/Auto-checkup pass
  /// it interrupted once done.
  ///
  /// Bug fixed 2026-09-10: this used to be fire-and-forget (write the
  /// request file, return immediately), which meant the Start button's
  /// own `busy`/loading state - driven by how long the wrapping `_run`
  /// call takes - collapsed back to "idle" within a fraction of a second,
  /// long before the engine had actually finished opening anything. Per
  /// the user, the button must show a loading spinner and stay disabled
  /// for the pair(s)' actual duration. Same blocking poll-by-id pattern as
  /// [requestPairAction], just for the plural `symbols` shape 'start'
  /// uses. `timeout` scales with symbol count since each selected pair is
  /// checked/opened one at a time on the single shared TradingView chart -
  /// six pairs can genuinely take several minutes, especially if one hits
  /// the indicator wait-ladder or a CDP hiccup.
  Future<Map<String, dynamic>> requestStartAction(
    List<String> symbols, {
    Duration? timeout,
    // Per the user (2026-09-11): "add per-pair feedback as each one
    // resolves, instead of one big summary at the end" - fired once per
    // symbol, the moment the engine's own live progress file
    // (CoreStorage.startInProgressFile) shows it decided, rather than
    // waiting for the whole batch (which can now genuinely take minutes,
    // since Auto categories can pause it) to finish before the caller
    // hears anything at all.
    void Function(String symbol, {required bool opened, String? reason})?
    onSymbolResolved,
  }) async {
    // Per the user (2026-09-05): pass symbols through exactly as the Red
    // List names them - no rebuilding, no qualifySymbol guessing.
    final clean = symbols
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    _storage.writeJson(_storage.pairActionFile, {
      'id': id,
      'action': 'start',
      'symbols': clean,
    });
    _log(
      'Start requested for ${clean.join(', ')} (id=$id) - checking on the '
      'spot; whatever else is running resumes once done.',
    );
    final effectiveTimeout =
        timeout ?? Duration(seconds: 30 + 45 * clean.length);
    final deadline = DateTime.now().add(effectiveTimeout);
    final alreadyNotified = <String>{};
    void notifyNewOutcomes(Map<String, dynamic>? progress) {
      if (onSymbolResolved == null || progress == null) return;
      if ('${progress['id']}' != id) return;
      for (final s
          in ((progress['opened'] as List?) ?? const []).cast<String>()) {
        if (alreadyNotified.add(s)) onSymbolResolved(s, opened: true);
      }
      final skippedMap =
          ((progress['skipped'] as Map?) ?? const {}).cast<String, dynamic>();
      for (final entry in skippedMap.entries) {
        if (alreadyNotified.add(entry.key)) {
          onSymbolResolved(entry.key, opened: false, reason: '${entry.value}');
        }
      }
    }

    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      notifyNewOutcomes(
        _storage.readJsonObject(_storage.startInProgressFile),
      );
      final result = _storage.readJsonObject(_storage.pairActionResultFile);
      if (result != null && '${result['id']}' == id) {
        // Covers a Start that finished within a single, never-paused pass
        // (fast enough that the progress file above never got polled
        // mid-flight) - every symbol's outcome still gets its own
        // callback, from the final result instead.
        notifyNewOutcomes(result);
        return result;
      }
    }
    return {
      'ok': false,
      'symbols': clean,
      'message':
          'Timed out waiting for the engine to respond — it may still be '
          'working through the selection. Check the Auto bots list shortly.',
    };
  }

  /// refreshSync: prune created-bots.json against what's ACTUALLY running on
  /// Pionex — Pionex is the source of truth. Any recorded app bot no longer
  /// running, or manually paused/canceling, is dropped (memory-only; Pionex
  /// is never touched). Called automatically before status/report/select.
  Future<Map<String, dynamic>> refreshSync() async {
    createdBots.load();
    final before = createdBots.listAppBots().length;
    final running = _pionex.available
        ? await _pionex.getActiveGrids()
        : const <Map<String, dynamic>>[];
    final runningIds = <String>{};
    final interruptedIds = <String>{};
    for (final o in running) {
      final id = (o['buOrderId'] ?? (o['buOrderData'] as Map?)?['buOrderId'])
          ?.toString();
      if (id == null) continue;
      runningIds.add(id);
      final status =
          (o['status'] ?? (o['buOrderData'] as Map?)?['status'] ?? '')
              .toString()
              .toLowerCase();
      if (o['canceling'] == true || status == 'paused') interruptedIds.add(id);
    }
    final removed = <String>[];
    for (final id in createdBots.listAppBots()) {
      if (runningIds.contains(id) && !interruptedIds.contains(id)) continue;
      removed.add(id);
      createdBots.forgetBot(id);
    }
    return {
      'removed': removed,
      'before': before,
      'remaining': createdBots.listAppBots().length,
      'running': running.length,
    };
  }

  Set<String> retiredBases() => retired.loadRetiredBases();

  /// Which rotating cycle-marker index [base]/[category] was last actually
  /// checked under, if ever this session (2026-09-12, per the user) - null
  /// means "not checked since the engine last restarted." Compare against
  /// `EngineStatus.statusFor(category).cycleMarkerIndex` (the CURRENT
  /// marker) to tell whether a row was covered in the latest sweep.
  int? cycleMarkerFor(String base, AutoCategory category) {
    final map = _storage.readJsonObject(_storage.cycleMarkersFile);
    final value = map?['${base.toUpperCase()}|${category.wireValue}'];
    return (value as num?)?.toInt();
  }

  /// Same idea as [cycleMarkerFor], for the Checkup track (2026-09-12, per
  /// the user) - null means "not checked yet in the sweep running right
  /// now" (or never checked this session).
  int? checkupCycleMarkerFor(String base) {
    final map = _storage.readJsonObject(_storage.cycleMarkersFile);
    final value = map?['${base.toUpperCase()}|CHECKUP'];
    return (value as num?)?.toInt();
  }

  Set<String> retire(List<String> bases, AutoCategory category) {
    final result = retired.addRetiredBases(
      bases.map((b) => (base: b, category: category)),
    );
    _log(
      'Retired: ${bases.join(', ')} (${category.label}). Full retired list: ${result.join(', ')}.',
    );
    return result;
  }

  Future<Set<String>> unretire(List<String> bases, AutoCategory category) async {
    final result = retired.removeRetiredBases(
      bases.map((b) => (base: b, category: category)),
    );
    // Clean up any now-stale "Last" history entry (2026-09-24, per the
    // user: "if the bot is tagged last but not yet terminated, then it
    // should not be there in history" - confirmed live: a SOL bot tagged
    // Last then untagged while still genuinely running had its Last entry
    // sitting in History forever, making a still-open bot look like a
    // closed one). A `kind: last` entry is recorded the moment a base is
    // tagged, describing an expected future outcome ("will finish
    // naturally") - reversing the tag before that actually happens means
    // the entry no longer describes reality and should go with it. Only
    // removes the entry for a base whose bot is STILL RUNNING right now -
    // if the bot already closed (Last genuinely took effect), its Last
    // entry is real history and must stay untouched.
    try {
      final grids = await _splitGrids();
      final bareBases = bases.map((b) => b.trim().toUpperCase()).toSet();
      for (final bot in grids.appRunning) {
        final bareBase = bot.base
            .toUpperCase()
            .replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '');
        if (!bareBases.contains(bareBase)) continue;
        final botCategory =
            botCategories.categoryOf(bot.buOrderId) ?? AutoCategory.oneHour;
        if (botCategory != category) continue;
        final staleEntries = history().where(
          (e) => e.kind == BotHistoryKind.last && e.buOrderId == bot.buOrderId,
        );
        for (final e in staleEntries) {
          deleteHistoryEntry(e.id);
          _log(
            'Unretired ${bot.pairKey} (${category.label}) while its bot is still running - removed the now-stale "Last" history entry.',
          );
        }
      }
    } catch (e) {
      _log('Unretire: could not check for a stale Last history entry ($e).');
    }
    _log(
      'Unretired: ${bases.join(', ')} (${category.label}). Full retired list: ${result.isEmpty ? '(none)' : result.join(', ')}.',
    );
    return result;
  }

  /// last-select: validate the given bases are currently-running AUTO grids,
  /// then retire them (they finish naturally; the engine will never
  /// auto-recreate that pair again unless explicitly re-selected/unretired).
  Future<Map<String, dynamic>> lastSelect(List<String> bases) async {
    // Bug fixed 2026-09-11 (same audit as every other retired-base
    // mismatch this session): both sides here used to be Pionex's raw,
    // ".PERP"-suffixed base ("LINK.PERP") - they matched each other fine,
    // but that meant the suffixed form got written straight into
    // RetiredStore, breaking the "bare name" invariant every OTHER
    // retired-base comparison site (GridsTable's "Last" tag, etc) relies on.
    // Stripping here keeps RetiredStore bare, as it's supposed to be.
    String bare(String b) =>
        b.trim().toUpperCase().replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '');
    final clean = bases.map(bare).where((b) => b.isNotEmpty).toSet();
    final grids = await _splitGrids();
    final autoByBase = {
      for (final g in grids.appRunning) bare(g.base): g,
    };
    final valid = clean.where(autoByBase.containsKey).toList();
    final invalid = clean.where((b) => !autoByBase.containsKey(b)).toList();
    if (valid.isEmpty) {
      _log(
        'Last-select: none of ${clean.join(', ')} is a currently-running auto grid - nothing retired.',
      );
      return {
        'ok': false,
        'reason': 'none-are-auto',
        'checked': clean.toList(),
      };
    }
    final newSet = retired.addRetiredBases(
      valid.map(
        (base) => (
          base: base,
          category:
              botCategories.categoryOf(autoByBase[base]!.buOrderId) ??
              AutoCategory.oneHour,
        ),
      ),
    );
    for (final base in valid) {
      _recordHistory(
        BotHistoryEntry.fromBot(
          autoByBase[base]!,
          kind: BotHistoryKind.last,
          detail: 'Retired — will finish naturally and never auto-recreate.',
          category: botCategories.categoryOf(autoByBase[base]!.buOrderId),
        ),
      );
    }
    _log(
      'Last-select: retired ${valid.join(', ')} to finish naturally and never auto-recreate.${invalid.isEmpty ? '' : ' Skipped (not auto): ${invalid.join(', ')}.'}',
    );
    return {
      'ok': true,
      'retired_now': valid,
      'not_auto_skipped': invalid,
      'retired_all': newSet.toList()..sort(),
    };
  }

  /// [lastSelect]'s per-bot equivalent (2026-09-20, live bug fix, per the
  /// user: checked BTC's 1H row specifically and clicked Last, but the
  /// checkbox stayed stuck checked/disabled forever). Root cause:
  /// [lastSelect] only ever took bare base names, and its internal
  /// `autoByBase` map is keyed by bare base alone - with two independent
  /// running bots sharing the same base under different categories (e.g.
  /// BTC 5m and BTC 1H, both real and simultaneous, confirmed live), that
  /// map silently collapsed to whichever one won the key collision,
  /// retiring the WRONG bot regardless of which row's checkbox was
  /// actually checked in the GUI. This variant takes the exact
  /// `buOrderId`s the GridsTable rows actually represent, so there is no
  /// ambiguity: every row (any base+category combination) is targeted
  /// individually. GridsTable's own `onBulkLast` is the only caller.
  Future<Map<String, dynamic>> lastSelectByIds(List<String> buOrderIds) async {
    final grids = await _splitGrids();
    final autoById = {for (final g in grids.appRunning) g.buOrderId: g};
    final valid = buOrderIds.where(autoById.containsKey).toList();
    final invalid = buOrderIds.where((id) => !autoById.containsKey(id)).toList();
    if (valid.isEmpty) {
      _log('Last-select: none of the selected bot(s) is a currently-running auto grid - nothing retired.');
      return {'ok': false, 'reason': 'none-are-auto', 'checked': buOrderIds};
    }
    String bareBaseOf(GridBot bot) => bot.base
        .toUpperCase()
        .replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '');
    final newSet = retired.addRetiredBases(
      valid.map(
        (id) => (
          base: bareBaseOf(autoById[id]!),
          category: botCategories.categoryOf(id) ?? AutoCategory.oneHour,
        ),
      ),
    );
    final retiredLabels = <String>[];
    for (final id in valid) {
      final bot = autoById[id]!;
      final category = botCategories.categoryOf(id) ?? AutoCategory.oneHour;
      retiredLabels.add('${bareBaseOf(bot)} (${category.label})');
      _recordHistory(
        BotHistoryEntry.fromBot(
          bot,
          kind: BotHistoryKind.last,
          detail: 'Retired — will finish naturally and never auto-recreate.',
          category: category,
        ),
      );
    }
    _log(
      'Last-select: retired ${retiredLabels.join(', ')} to finish naturally and never auto-recreate.${invalid.isEmpty ? '' : ' Skipped (not auto): ${invalid.length} bot(s).'}',
    );
    return {
      'ok': true,
      'retired_now': valid,
      'not_auto_skipped': invalid,
      'retired_all': newSet.toList()..sort(),
    };
  }

  /// buOrderIds among [bots] currently tagged for "Stop Loss Lock"
  /// (2026-09-22, per the user: "add a disable toggle same as last toggle")
  /// - resolves each bot's own tag correctly regardless of whether it's
  /// auto (base+category composite key) or manual (buOrderId key), so
  /// [GridsTable] itself never needs to know the difference; it just checks
  /// this set per row, same as [lastMarkedBases]'s own bare-key matching.
  Set<String> stopLossLockedIds(List<GridBot> bots) {
    final ids = <String>{};
    for (final bot in bots) {
      if (bot.appInitiated) {
        final bareBase = bot.base
            .toUpperCase()
            .replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '');
        final category =
            botCategories.categoryOf(bot.buOrderId) ?? AutoCategory.oneHour;
        if (stopLossLock.isTaggedAuto(bareBase, category)) ids.add(bot.buOrderId);
      } else if (stopLossLock.manualCategory(bot.buOrderId) != null) {
        ids.add(bot.buOrderId);
      }
    }
    return ids;
  }

  /// Tags/untags bot(s) for "Stop Loss Lock" (2026-09-22, per the user's
  /// exact spec) - [GridsTable]'s own gear-menu equivalent of
  /// [lastSelectByIds]. Auto bots (found in `appRunning`) are tagged by
  /// their own (base, category) - the standing composite-key convention,
  /// persisting across recycles just like a Last retirement. Manual bots
  /// (found in `manualRunning`) have no inherent category, so
  /// [manualCategory] is required whenever enabling one - the SAME picked
  /// timeframe applies to every manual bot in this one call, matching how
  /// every other bulk action in this app already applies one choice to a
  /// whole selection at once.
  Future<Map<String, dynamic>> stopLossLockSelect(
    List<String> buOrderIds, {
    required bool enable,
    AutoCategory? manualCategory,
  }) async {
    final grids = await _splitGrids();
    final autoById = {for (final g in grids.appRunning) g.buOrderId: g};
    final manualById = {for (final g in grids.manualRunning) g.buOrderId: g};
    final affected = <String>[];
    final skipped = <String>[];
    for (final id in buOrderIds) {
      final autoBot = autoById[id];
      if (autoBot != null) {
        final bareBase = autoBot.base
            .toUpperCase()
            .replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '');
        final category = botCategories.categoryOf(id) ?? AutoCategory.oneHour;
        if (enable) {
          stopLossLock.tagAuto(bareBase, category);
        } else {
          stopLossLock.untagAuto(bareBase, category);
        }
        affected.add('$bareBase (${category.label})');
        continue;
      }
      final manualBot = manualById[id];
      if (manualBot != null) {
        if (enable) {
          if (manualCategory == null) {
            skipped.add(id);
            continue;
          }
          stopLossLock.tagManual(id, manualCategory);
        } else {
          stopLossLock.untagManual(id);
        }
        affected.add('${manualBot.tickerSymbol} (manual, ${(manualCategory ?? stopLossLock.manualCategory(id))?.label ?? '?'})');
        continue;
      }
      skipped.add(id);
    }
    if (affected.isEmpty) {
      return {'ok': false, 'reason': 'none-resolved', 'checked': buOrderIds};
    }
    _log(
      '${enable ? 'Stop Loss Lock enabled' : 'Stop Loss Lock disabled'} for ${affected.join(', ')}.',
    );
    return {'ok': true, 'affected': affected, 'skipped': skipped};
  }
}
