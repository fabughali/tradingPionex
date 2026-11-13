import 'dart:async';
import 'dart:convert';
import 'dart:io' show InternetAddress;

import '../../core/core_api.dart';
import '../../core/core_constants.dart';
import '../../core/core_storage.dart';
import '../brain/brain_store.dart';
import '../identity/auto_managed_store.dart';
import '../identity/bot_category_store.dart';
import '../identity/created_bots_store.dart';
import '../identity/entry_signal_store.dart';
import '../identity/favorite_trades_store.dart';
import '../identity/pair_category_store.dart';
import '../identity/pair_investment_store.dart';
import '../identity/stop_loss_lock_state_store.dart';
import '../identity/stop_loss_lock_store.dart';
import '../identity/tp_sl_ratchet_store.dart';
import '../identity/widen_applied_store.dart';
import '../identity/retired_store.dart';
import '../models/auto_category.dart';
import '../logging/app_logger.dart';
import '../models/app_config.dart';
import '../models/bot_history_entry.dart';
import '../models/trade_start_event.dart';
import '../models/signal.dart';
import '../models/trade_direction.dart';
import '../models/engine_status.dart';
import '../models/grid_bot.dart';
import '../models/liquidation_levels.dart';
import '../models/open_entry.dart';
import '../models/preview_grid_pair.dart';
import '../models/running_bots_report.dart';
import '../models/range_result.dart';
import '../pionex/pionex_client.dart';
import '../pionex/price_momentum.dart';
import '../risk/risk_gate.dart';
import 'sll_rules.dart';
import '../technique/grid_count.dart';
import '../technique/liquidation.dart';
import '../technique/shrink_retry.dart';
import '../technique/candle_closed.dart';
import '../technique/trending.dart';
import '../technique/worm10_decision.dart';
import '../technique/worm10_pionex.dart';
import '../technique/zigzag_range.dart';
import '../tradingview/cdp_client.dart';
import '../tradingview/chart_state.dart';
import '../tradingview/enforce.dart';
import '../tradingview/launch.dart';
import '../tradingview/signals_reader.dart';
import '../tradingview/tv_sync.dart';
import '../tradingview/watchlist_reader.dart';

/// The app brain — the sole trading-decision authority (PRD §1/§10 rule 1).
/// Ported from bot-grid.js's 5s mainLoop, faithfully reproducing every
/// user-confirmed rule: candle gate anchored to the chart's own bar time,
/// re-entrancy guard + 600s watchdog, sleep/awake health-recovery checkups,
/// the indicator load retry ladder, funds/selection scoping, the same-id
/// close guard, auto-reserve 2-step, and the liquidation-avoidance shrink
/// retry. Meant to run as its own long-lived process (see bin/engine.dart) —
/// the GUI never embeds this class; it only reads the status/log/state
/// files it writes and toggles the PAUSE/STOP/CHECKNOW control files,
/// exactly like the original engine + its opencode helper scripts
/// communicated only through files on disk.
class EngineService {
  EngineService({
    required this.config,
    required this.storage,
    required this.logger,
  }) {
    risk = RiskGate(storage, config.risk);
    createdBots = CreatedBotsStore(storage);
    widenApplied = WidenAppliedStore(storage);
    retired = RetiredStore(storage);
    autoManaged = AutoManagedStore(storage);
    botCategories = BotCategoryStore(storage);
    tpSlRatchet = TpSlRatchetStore(storage);
    stopLossLock = StopLossLockStore(storage);
    stopLossLockState = StopLossLockStateStore(storage);
    favoriteTrades = FavoriteTradesStore(storage);
    entrySignalStore = EntrySignalStore(storage);
    pairCategories = PairCategoryStore(storage);
    pairInvestments = PairInvestmentStore(storage);
    autoManagedByCategory = {
      for (final c in allAutoCategories)
        c: c == AutoCategory.oneHour
            ? autoManaged
            : AutoManagedStore(
                storage,
                filePath: storage.autoManagedBasesFileFor(c),
              ),
    };
    brain = BrainStore(storage);
    final env = storage.readEnvFile();
    pionex = PionexClient(
      apiKey: env['PIONEX_API_KEY'] ?? '',
      apiSecret: env['PIONEX_API_SECRET'] ?? '',
      onLog: logger.log,
    );
  }

  final AppConfig config;
  final CoreStorage storage;
  final AppLogger logger;
  late final RiskGate risk;
  late final CreatedBotsStore createdBots;
  late final WidenAppliedStore widenApplied;
  late final RetiredStore retired;
  late final AutoManagedStore autoManaged;

  /// Per-category equivalent of [autoManaged] (2026-09-07) - the 1H entry
  /// IS [autoManaged] (same instance, same file), 1m/1D get their own.
  late final Map<AutoCategory, AutoManagedStore> autoManagedByCategory;
  late final BotCategoryStore botCategories;
  late final TpSlRatchetStore tpSlRatchet;

  /// Which pairs/bots are governed by "Stop Loss Lock" (2026-09-22, per the
  /// user) instead of the normal TP/SL ratchet - see [StopLossLockStore]'s
  /// own doc for the full design.
  late final StopLossLockStore stopLossLock;

  /// Per-buOrderId Stop Loss Lock state (the highest profit-floor SL
  /// percentage locked in so far) - see [StopLossLockStateStore].
  late final StopLossLockStateStore stopLossLockState;
  late final FavoriteTradesStore favoriteTrades;
  late final EntrySignalStore entrySignalStore;
  late final PairCategoryStore pairCategories;
  late final PairInvestmentStore pairInvestments;
  late final BrainStore brain;
  late final PionexClient pionex;

  /// Set immediately before any early-return skip inside `_manageGridPair`'s
  /// create branch (funds-restricted, selection-blocked, RiskGate-blocked),
  /// cleared at the top of every call - lets `_pairActionStart` report the
  /// REAL reason a Start didn't open a pair instead of a generic guess.
  /// Fixed 2026-09-10: a live Start on 4 pairs opened 2 and reported the
  /// other 2 as "no valid signal or insufficient funds right now" when the
  /// actual, already-logged reason was `GATE BLOCKED grid for X: Daily
  /// trade cap reached: 10/10` - a real, specific, actionable RiskGate
  /// limit that the generic catch-all message threw away.
  String? _lastCreateSkipReason;


  /// One-time raw-order dump for the TP/SL field audit - see the log call
  /// site in _refreshActiveGrids.
  bool _loggedRawOrderSample = false;

  /// Temporary, one-time dump of every loaded custom script's real
  /// scriptIdPart - see the log call site in _ensureCustomScripts. Added
  /// 2026-09-16 (per the user: "instead of using combined indicator, i
  /// want you to use spy_9_26") to find spy_9_26's actual hash live,
  /// since this environment has no direct way to query TradingView's CDP
  /// port itself - remove once that hash is confirmed and hardcoded into
  /// chart_state.dart's `customScripts`.
  bool _loggedCustomScriptSources = false;

  /// Temporary, one-time diagnostic dump of one specific bot's raw data -
  /// see the log call site in _refreshActiveGrids. Added 2026-09-16, per
  /// the user pointing at buOrderId b1574697-... to illustrate "running
  /// vs. working" - remove once that check is done.
  bool _loggedSpecificOrderSample = false;

  /// True once [RiskGate]'s one-time symbol+category key migration has run
  /// - see the resync call site in `_refreshActiveGrids`.
  bool _riskGateResynced = false;

  /// "Running vs working" cycle counter, keyed by buOrderId - how many
  /// consecutive auto-checkup cycles a running app bot has shown zero
  /// position (never filled). See the check site in `_runAutoCheckup`.
  /// Added 2026-09-16, per the user.
  final Map<String, int> _pnlCheckCycleCount = {};

  /// One-time per-bot investment-field dump - see the log call site in
  /// _refreshActiveGrids.
  bool _loggedInvestmentSample = false;

  CdpClient? _cdp;
  // Per the user (2026-09-06): keyed by buOrderId, never by pair - Pionex
  // can (and does) run more than one grid on the same pair at once (e.g. a
  // manual bot plus the app's own), and a pair-keyed map can only ever hold
  // one of them, silently losing track of whichever one didn't win the
  // last write. Confirmed live: a manual DOGE grid and the app's own DOGE
  // grid were both genuinely open simultaneously, and the old pair-keyed
  // map kept losing the app's own bot to the manual one on every refresh.
  final Map<String, GridBot> _activeGridsById = {};
  final Map<String, OpenEntry> _openEntryByPair = {};
  final Map<String, int> _indicatorWaitFailures = {};
  /// How many extra failures at the wait ladder's shortest rung (5s)
  /// before resetting back to the top (30s) for one real attempt - see
  /// the reset logic in `_checkBuySellOnPair`. Added 2026-09-16, per the
  /// user - fixes a real live lockup where every pair got stuck at 5s
  /// forever with no way back to a longer, actually-sufficient budget.
  static const _indicatorWaitFloorRetries = 3;
  bool _healthRecoveryPending = false;
  bool _prevTvHealthy = true;
  bool _prevPionexHealthy = true;
  bool _prevInternetHealthy = true;
  int? _lastHourlyCandleTs;

  /// Per-category candle-gate anchor (2026-09-07) - each of the 3 Auto
  /// engines only actually re-checks its bases at the start of its own new
  /// candle (1m/1H/1D), not continuously every poll tick. Separate from
  /// [_lastHourlyCandleTs] (Checkup's own anchor) since these tracks run
  /// independently and shouldn't share mutable state just because they
  /// happen to read the same market clock.
  final Map<AutoCategory, int?> _lastAutoCandleTs = {
    for (final c in allAutoCategories) c: null,
  };
  final Map<String, double> _nextInvestmentByPair = {};

  /// Worm10 Hybrid Decision technique (2026-10-25, per the user: "and
  /// remove any old technique from code and from prd") - entry-key
  /// ("$key|${category.wireValue}") -> the latest event that passed the
  /// 3-read "1 million sure" check, held until its bar time + 2 candle
  /// periods: its own candle's close plus one more full candle (§5 of the
  /// user's spec). Replaces the old worm_9_26-era fresh-entry-signal-wait
  /// entirely, not alongside it - see [_confirmedWorm10Event]. Persisted to
  /// `worm10-gate.json` (see [_persistWorm10Pending]/
  /// [_reloadWorm10GateIntoMemory]) so a restart mid-wait doesn't silently
  /// forget which candidate is pending.
  final Map<String, Worm10Event> _worm10Pending = {};

  /// Per entry-key, when [_confirmedWorm10Event] last read the chart for a
  /// normal check - see [_worm10RetryCooldown].
  final Map<String, DateTime> _worm10LastCheckedAt = {};
  static const _worm10RetryCooldown = Duration(minutes: 3);

  /// Entry-keys that have had their first check since this engine started -
  /// that check is the immediate one, see [_confirmedWorm10Event].
  final Set<String> _worm10StartupChecked = {};

  /// Bots the retroactive audit has already checked since it was last re-armed
  /// - see [_auditRunningBot]. In-memory on purpose: a restart re-audits all.
  final Set<String> _worm10AuditedBots = {};
  DateTime? _worm10AuditLastClearedAt;
  int? _worm10LastHourlyAuditEpochHour;
  static const _worm10AuditClearDebounce = Duration(minutes: 2);
  static const _worm10HourlyAuditLeadTime = Duration(minutes: 15);

  /// buOrderIds already recorded as `convertedToManual` in history - per
  /// the user (2026-09-14): "summary should show all terminated auto bots
  /// even if it is terminated by user or switched to manual then
  /// terminated." Bug fixed the same day: the reconciliation loop used to
  /// call `createdBots.forgetBot(id)` unconditionally the moment a bot was
  /// first detected as manually interrupted, permanently dropping it from
  /// `createdBots.listAppBots()` - so its EVENTUAL real close (whenever
  /// that happened) was never seen or recorded again, ever. Now the bot
  /// stays tracked; this set just stops the one-time "converted to
  /// manual" notice from being re-recorded on every single pass for as
  /// long as it stays manual - the real termination, once it finally
  /// happens, is recorded exactly once, normally, with its real settled
  /// P/L (see [_interruptedBotSnapshot] for how that's still possible
  /// once neither `_activeGridsById` nor `_openEntryByPair` has anything
  /// left for this id by then).
  final Set<String> _manualInterruptAcknowledged = {};

  /// The bot's own last-known snapshot, captured the moment it was first
  /// detected as manually interrupted - needed because by the time it
  /// ACTUALLY closes for real, `_activeGridsById` (cleared and rebuilt
  /// fresh every pass, only from bots Pionex still lists) will already
  /// have nothing for this id, and `_openEntryByPair` will have already
  /// dropped it too (the interruption itself clears that entry the same
  /// pass it's first detected). Without this, the eventual real
  /// termination would still be detected, but recorded with `base:
  /// 'unknown'`/`category: null` - which `pnlByPairSummary()` silently
  /// excludes, reproducing the exact gap this whole fix exists to close.
  final Map<String, GridBot> _interruptedBotSnapshot = {};
  List<String> _redListSymbols = [];
  final Set<String> _sessionRetiredPairs = {};
  // See the 2026-09-15 fix in _readRedList - true only right after a
  // single empty-list read following a non-empty one; requires a SECOND
  // consecutive empty read before it's trusted as genuine.
  bool _redListWasEmptyLastRead = false;
  final List<RunningBotCheck> _runningBotsReportEntries = [];
  bool _mainLoopRunning = false;

  /// Base tickers Pionex currently offers as a tradeable perpetual futures
  /// grid - refreshed on Power-up, Check Now, and the Controls-screen Check
  /// button (per the user, 2026-09-06), never on every 5s tick. Null until
  /// the first successful refresh, so nothing gets wrongly tagged "unlisted"
  /// before Pionex has ever actually answered.
  Set<String>? _pionexFuturesBases;
  bool? _pauseFileLastSeen;

  /// The current Check Now round (see [CoreStorage.checkNowPairsFile]) and the
  /// pairs already read in it.
  int? _checkNowRound;
  final Set<String> _checkedInRound = {};

  /// The table's pairs for Check Now, or null if the app hasn't sent any.
  ({int round, List<String> symbols})? _readCheckNowTablePairs() {
    final json = storage.readJsonObject(storage.checkNowPairsFile);
    final symbols = ((json?['symbols'] as List?) ?? const [])
        .map((e) => '$e'.trim().toUpperCase())
        .where((e) => e.isNotEmpty)
        .toList();
    if (json == null || symbols.isEmpty) return null;
    return (round: (json['round'] as num?)?.toInt() ?? 0, symbols: symbols);
  }

  /// Check Now's pair list: Pionex's trending USDT-M + tokenized-stock perps
  /// (see technique/trending.dart). Null if Pionex's tickers can't be read,
  /// so the caller falls back to the Red list.
  Future<List<String>?> _trendingUniverse() async {
    final tickers = await pionex.getPerpTickers();
    if (tickers.isEmpty) return null;
    final list = rankTrending(
      tickers,
      minTurnoverUsdt: CoreConstants.trendingMinTurnoverUsdt,
      maxPairs: CoreConstants.trendingMaxPairs,
    );
    if (list.isEmpty) return null;
    logger.log(
      'TRENDING: ${list.length} Pionex pair(s) with >= '
      '\$${(CoreConstants.trendingMinTurnoverUsdt / 1e6).toStringAsFixed(1)}M '
      '24h turnover, biggest 24h move first: ${list.join(', ')}',
    );
    return list;
  }

  Future<void> _refreshPionexFuturesListing() async {
    try {
      final bases = await pionex.getFuturesBaseTickers();
      _pionexFuturesBases = bases;
      logger.log(
        'PIONEX LISTING: refreshed - ${bases.length} tradeable futures base(s) known.',
      );
    } catch (e) {
      logger.log('PIONEX LISTING refresh failed: $e');
    }
  }

  /// True only once a listing has actually loaded and [symbolOrBase]'s base
  /// ticker is confirmed absent from it - before the first successful
  /// refresh this always returns false, so nothing is wrongly tagged
  /// "unlisted" from an empty/unloaded cache.
  bool _isUnlistedOnPionexFutures(String symbolOrBase) {
    final bases = _pionexFuturesBases;
    if (bases == null) return false;
    return !bases.contains(_baseOf(symbolOrBase).toUpperCase());
  }

  /// Set when a fresh checkup (CHECKNOW) is explicitly requested while a
  /// cycle is already mid-sweep - the per-pair loop in _runCycle checks this
  /// and breaks out early instead of finishing the stale cycle, so a fresh
  /// request always wins and starts clean rather than silently queueing
  /// behind (or being dropped by) whatever was already running.
  bool _freshCycleRequested = false;

  /// Set when a Controls-screen pair action (Check/Add/Remove/Start) is
  /// waiting for the single TradingView chart while a sweep is mid-cycle -
  /// same early-cancel as [_freshCycleRequested] (the per-pair loop below
  /// checks both), but on exit this does NOT auto-restart a full sweep the
  /// way a fresh checkup does: the pair action just needs the chart free,
  /// not a whole new cycle. Once the cancelled cycle exits, `_pairActionTick`
  /// (its own independent timer) picks the pending request up on its very
  /// next poll since `_mainLoopRunning` is now false; normal cycling then
  /// resumes on the main loop's own schedule same as always, with nothing
  /// explicitly "resumed" - it was never stopped, only this one cycle's
  /// work was cut short and gets naturally redone on the next tick.
  bool _cycleCancelledForPairAction = false;

  /// Set when an Auto category's own candle boundary genuinely comes due
  /// while a Check Now/Start sweep has the chart (2026-09-11, per the
  /// user: "if checknow is running and any auto interval comes, checknow
  /// pause and auto proceed - once auto finish, checknow continue"). Same
  /// early-cancel/resume mechanism as [_cycleCancelledForPairAction] (the
  /// per-pair loop below checks both) - the cancelled sweep's remaining
  /// pairs go into [_checkupResumePairs] exactly the same way, and
  /// `_runCycleGuarded`'s existing `_wakePendingAutoCategory()` call (which
  /// already exists for the pair-action-preempts-checkup case) picks up
  /// the now-queued category the moment the chart is free. Deliberately
  /// scoped to Check Now/Start only - a busy pair action or a DIFFERENT
  /// already-running Auto category keep their own separate, pre-existing
  /// priority rules untouched.
  bool _cycleCancelledForAutoCheckup = false;

  /// Non-null only right after a checkup was paused mid-sweep for a pair
  /// action - the pairs it hadn't reached yet, consumed (and cleared) the
  /// next time `_runCycle` runs, so that run resumes there instead of
  /// starting over. Null means there's nothing paused to resume.
  List<String>? _checkupResumePairs;

  // --- Auto checkup: 3 independent tracks (2026-09-07), one per
  // [AutoCategory], each fully separate from the full Checkup above (see
  // the user's spec, 2026-09-04) and from each other - a base can be
  // auto-managed by more than one category at once, each with its own
  // bot(s). Scoped only to that category's own auto-managed bases (see
  // AutoManagedStore) - never the whole Red list. Shares the single
  // TradingView chart with Checkup, pair actions, and the OTHER 2
  // categories. Simplified concurrency model vs Checkup/pair-actions'
  // mutual preemption: at most one Auto category ever runs at a time (each
  // checks the others before starting), Checkup/pair actions can still
  // preempt whichever ONE is currently running, but none of the 3
  // categories ever preempt each other or Checkup - a routine tick that
  // finds the chart busy just skips itself and retries on the next poll
  // (the candle gate means nothing is lost, only delayed).
  final Map<AutoCategory, bool> _autoRunning = {
    for (final c in allAutoCategories) c: false,
  };
  final Map<AutoCategory, List<String>?> _autoResumePairs = {
    for (final c in allAutoCategories) c: null,
  };

  bool get _anyAutoRunning => _autoRunning.values.any((r) => r);

  /// Which category is currently running, if any - at most one ever is
  /// (see the concurrency note above), so this is unambiguous.
  AutoCategory? get _runningAutoCategory => allAutoCategories
      .cast<AutoCategory?>()
      .firstWhere((c) => _autoRunning[c] == true, orElse: () => null);

  /// Set when a full Checkup (explicit Check Now/Start) needs the chart
  /// while an auto-checkup is mid-sweep - whichever category is currently
  /// running (see [_runningAutoCategory]) checks this and pauses (saving
  /// its remaining bases) rather than finishing the stale pass, so an
  /// explicit user request always wins.
  bool _autoCheckupCancelledForCheckup = false;

  /// Set when a Controls-screen pair action needs the chart while an
  /// auto-checkup is mid-sweep - same pause-and-resume as
  /// [_autoCheckupCancelledForCheckup], different reason for the log line.
  bool _autoCheckupCancelledForPairAction = false;

  /// Per-category: set when that category is triggered again (its own
  /// toggle switched on, or its own force-check) while it's already
  /// running - per the user (2026-09-07, rule 2): the second trigger runs
  /// once the first finishes, it is never just dropped. Checked in that
  /// category's own finally block.
  final Map<AutoCategory, bool> _autoForceRequested = {
    for (final c in allAutoCategories) c: false,
  };

  Timer? _autoLoopTimer1h;

  /// Ticks a lightweight, independent check for [_checkForSelfExit] - per
  /// the user (2026-09-14): "i want engine stop when there is no auto
  /// trade." Deliberately a SEPARATE timer, not folded into the existing
  /// cycle/auto-checkup machinery, so this can never interact with (or
  /// risk destabilizing) the actual trading loop - it only ever reads
  /// state, never touches the chart, Pionex, or any in-flight operation.
  Timer? _selfExitCheckTimer;

  /// Bug fixed 2026-09-17, live, real-money (per the user: "double check
  /// the recycled money and the sum in auto card" - traced to a full
  /// audit against real Pionex data: 27 of 196 closed trades since the
  /// last reset had a WRONG recorded P/L, 19 with the sign flipped
  /// outright, because [_reconcilePnlSettlement] was only ever invoked
  /// from inside a genuinely fresh (non-resumed) checkup sweep - confirmed
  /// via engine.log that it had NEVER once fired, in 16+ hours across two
  /// restarts, almost certainly because a full Red List sweep this live
  /// almost never completes uninterrupted before a candle boundary or pair
  /// action preempts it, leaving `_checkupResumePairs` non-null (so
  /// `resuming` reads true) far more often than not. Same "separate timer,
  /// never touches the actual trading loop" pattern as
  /// [_selfExitCheckTimer] - this only ever reads Pionex's finished-orders
  /// list and patches `bot-history.jsonl` in place, decoupled entirely from
  /// whether a checkup sweep is fresh, resuming, or mid-flight. Its own
  /// internal 15-minute throttle ([_pnlSettlementInterval]) still applies,
  /// so most ticks are a cheap no-op - this timer just guarantees it
  /// actually gets a chance to fire instead of depending on a rare, mostly
  /// theoretical "sweep completed cleanly" moment.
  Timer? _pnlSettlementTimer;

  /// Auto TP/SL ratchet sweep — runs on the SAME poll cadence as every
  /// other timer in this file ([AppConfig.pollIntervalSec], not a bespoke
  /// interval this app has no other concept of), checking every
  /// currently-running app-initiated bot's floating P&L (in USDT) against
  /// [highestDollarThresholdCrossed]/[dollarLockFor] (2026-10-25, the
  /// dollar ladder - see `tp_sl_ladder.dart`) and ratcheting its stop-loss
  /// tighter (never looser) as milestones are crossed; also applies the
  /// baseline (TP at the grid's own top/bottom edge, SL at -50%) to any
  /// app-initiated bot that doesn't have it yet — covers both a
  /// freshly-created bot and one that was already running before this
  /// feature existed. No grace period for the dollar ladder itself (see
  /// `_checkTpSlRatchet`'s doc) - polling this fast is harmless regardless,
  /// since the ratchet only ever moves up and re-checking a threshold that
  /// hasn't changed is a no-op.
  Timer? _tpSlRatchetTimer;

  /// "Stop Loss Lock" sweep (2026-09-22, per the user's exact spec) — an
  /// independent, fixed 3-minute timer (NOT tied to any [AutoCategory]'s
  /// own candle period, per the user: "engine will check every 3 minutes"
  /// regardless of whether the tagged pair is on 3m/5m/15m/1H/1D), checking
  /// every Stop Loss Lock-tagged auto/manual bot's floating P&L and, once it
  /// clears +100%, watching for a reversal signal on that pair's OWN
  /// timeframe (yellow zone + HH for a long, blue zone + LL for a short) to
  /// lock the stop-loss to P&L-10 points. Below +100% this sweep does
  /// nothing at all - the normal flat -50% baseline SL (still applied by
  /// [_checkTpSlRatchet]) is what's actually protecting the position; see
  /// [_checkStopLossLock]'s own doc for the full gate.
  ///
  /// Lowest priority of every chart-holding track in this file - it never
  /// preempts Checkup/Start or any AutoCategory the way they preempt each
  /// other, and voluntarily yields mid-sweep (see [_runStopLossLockSweep])
  /// the instant any of them genuinely need the chart, since this is a
  /// profit-lock optimization, not a real trading signal.
  Timer? _stopLossLockTimer;

  /// Drives [_runNeverFilledSweep] - fixed 3-minute cadence, independent of
  /// any [AutoCategory]'s own candle-gated cycle (2026-09-27, per the
  /// user's exact request).
  Timer? _neverFilledCheckTimer;

  /// True only while [_runStopLossLockSweep] is actively holding the chart
  /// (switching symbols, reading the oscillator) - folded into every other
  /// track's own "is the chart busy" gate below, exactly like
  /// [_anyAutoRunning], so Checkup/pair-actions/AutoCategory ticks correctly
  /// treat a Stop Loss Lock read in progress as chart-busy too.
  bool _stopLossLockRunning = false;

  /// buOrderIds whose pre-existing -50% baseline SL has already been
  /// explicitly cleared because the pair was tagged for Stop Loss Lock
  /// AFTER that baseline was already live on Pionex (2026-09-22, per the
  /// user - see [_checkTpSlRatchet]'s doc). In-memory only, not persisted:
  /// on an engine restart this is empty again, so a still-tagged bot with a
  /// genuinely-already-cleared SL just gets the same (idempotent, harmless)
  /// clear call re-sent once more rather than being silently skipped.
  final Set<String> _stopLossLockSlCleared = {};

  /// Completed exactly once, the moment either [_checkForSelfExit] ("no
  /// auto trade left") or [_checkGuiHeartbeat] ("GUI off") decides the
  /// engine should shut itself down - whichever fires first wins, the
  /// other's own `isCompleted` guard then makes it a no-op.
  /// `bin/engine.dart`'s `main()` awaits this the same way it awaits
  /// SIGINT/SIGTERM, so a self-initiated exit goes through the EXACT same
  /// graceful shutdown path (stop all timers, close CDP, delete the PID
  /// file, `exit(0)`) as a manual `kill`. The completed value is the
  /// human-readable reason, logged verbatim by `bin/engine.dart`'s own
  /// generic `shutdown(signal)` - carrying it through here instead of
  /// hardcoding one label fixes a real, found-via-testing bug (2026-10-25):
  /// every self-exit used to log "stopping engine (no auto trade)" even
  /// when the actual cause was a stale GUI heartbeat.
  final Completer<String> _selfExitRequested = Completer<String>();

  /// Resolves once the engine has decided to shut itself down, with the
  /// reason - see [_selfExitRequested].
  Future<String> get onSelfExitRequested => _selfExitRequested.future;

  /// What the full Checkup track is doing right now, in plain words -
  /// separate from [_autoCheckupMessage] since the tracks run independently
  /// and the user should never see one track's activity mislabeled as the
  /// other's.
  String _checkupMessage = '';

  /// What each Auto-checkup category is doing right now, in plain words -
  /// see [_checkupMessage].
  final Map<AutoCategory, String> _autoCheckupMessage = {
    for (final c in allAutoCategories) c: '',
  };

  int _consecutiveWatchdogTrips = 0;
  static const _chronicWatchdogThreshold = 3;
  bool _forceStopLogged = false;

  Timer? _loopTimer;
  Timer? _verifyTimer;
  Timer? _heartbeatTimer;
  Timer? _pairActionTimer;
  bool _pairActionRunning = false;

  /// True only while a 'reprice' pair action (2026-09-11, per the user -
  /// editing a pair's investment mid-sweep) is actually running. Deliberately
  /// separate from [_pairActionRunning]/the chart-ownership gates below -
  /// reprice only calls Pionex's REST API (checkFuturesGrid), never touches
  /// the shared TradingView chart, so it never needs to wait for Check
  /// Now/Auto-checkup/another pair action to free it, and never preempts
  /// them either. This flag exists purely to stop two reprice requests
  /// from overlapping each other, nothing more.
  bool _repriceRunning = false;

  /// True only while [_pairActionStart] (the multi-symbol "Start selected"
  /// request) is actually iterating its symbol list - never set for the
  /// single-symbol check/add/remove pair actions, which stay quick and
  /// uninterruptible on purpose (2026-09-11, per the user: an Auto
  /// category's own candle boundary must be able to preempt an in-progress
  /// Start the same way it already preempts Check Now, since Start can run
  /// for minutes across several symbols).
  bool _pairActionIsStart = false;

  /// Set when an Auto category's own candle boundary genuinely comes due
  /// while a multi-symbol Start is actively working through its list -
  /// checked between each symbol in [_pairActionStart]'s own loop, the
  /// same cooperative-cancellation pattern [_cycleCancelledForAutoCheckup]
  /// uses for Check Now.
  bool _pairActionCancelledForAutoCheckup = false;

  /// Pairs Start put in Waiting that still get one fill-now attempt, in
  /// order. Drained one at a time by [_onPairActionTick] when no pair
  /// action request is waiting, so a new Start never waits behind fills.
  final List<String> _fillQueue = [];

  /// Non-null only right after a Start request was paused mid-list for an
  /// Auto category - the request's id, the symbols it hadn't reached yet,
  /// and everything opened/skipped so far, so resuming continues exactly
  /// where it left off instead of losing that progress or re-running
  /// already-handled symbols. All four are set together and cleared
  /// together. Mirrors [_checkupResumePairs].
  String? _pairActionResumeId;
  List<String>? _pairActionResumeSymbols;
  List<String>? _pairActionResumeOpened;
  Map<String, String>? _pairActionResumeSkipped;

  /// True whenever the last _refreshRedListNow() attempt didn't confirm
  /// both indicators loaded (or couldn't even connect) - makes
  /// _onPairActionTick call it again on the very next tick, automatically,
  /// with no Check Now/Power-cycle required. Cleared the moment an attempt
  /// actually succeeds.
  bool _indicatorRetryPending = false;

  static const _redListName = 'Red list';

  void start() {
    storage.ensureRuntimeDirs();
    _reconcileStaleStartInProgress();
    _reloadPendingInvestmentsIntoMemory();
    _reloadWorm10GateIntoMemory();
    logger.log('trading-bot engine started (grid orchestrator)');
    logger.log(
      'poll=${config.pollIntervalSec}s grid_pairs=${config.gridPairs.map((p) => p.symbol).join(', ')}',
    );
    logger.log('pionex configured=${pionex.available}');
    unawaited(_reconcileHistoryGapOnStartup());

    _tickHeartbeat();
    _writeTvSyncHeartbeat();
    _tvSyncTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _writeTvSyncHeartbeat(),
    );
    _heartbeatTimer = Timer.periodic(
      CoreConstants.heartbeatTick,
      (_) => _tickHeartbeat(),
    );
    _loopTimer = Timer.periodic(
      Duration(seconds: config.pollIntervalSec),
      (_) => _onLoopTick(),
    );
    _verifyTimer = Timer.periodic(
      CoreConstants.indicatorVerifyInterval,
      (_) => _onVerifyTick(),
    );
    _pairActionTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _onPairActionTick(),
    );
    _autoLoopTimer1h = Timer.periodic(
      Duration(seconds: config.pollIntervalSec),
      (_) => _onAutoLoopTick(AutoCategory.oneHour),
    );
    _selfExitCheckTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkForSelfExit();
      _checkGuiHeartbeat();
    });
    _pnlSettlementTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(_reconcilePnlSettlement()),
    );
    // Stop Loss Lock - every 5 seconds (per the user, 2026-11-09).
    _tpSlRatchetTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_runSllSweep()),
    );
    _neverFilledCheckTimer = Timer.periodic(
      const Duration(minutes: 3),
      (_) => unawaited(_runNeverFilledSweep()),
    );
  }

  /// Per the user (2026-09-14): "i want engine stop when there is no auto
  /// trade." Trips only when ALL of the following hold, checked fresh
  /// every 30s:
  /// - every category's auto-managed list is genuinely empty
  /// - no app-initiated bot is currently running (this also covers a
  ///   Last-marked bot still finishing naturally - "Last" removes a base
  ///   from its auto-managed list immediately, but the bot itself keeps
  ///   running until it closes on its own, so this must still count as
  ///   "auto trade" until then, exactly like the GUI's own Power-off/
  ///   Last-only-mode decision already does)
  /// - the engine is genuinely idle: no cycle/pair-action/auto-checkup in
  ///   flight, and nothing pending that's about to start one (a fresh
  ///   Check Now, a paused Start resume, a waiting pair action) - never
  ///   trips mid-operation or right as something is about to begin.
  ///
  /// Deliberately a one-way decision once tripped (see
  /// [_selfExitRequested] - a `Completer` can only resolve once): this
  /// isn't a pause that un-trips itself if a base briefly reappears a
  /// moment later, it's "shut down now" - relaunching (Power on) is the
  /// GUI's own existing, explicit action per [_selfExitRequested]'s doc.
  ///
  /// Bug fixed same day, confirmed live: the original version fired on a
  /// bare "nothing queued yet" state, which is ALWAYS true in the first
  /// 30s after a fresh launch (the user hasn't had a chance to Start
  /// anything yet) - 4 consecutive Power-on attempts each self-exited
  /// within ~20-30s, making Power-on effectively unusable. [_everHadAutoTrade]
  /// makes this "no auto trade LEFT", matching the user's own wording -
  /// only arms once this process has actually observed some auto-managed
  /// base or app-initiated bot at least once since it started.
  bool _everHadAutoTrade = false;

  void _checkForSelfExit() {
    if (_selfExitRequested.isCompleted) return;
    if (_mainLoopRunning ||
        _pairActionRunning ||
        _anyAutoRunning ||
        _stopLossLockRunning) {
      return;
    }
    if (storage.fileExists(storage.checknowFile)) return;
    if (storage.fileExists(storage.pairActionFile)) return;
    if (_pairActionResumeSymbols != null || _checkupResumePairs != null) {
      return;
    }
    final anyAutoManaged = autoManagedByCategory.values.any(
      (store) => store.loadAutoManagedBases().isNotEmpty,
    );
    final anyAppBotRunning = _activeGridsById.values.any(
      (b) => b.appInitiated,
    );
    if (anyAutoManaged || anyAppBotRunning) {
      _everHadAutoTrade = true;
      return;
    }
    if (!_everHadAutoTrade) return;
    logger.log(
      'NO AUTO TRADE: every category is empty and no app-initiated bot is '
      'running - shutting the engine process down, per the user\'s '
      'explicit request. Turn Power back on in the app to relaunch it.',
      level: 'CRITICAL',
    );
    _selfExitRequested.complete('no auto trade');
  }

  /// "GUI off == engine is off" (2026-10-20, per the user). Replaces the old
  /// `LAST_ONLY_MODE` lingering behavior entirely: the engine no longer
  /// has any reason to outlive the GUI at all, so there's nothing left to
  /// special-case for a still-running Last-marked bot - that position
  /// simply sits open and unmonitored on Pionex until the GUI (and
  /// therefore Power) comes back.
  ///
  /// `guiHeartbeatFile` is touched by `main.dart` every few seconds for as
  /// long as the GUI process is running (see `TradingPionexApp`). A
  /// missing file (GUI never opened at all this engine's lifetime, or a
  /// genuinely headless manual launch) is treated identically to a stale
  /// one - deliberately: per the user's own rule, the engine has no
  /// standalone/headless mode left. Unaffected by `_everHadAutoTrade` or
  /// any busy-state guard (unlike [_checkForSelfExit]) - the GUI being gone
  /// is reason enough to stop regardless of what's mid-cycle; whatever was
  /// running simply gets cut off cleanly via the same graceful shutdown
  /// path everything else here already uses.
  static const _guiHeartbeatStaleThreshold = Duration(seconds: 60);

  void _checkGuiHeartbeat() {
    if (_selfExitRequested.isCompleted) return;
    final raw = storage.readString(storage.guiHeartbeatFile);
    final last = raw == null ? null : DateTime.tryParse(raw.trim());
    if (last != null &&
        DateTime.now().toUtc().difference(last.toUtc()) <=
            _guiHeartbeatStaleThreshold) {
      return;
    }
    logger.log(
      'GUI HEARTBEAT STALE: the GUI has not been seen in over '
      '${_guiHeartbeatStaleThreshold.inSeconds}s (or never this run) - '
      'shutting the engine process down, per the user\'s "gui off == '
      'engine is off" rule. Open the GUI and turn Power on to relaunch it.',
      level: 'CRITICAL',
    );
    _selfExitRequested.complete('gui heartbeat stale');
  }

  /// A multi-symbol Start that was paused mid-list (waiting for an Auto
  /// category's turn) tracks its resume state ONLY in memory
  /// (`_pairActionResumeSymbols` etc.) - a restart while paused wipes that
  /// state silently, but `start-in-progress.json` (written purely for GUI
  /// display, see `_persistStartInProgress`) is never cleared except by
  /// the resume path completing normally, so it kept showing the same
  /// `remaining` symbols forever with zero further activity (2026-09-12,
  /// confirmed live: TRXUSDT, XAUTUSDT, XLMUSDT sat in `remaining` for 3+
  /// hours across at least one restart, with no log trace since - per the
  /// user, "they are since a while in waiting list too"). On every fresh
  /// startup, treat any leftover `remaining` symbols the same way
  /// `_pairActionStart`'s own failure branches already do for a symbol
  /// that couldn't be opened this attempt - join the auto-managed list
  /// for its category so the regular auto-checkup/waiting engine picks it
  /// up going forward - then clear the stale file.
  void _reconcileStaleStartInProgress() {
    final raw = storage.readJsonObject(storage.startInProgressFile);
    if (raw == null) return;
    final remaining = ((raw['remaining'] as List?) ?? const [])
        .cast<String>();
    if (remaining.isEmpty) return;
    for (final symbol in remaining) {
      final base = _baseOf(symbol);
      final category = pairCategories.categoryOf(symbol);
      autoManagedByCategory[category]!.addBase(base);
      logger.log(
        'STARTUP: recovered stale Start entry $symbol - left in '
        'start-in-progress.json with no resume state (a restart during '
        'its pause wiped it) - joined the ${category.label} auto-managed '
        'list so it is retried normally.',
      );
    }
    storage.deleteFileIfExists(storage.startInProgressFile);
  }

  /// `_nextInvestmentByPair` (the recycled "old + P/L" amount a just-
  /// closed bot should reopen with) is otherwise in-memory only -
  /// `pending-investments.json` is written on every set/remove purely so
  /// the GUI can display it (see `_persistPendingInvestment`), with no
  /// load-on-startup path. A restart landing between a close and its
  /// eventual reopen silently wiped the real recycled amount, falling
  /// back to the pair's plain configured default instead - the exact
  /// same "write-only, no reload" shape as the `start-in-progress.json`
  /// bug just above, just on a different file. Confirmed live, this
  /// session: DOTUSDT closed with P/L=$0.00 right before a restart, then
  /// reopened using the plain default with no "using reinvested amount"
  /// log line at all - invisible here only because $0.00 P/L happens to
  /// equal the default; a genuine profit or loss would have been
  /// silently dropped on the very next reopen (2026-09-12, per the
  /// user's own request to double-check that recycling actually works).
  /// Fixed by reloading every pending entry back into memory on startup,
  /// converting the file's `"BASE|CATEGORY"` key (`_persistPending
  /// Investment`'s format) to `_nextInvestmentByPair`'s own
  /// `"GRID_KEY|CATEGORY"` format.
  void _reloadPendingInvestmentsIntoMemory() {
    final pending = storage.readJsonObject(storage.pendingInvestmentsFile);
    if (pending == null || pending.isEmpty) return;
    var restored = 0;
    for (final entry in pending.entries) {
      final parts = entry.key.split('|');
      if (parts.length != 2) continue;
      final category = autoCategoryFromWire(parts[1]);
      final amount = (entry.value as num?)?.toDouble();
      if (category == null || amount == null) continue;
      final entryKey = '${_gridKey(parts[0])}|${category.wireValue}';
      _nextInvestmentByPair[entryKey] = amount;
      restored++;
    }
    if (restored > 0) {
      logger.log(
        'STARTUP: restored $restored pending recycled investment(s) from '
        'pending-investments.json into memory - a base still waiting to '
        'reopen since before this restart will use its real recycled '
        'amount, not silently fall back to its plain default.',
      );
    }
  }

  /// `_worm10Pending` is otherwise in-memory only - same "write-only, no
  /// reload" shape as [_reloadPendingInvestmentsIntoMemory] fixed above (and
  /// the worm_9_26-era fresh-entry-signal wait this replaces): without this, a
  /// restart mid-wait would silently forget which candidate is pending. Fixed
  /// the same way: persisted on every state change (see
  /// [_persistWorm10Pending]), reloaded back into memory here on startup.
  void _reloadWorm10GateIntoMemory() {
    final data = storage.readJsonObject(storage.worm10GateFile);
    if (data == null || data.isEmpty) return;
    var restored = 0;
    Worm10Event? eventOf(Map? json) {
      if (json == null) return null;
      Worm10EventKind? type;
      for (final t in Worm10EventKind.values) {
        if (t.name == json['type']) {
          type = t;
          break;
        }
      }
      final time = (json['time'] as num?)?.toInt();
      if (type == null || time == null) return null;
      return Worm10Event(kind: type, time: time);
    }

    for (final entry in data.entries) {
      final entryKey = entry.key;
      final json = entry.value as Map?;
      if (json == null) continue;
      final pending = eventOf(json['pending'] as Map?);
      if (pending != null) {
        _worm10Pending[entryKey] = pending;
        restored++;
      }
    }
    if (restored > 0) {
      logger.log(
        'STARTUP: restored $restored Worm10 gate entr${restored == 1 ? 'y' : 'ies'} '
        'from worm10-gate.json into memory - a candidate still mid-wait before '
        'this restart keeps its state, not silently resetting.',
      );
    }
  }

  /// Exports one `_worm10Pending` entry to disk - see
  /// [_reloadWorm10GateIntoMemory]'s doc for why. Called on every state change
  /// so the file never drifts from memory. `null` removes the entry.
  void _persistWorm10Pending(String entryKey, Worm10Event? pending) {
    final data = storage.readJsonObject(storage.worm10GateFile) ?? {};
    if (pending == null) {
      data.remove(entryKey);
    } else {
      data[entryKey] = {
        'pending': {'type': pending.kind.name, 'time': pending.time},
      };
    }
    storage.writeJson(storage.worm10GateFile, data);
  }

  void stop() {
    // A stop mid-scan must not leave "busy" behind for the app to show.
    try {
      _writeStatus(
        message: '',
        busy: false,
        checkupPairIndex: 0,
        checkupPairTotal: 0,
        checkupCurrentBase: '',
      );
    } catch (_) {}
    _loopTimer?.cancel();
    _autoLoopTimer1h?.cancel();
    _verifyTimer?.cancel();
    _heartbeatTimer?.cancel();
    _tvSyncTimer?.cancel();
    tvSync.releaseLock();
    _writeTvSyncHeartbeat(power: false);
    _pairActionTimer?.cancel();
    _selfExitCheckTimer?.cancel();
    _pnlSettlementTimer?.cancel();
    _tpSlRatchetTimer?.cancel();
    _stopLossLockTimer?.cancel();
    _neverFilledCheckTimer?.cancel();
    _cdp?.close();
  }

  // Unlike logger.log() (which already self-protects, see AppLogger),
  // _tickHeartbeat/_writeStatus write raw to disk with nothing above them on
  // the call stack to catch a failure - a Timer.periodic callback's
  // exception doesn't crash the process, but it also isn't logged anywhere,
  // so a disk-full/permissions failure would silently freeze status.json
  // and the heartbeat file forever with zero diagnostic trace. Both guard
  // themselves the same way logger.log() does.
  bool _statusWriteFailureLogged = false;
  bool _heartbeatWriteFailureLogged = false;

  void _tickHeartbeat() {
    try {
      storage.writeString(
        storage.heartbeatFile,
        DateTime.now().toUtc().toIso8601String(),
      );
      _heartbeatWriteFailureLogged = false;
    } catch (e) {
      // Log once per failure streak, not every 60s, so a genuinely stuck
      // disk doesn't spam the log it likely also can't write to.
      if (!_heartbeatWriteFailureLogged) {
        logger.log(
          'CRITICAL: failed to write heartbeat file: $e',
          level: 'CRITICAL',
        );
        _heartbeatWriteFailureLogged = true;
      }
    }
  }

  bool _checkupBusy = false;
  bool _checkupUrgent = false;
  final Map<AutoCategory, bool> _autoCheckupBusy = {
    for (final c in allAutoCategories) c: false,
  };
  int _checkupPairIndex = 0;
  int _checkupPairTotal = 0;
  String _checkupCurrentBase = '';
  String _waitingEngineCurrentBase = '';
  String _waitingEngineIdleReason = '';

  /// Which of each category's 3 rotating cycle markers is current right
  /// now (2026-09-12, per the user) - see [AutoCategoryStatus.cycleMarkerIndex]'s
  /// doc for the full feature. In-memory only, resets to 0 on restart.
  final Map<AutoCategory, int> _cycleMarkerIndex = {
    for (final c in allAutoCategories) c: 0,
  };

  /// When the waiting engine last attempted each base (keyed
  /// "CATEGORY_WIRE|BASE"). REPLACED 2026-09-12, same day, per the user:
  /// the original per-CYCLE version of this ("one attempt per 3m cycle")
  /// fixed PONSUSDT hammering the API every ~35s, but over-corrected -
  /// once a base's one attempt for the cycle failed, both this AND the
  /// regular 3m pass sat fully idle for whatever was left of the 3-minute
  /// window (confirmed live: an 80-SECOND stretch of the chart doing
  /// nothing at all). User: "fix it .. do anything to fix it .. i dont
  /// want any waiting pairs." Now a short, fixed per-base COOLDOWN
  /// ([_waitingEngineRetryCooldown]) instead of a per-cycle gate - a
  /// failing base is retried again the moment its own cooldown elapses,
  /// not "whenever the next 3m boundary happens to occur." Still bounded
  /// (never back-to-back with zero delay, which is what actually hammered
  /// Pionex before), just no longer wasteful.
  final Map<String, DateTime> _waitingEngineLastAttemptAt = {};

  /// How long a base must sit before the waiting engine retries it again
  /// - long enough that a genuinely failing pair can never be hammered
  /// back-to-back (the original PONSUSDT problem), short enough that idle
  /// chart time actually gets used instead of sitting empty for the rest
  /// of a 3-minute cycle (the problem this same fix replaced).
  static const _waitingEngineRetryCooldown = Duration(seconds: 20);

  /// How long to sleep before re-checking when every waiting base is
  /// currently on cooldown - keeps the loop responsive (picks up a newly-
  /// eligible base quickly, still checks the chart-needed-elsewhere flags
  /// every cycle) without busy-spinning.
  static const _waitingEngineIdleSleep = Duration(seconds: 3);

  /// Consecutive genuine open-attempt failures per base (keyed same as
  /// [_waitingEngineLastAttemptAt]) - 2026-09-12, per the user: "if the
  /// waiting pair failed to start after 5 waiting cycles, app will
  /// terminate this auto trade before relaunching again." Reset to
  /// nothing the moment an attempt actually succeeds (a real grid now
  /// exists); incremented only on a GENUINE failure - the create loop was
  /// actually reached and exhausted every shrink-retry without a grid
  /// resulting (`_lastCreateSkipReason == null` after the call) - never
  /// on a benign skip (already running, funds-restricted, not selected,
  /// no valid signal this round), which would wrongly punish a base that
  /// simply hasn't had a real chance to open yet. Reaching
  /// [_waitingEngineMaxFailuresBeforeTerminate] retires the base (see
  /// [RetiredStore]) - the exact same mechanism the "Last" feature uses -
  /// so the waiting engine stops relaunching it. Not a dead end: the
  /// Next Trade table's Start button never checks retired status (see
  /// `createBlocked` in `_manageGridPair`), and a genuinely successful
  /// manual Start clears the retirement automatically (same as any other
  /// brand-new grid), so the user can always choose it there again.
  final Map<String, int> _waitingEngineFailCount = {};

  /// See [_waitingEngineFailCount]'s doc - confirmed live against
  /// XRPUSDT (100+ consecutive real Pionex rejections with the identical
  /// range/investment, never once transient) before this cap existed.
  static const _waitingEngineMaxFailuresBeforeTerminate = 5;

  String _waitingEngineTriedKey(AutoCategory cat, String base) =>
      '${cat.wireValue}|${base.toUpperCase()}';

  /// Same idea as [_cycleMarkerIndex], but for the Checkup track (Check
  /// Now/Start's own sweep over the whole red list) - per the user
  /// (2026-09-12): "same technique is applied on check now... a symbol
  /// appears inside check now button and this symbol is next to pair name
  /// after check in next trade table... helps user to know if all pairs
  /// updated according to last check now or not." Advances only on a
  /// genuinely fresh sweep (never a resume), same reasoning as the
  /// auto-category version.
  int _checkupCycleMarkerIndex = 0;

  /// Records that [base]/[category] was just actually checked under
  /// [category]'s CURRENT cycle marker (2026-09-12, per the user) - a
  /// small file the GUI compares against the toggle's own current marker
  /// to show "checked in this sweep" per row. Read-modify-write on a tiny
  /// file (one entry per auto-managed base at most), same pattern as
  /// other per-base persisted stores in this file (e.g.
  /// `_persistPendingInvestment`) - negligible next to the real network
  /// calls already happening for the same check.
  void _recordCycleMarker(String base, AutoCategory category) {
    final key = '${base.toUpperCase()}|${category.wireValue}';
    final current =
        storage.readJsonObject(storage.cycleMarkersFile) ??
        <String, dynamic>{};
    current[key] = _cycleMarkerIndex[category] ?? 0;
    // When it was checked - the dashboard shows a check mark for pairs
    // checked in the current UTC hour (per the user, 2026-11-11).
    current['$key|at'] = DateTime.now().millisecondsSinceEpoch;
    storage.writeJson(storage.cycleMarkersFile, current);
  }

  /// Same idea as [_recordCycleMarker], for the Checkup track (2026-09-12,
  /// per the user) - shares the same small file, keyed with the literal
  /// "CHECKUP" pseudo-category (never a real [AutoCategory.wireValue], so
  /// it can't collide with a real per-category entry).
  void _recordCheckupCycleMarker(String base) {
    final key = '${base.toUpperCase()}|CHECKUP';
    final current =
        storage.readJsonObject(storage.cycleMarkersFile) ??
        <String, dynamic>{};
    current[key] = _checkupCycleMarkerIndex;
    storage.writeJson(storage.cycleMarkersFile, current);
  }

  /// Writes the persisted status snapshot. `message`/`busy`/`urgent` update
  /// the Checkup track's own fields; `autoMessage`/`autoBusy` update
  /// [category]'s own Auto-checkup fields - each is nullable and, left
  /// null, simply keeps whatever that field already was, so any track can
  /// call this without blanking out another track's current status. This
  /// is what makes every status line genuinely independent instead of one
  /// overwriting another.
  void _writeStatus({
    String? message,
    bool? busy,
    bool? urgent,
    AutoCategory? category,
    String? autoMessage,
    bool? autoBusy,
    int? checkupPairIndex,
    int? checkupPairTotal,
    String? checkupCurrentBase,
    String? waitingEngineCurrentBase,
    String? waitingEngineIdleReason,
  }) {
    if (message != null) _checkupMessage = message;
    if (busy != null) _checkupBusy = busy;
    if (urgent != null) _checkupUrgent = urgent;
    if (category != null) {
      if (autoMessage != null) _autoCheckupMessage[category] = autoMessage;
      if (autoBusy != null) _autoCheckupBusy[category] = autoBusy;
    }
    if (checkupPairIndex != null) _checkupPairIndex = checkupPairIndex;
    if (checkupPairTotal != null) _checkupPairTotal = checkupPairTotal;
    if (checkupCurrentBase != null) _checkupCurrentBase = checkupCurrentBase;
    if (waitingEngineCurrentBase != null) {
      _waitingEngineCurrentBase = waitingEngineCurrentBase;
    }
    if (waitingEngineIdleReason != null) {
      _waitingEngineIdleReason = waitingEngineIdleReason;
    }
    final appInitiatedCount = _activeGridsById.values
        .where((g) => g.appInitiated)
        .length;
    final oneHour = AutoCategory.oneHour;
    final status = EngineStatus(
      state: _forceStopActive()
          ? EngineRunState.paused
          : (risk.killSwitchTripped
                ? EngineRunState.killSwitched
                : EngineRunState.running),
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      cdpHealthy: _prevTvHealthy,
      pionexHealthy: _prevPionexHealthy,
      internetHealthy: _prevInternetHealthy,
      lastCycleMessage: _checkupMessage,
      busy: _checkupBusy,
      urgent: _checkupUrgent,
      autoCheckupMessage: _autoCheckupMessage[oneHour] ?? '',
      autoCheckupBusy: _autoCheckupBusy[oneHour] ?? false,
      activeGridCount: _activeGridsById.length,
      appInitiatedGridCount: appInitiatedCount,
      lastCandleTimeMs: _lastHourlyCandleTs,
      lastAutoCandleTimeMs: _lastAutoCandleTs[oneHour],
      redListSymbols: _redListSymbols,
      checkupPairIndex: _checkupPairIndex,
      checkupPairTotal: _checkupPairTotal,
      checkupCurrentBase: _checkupCurrentBase,
      waitingEngineCurrentBase: _waitingEngineCurrentBase,
      waitingEngineIdleReason: _waitingEngineIdleReason,
      waitingEngineTriedBases: _waitingEngineLastAttemptAt.keys.toList(),
      checkupCycleMarkerIndex: _checkupCycleMarkerIndex,
      autoCategories: {
        for (final c in allAutoCategories)
          c: AutoCategoryStatus(
            message: _autoCheckupMessage[c] ?? '',
            busy: _autoCheckupBusy[c] ?? false,
            // Per the user (2026-09-09): the "next checkup" countdown for a
            // category must only show while that category actually has a
            // real, currently-open app-initiated bot right now - a base
            // that stays on the watchlist after closing (waiting for a
            // fresh signal to recycle-reopen) does NOT count, and neither
            // does a base someone closed manually on Pionex. Gated on the
            // live count of open grids tagged to this category (not the
            // watchlist size, which was the previous, insufficient fix) -
            // recomputed every status write, so it clears the instant the
            // last bot under a category closes and reappears the instant a
            // new one opens.
            lastCandleTimeMs: _activeAppGridCountFor(c) == 0
                ? null
                : _lastAutoCandleTs[c],
            enabled: !storage.fileExists(storage.autoCategoryPausedFileFor(c)),
            cycleMarkerIndex: _cycleMarkerIndex[c] ?? 0,
          ),
      },
    );
    try {
      storage.writeJson(storage.statusFile, status.toJson());
      _statusWriteFailureLogged = false;
    } catch (e) {
      if (!_statusWriteFailureLogged) {
        logger.log(
          'CRITICAL: failed to write status.json: $e',
          level: 'CRITICAL',
        );
        _statusWriteFailureLogged = true;
      }
    }
  }

  bool _forceStopActive() => storage.fileExists(storage.pauseFile);

  /// Pionex rejects `quoteInvestment` with more than 2 decimal places
  /// ("quote_investment not match spending precision: max 2 decimal
  /// places") - every recycled investment amount (`old + P/L`) must be
  /// rounded through this before being stored/sent, or a reopen attempt
  /// fails outright, permanently, on every single retry (confirmed live -
  /// see the RECYCLE section's fix comment).
  double _roundTo2dp(double v) => (v * 100).round() / 100;

  /// Exports `_nextInvestmentByPair` to disk (2026-09-10, per the user's
  /// "waiting SYMBOL/CATEGORY/AMOUNT" Auto bots card request) - the GUI has
  /// no other way to know a pending recycled amount exists before it
  /// actually succeeds, since this map is otherwise in-memory only. Called
  /// right after every set/remove on the map so the file never drifts from
  /// it. `amount == null` removes the entry (a reopen just succeeded or was
  /// never pending).
  void _persistPendingInvestment(
    String base,
    AutoCategory category,
    double? amount,
  ) {
    final pending =
        storage.readJsonObject(storage.pendingInvestmentsFile) ?? {};
    final key = '${base.toUpperCase()}|${category.wireValue}';
    if (amount == null) {
      pending.remove(key);
    } else {
      pending[key] = amount;
    }
    storage.writeJson(storage.pendingInvestmentsFile, pending);
  }

  /// Exports a multi-symbol Start's live progress (2026-09-11, per the
  /// user) - see [CoreStorage.startInProgressFile]. `remaining` drives the
  /// Auto bots card's "Waiting" row; `opened`/`skipped` (accumulated so
  /// far, carried across any pause/resume) let the GUI's own poll loop
  /// surface each symbol's outcome the moment it's decided, instead of
  /// waiting for the whole batch to finish. All-empty clears the file
  /// entirely (Start genuinely finished, not just paused).
  void _persistStartInProgress(
    String id,
    List<String> remaining,
    List<String> opened,
    Map<String, String> skipped,
  ) {
    if (remaining.isEmpty && opened.isEmpty && skipped.isEmpty) {
      storage.deleteFileIfExists(storage.startInProgressFile);
      return;
    }
    storage.writeJson(storage.startInProgressFile, {
      'id': id,
      'remaining': remaining,
      'opened': opened,
      'skipped': skipped,
    });
  }

  /// Appends to the History screen's log (see [CoreStorage.botHistoryFile]).
  ///
  /// Bug fixed 2026-09-14, per the user ("all red = negative" investigation
  /// surfaced 28 duplicated buOrderIds going back to 2026-09-12): this
  /// engine and the GUI's own `EngineControlRepository` (a separate
  /// process, its own copy of `_recordHistory`) can each independently
  /// detect and record the SAME bot's closure - the engine's routine
  /// reconciliation notices it's gone from Pionex at roughly the same
  /// moment an explicit GUI Stop finishes its own (slower, paginated)
  /// P/L lookup and records its own entry too. Confirmed live: GALA/DOGE/
  /// POL/XAUT/PAXG all double-recorded within one session, sometimes with
  /// genuinely different P/L values since one read raced ahead of Pionex
  /// still settling. A real close should only ever be logged once - skip
  /// if this exact buOrderId+kind is already recorded anywhere in
  /// history. The existing PNL settlement sweep already handles
  /// correcting the VALUE later if a write raced a still-settling read -
  /// this only needed to fix HOW MANY TIMES an event gets logged, not
  /// whether the number is accurate yet.
  void _recordHistory(BotHistoryEntry entry) {
    final already = storage
        .readJsonl(storage.botHistoryFile)
        .any(
          (e) =>
              e['buOrderId'] == entry.buOrderId &&
              e['kind'] == entry.kind.wireValue,
        );
    if (already) return;
    storage.appendJsonl(storage.botHistoryFile, entry.toJson());
  }

  /// One-time reconciliation, fired from [start()] on every engine launch
  /// (2026-09-21, per the user's "why this problem always happening" after
  /// the second real live incident this session where bots closed on
  /// Pionex while the engine simply wasn't running to see it: first a
  /// brief redeploy gap, then a multi-hour disk-full/CDP-outage window -
  /// both times the real closes only surfaced when the user asked for a
  /// manual sum-vs-Pionex audit, sometimes hours or days later). The
  /// engine's normal reconciliation only ever notices a bot closed by
  /// watching it disappear from Pionex's currently-open list WHILE the
  /// engine is running - it has no other way to learn about a close that
  /// happened entirely inside a downtime window. This closes that gap
  /// directly: on every startup, ask Pionex's own closed-grids history for
  /// everything closed since the last time this check succeeded (a
  /// persisted checkpoint - falls back to the P&L reset time on the very
  /// first run, or 2 days ago if neither exists yet), and backfill
  /// anything [_recordHistory] doesn't already have. Safe to call for
  /// every closed grid found, not just ones already known to be missing -
  /// `_recordHistory`'s own buOrderId+kind dedup guard means a re-check
  /// covering an already-reconciled window is a cheap no-op. Fire-and-
  /// forget from `start()`: a slow or failed Pionex call here must never
  /// block or crash the rest of startup, and simply retries fresh (from
  /// the last successful checkpoint) on the next restart if it fails.
  Future<void> _reconcileHistoryGapOnStartup() async {
    if (!pionex.available) return;
    try {
      final checkpointMs =
          (storage.readJsonObject(storage.historyReconcileCheckpointFile))?['checked_through_ms']
              as int?;
      final resetMs =
          (storage.readJsonObject(storage.pnlResetFile))?['reset_at_ms']
              as int?;
      final sinceMs =
          checkpointMs ??
          resetMs ??
          DateTime.now()
              .subtract(const Duration(days: 2))
              .millisecondsSinceEpoch;
      final closed = await pionex.getClosedGrids(sinceTs: sinceMs);
      final existing = storage
          .readJsonl(storage.botHistoryFile)
          .where((e) => e['kind'] == 'terminated')
          .map((e) => e['buOrderId'])
          .whereType<String>()
          .toSet();
      var backfilled = 0;
      for (final raw in closed) {
        final data = (raw['buOrderData'] as Map?)?.cast<String, dynamic>();
        final buOrderId = (raw['buOrderId'] ?? data?['buOrderId'])
            ?.toString();
        if (buOrderId == null ||
            buOrderId.isEmpty ||
            existing.contains(buOrderId)) {
          continue;
        }
        final bot = GridBot.fromPionexOrder(raw, appInitiated: true);
        final reasonBy = (data?['reasonBy'] ?? raw['reasonBy'])?.toString();
        _recordHistory(
          BotHistoryEntry.fromBot(
            bot,
            kind: BotHistoryKind.terminated,
            detail:
                '${_reconciledCloseReason(buOrderId, reasonBy)} (found by startup reconciliation - closed on Pionex while the engine was not running.)',
          ).withEntrySignal(stopReason: _stopReasonFor(buOrderId, reasonBy)),
        );
        existing.add(buOrderId);
        backfilled++;
        // Bug fixed 2026-09-25, live (per the user: "there are some
        // records in pionex history not in app.. why?" - 5 real SLL SL
        // closes, found here for the first time, all recorded correctly
        // into History but NEVER recycled - confirmed live: none of their
        // bases got a `pending-investments.json` entry). This startup
        // backfill path is the ONE place a real close's P&L was recorded
        // without ever carrying it forward into the next bot's investment
        // - every OTHER reconciliation site in this file (both branches of
        // `_refreshActiveGrids`) already does this; this one just never
        // had it added. Same "old total investment + P&L" computation as
        // those sites, using whatever real numbers Pionex's own closed-
        // order record carries (`initialInvestment`, or actual+margin if
        // that's missing) - a genuine, if rarer, gap than the live
        // reconciliation paths, since it only ever fires for a close that
        // happened entirely during downtime between one engine run and the
        // next.
        if (bot.base.isNotEmpty && bot.totalRealizedProfit != null) {
          final category = botCategories.categoryOf(buOrderId) ?? AutoCategory.oneHour;
          final baseInvestment =
              bot.initialInvestment ??
              ((bot.actualInvestment ?? 0) + (bot.extraMargin ?? 0));
          if (baseInvestment > 0) {
            final recycled = _roundTo2dp(
              (baseInvestment + bot.totalRealizedProfit!).clamp(
                0,
                double.infinity,
              ),
            );
            _nextInvestmentByPair['${_gridKey(bot.base)}|${category.wireValue}'] =
                recycled;
            _persistPendingInvestment(bot.base, category, recycled);
            logger.log(
              'RECYCLE $buOrderId: closed during downtime, found by startup '
              'reconciliation, with P/L=${bot.totalRealizedProfit} USDT '
              '(base investment=$baseInvestment) - next investment=$recycled',
            );
          }
        }
      }
      storage.writeJson(storage.historyReconcileCheckpointFile, {
        'checked_through_ms': DateTime.now().millisecondsSinceEpoch,
      });
      logger.log(
        backfilled > 0
            ? 'STARTUP RECONCILE: found $backfilled real Pionex close(s) since the engine last ran that were never recorded - backfilled into bot-history.jsonl.'
            : 'STARTUP RECONCILE: checked ${closed.length} real Pionex close(s) since the engine last ran - all already recorded, nothing to backfill.',
      );
    } catch (e) {
      logger.log(
        'STARTUP RECONCILE failed (will retry from the same checkpoint next restart): $e',
        level: 'ERROR',
      );
    }
  }

  /// Pionex's own real close reason (`reasonBy` on the closed bot order),
  /// mapped to a specific, human-readable termination reason for the
  /// History card itself (2026-09-20, per the user - the previous generic
  /// "No longer running on Pionex." covered ~80% of all history entries
  /// and told the user nothing: "stop loss +5% termination, signal
  /// switched, stop loss -50% triggered and all other possible reasons").
  /// Distinguishes a raw baseline SL hit from one that fired after the
  /// ratchet had already escalated, using the exact same
  /// `tpSlRatchet.highestThreshold` state the SL re-ignite feature reads -
  /// a ratcheted hit gave back SOME locked-in profit, a raw one didn't.
  /// Falls back to showing the raw `reasonBy` value verbatim for any
  /// reason not explicitly covered here, per the user's own "and all
  /// other possible reasons" - never silently generic again.
  String _reconciledCloseReason(String buOrderId, String? reasonBy) {
    // Checked FIRST (2026-09-22, per the user - History filters need to
    // tell an SLL-caused close apart from the normal ratchet/baseline):
    // a Stop Loss Lock-tagged pair has its ratchet ladder disabled
    // entirely (see the override in `_checkTpSlRatchet`), so
    // `tpSlRatchet.highestThreshold` legitimately stays 0 for it even
    // after Stop Loss Lock has genuinely tightened its SL well above the
    // baseline - without this check first, a Stop-Loss-Lock-caused close
    // would misreport as the plain -50% baseline, which is wrong (and
    // unfilterable as "SLL" in History). Read before
    // `stopLossLockState.forget(buOrderId)` ever runs for this bot - every
    // call site records history before cleaning up that state.
    final lockedSl = stopLossLockState.lockedUsd(buOrderId);
    final ratcheted = tpSlRatchet.highestThreshold(buOrderId) > 0;
    return switch (reasonBy) {
      'loss_stop' => lockedSl != null
          ? 'Stop loss triggered by Stop Loss Lock (locked at +\$${lockedSl.toStringAsFixed(0)}).'
          : ratcheted
          ? 'Stop loss triggered after the ratchet had already locked in a higher level.'
          : 'Stop loss -50% (baseline) triggered.',
      'profit_stop' => 'Take-profit triggered.',
      'user_cancel' =>
        'Canceled directly on Pionex/TradingView (not via the app).',
      'liquidation' => 'Position liquidated.',
      null => 'No longer running on Pionex (reason unavailable).',
      _ => 'Closed on Pionex (reason: $reasonBy).',
    };
  }

  /// The SAME real close reason as [_reconciledCloseReason], but as a
  /// short, stable category string for [BotHistoryEntry.stopReason]
  /// instead of free text (2026-09-26, per the user: "i want to add stop
  /// signal - it can be TP/SL/Terminated by user/close signal/etc" - a
  /// structured field alongside the existing entry-signal one, not just
  /// text buried in `detail`). One of: 'take_profit', 'stop_loss_baseline',
  /// 'stop_loss_ratchet', 'stop_loss_lock', 'liquidation', or null if
  /// `reasonBy` is unavailable/unrecognized (detail's own text still
  /// covers that case, verbatim). Deliberately shares the exact same
  /// `lockedSl`/`ratcheted` inputs as [_reconciledCloseReason] so the two
  /// can never disagree about what actually happened to a given bot -
  /// called right alongside it at every real-close call site.
  String? _stopReasonFor(String buOrderId, String? reasonBy) {
    final lockedSl = stopLossLockState.lockedUsd(buOrderId);
    final ratcheted = tpSlRatchet.highestThreshold(buOrderId) > 0;
    return switch (reasonBy) {
      'loss_stop' => lockedSl != null
          ? 'stop_loss_lock'
          : ratcheted
          ? 'stop_loss_ratchet'
          : 'stop_loss_baseline',
      'profit_stop' => 'take_profit',
      'user_cancel' => 'terminated_by_user',
      'liquidation' => 'liquidation',
      _ => null,
    };
  }

  /// Appends a P&L=0 clarification and whether [base] is marked Last
  /// (retired), to any termination [reason] - shared tail for every
  /// history-recording site in this class (2026-09-20, per the user:
  /// "also mention P&L is 0 if terminated this way, also mention if the
  /// bot was last or not").
  String _withTerminationContext(
    String reason,
    String base,
    AutoCategory category, {
    double? realizedProfit,
  }) {
    var text = reason;
    if (realizedProfit == 0) text += ' P&L: \$0.00.';
    if (retired.isRetiredBase(base, category)) {
      text += ' Marked Last - will not auto-recreate.';
    }
    return text;
  }

  /// Diagnostic only (2026-09-14, per an external review of the
  /// BOT_INTERNAL_ERROR investigation) - picks out just the headers useful
  /// for telling requests apart (request/trace ids, dates, any rate-limit
  /// hints, the edge/server that handled it) instead of dumping the whole
  /// header map into every log line.
  String _diagnosticHeaders(Map<String, String>? headers) {
    if (headers == null) return 'none';
    const wanted = [
      'date',
      'x-request-id',
      'x-trace-id',
      'cf-ray',
      'server',
      'retry-after',
      'x-ratelimit-remaining',
      'x-ratelimit-limit',
    ];
    final picked = <String>[];
    for (final key in wanted) {
      final value = headers[key];
      if (value != null) picked.add('$key=$value');
    }
    return picked.isEmpty ? 'none of the tracked keys present' : picked.join(', ');
  }

  String _baseOf(String symbol) {
    final afterColon = symbol.split(':').last;
    final afterSlash = afterColon.split('/').first;
    final afterUnderscore = afterSlash.split('_').first;
    return afterUnderscore.replaceAll('USDT', '');
  }

  String _normalizeBase(String base) =>
      '${base.replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '')}.PERP';

  /// The one canonical pair key used to filter [_activeGridsById] by pair -
  /// Pionex's own base always carries ".PERP" (that's what [GridBot.pairKey],
  /// populated straight from real Pionex data, actually looks like), but a
  /// base derived from a TradingView chart symbol (via [_baseOf]) never
  /// does. Every ad-hoc "$base/USDT" key built from a chart-derived base
  /// silently never matched a real running grid - this was confirmed live
  /// (2026-09-05/06): an auto-managed bot already running on Pionex was
  /// treated as brand-new, got blocked by Pionex's own per-symbol
  /// position cap, and never made it into the Auto Bots report. Always
  /// build the key through here instead of inlining "$base/USDT".
  String _gridKey(String base) => '${_normalizeBase(base)}/USDT'.toUpperCase();

  /// The app-owned grid for [pairKey] under [category], if Pionex is
  /// currently running one - never a manual bot, and never a different
  /// category's own bot on the same pair (2026-09-07: a pair can have up to
  /// 3 simultaneous app-owned grids, one per category, each fully
  /// independent - confirmed live 2026-09-06 that Pionex genuinely allows
  /// more than one grid per pair at once).
  GridBot? _appGridForKey(String pairKey, AutoCategory category) =>
      _activeGridsById.values.cast<GridBot?>().firstWhere(
        (b) =>
            b?.pairKey == pairKey &&
            b?.appInitiated == true &&
            // Untagged (pre-existing/adopted-before-this-feature) bots
            // default to 1H - per the user (2026-09-07): "current auto
            // trades... are at engine 1H list".
            (botCategories.categoryOf(b?.buOrderId) ?? AutoCategory.oneHour) ==
                category,
        orElse: () => null,
      );

  /// How many real, currently-open app-initiated grids are tagged to
  /// [category] right now - used to decide whether that category's "next
  /// checkup" countdown should show at all (2026-09-09, per the user: no
  /// countdown once this hits 0, even if the category's watchlist still has
  /// bases waiting to recycle-reopen). Same untagged-defaults-to-1H rule as
  /// [_appGridForKey].
  int _activeAppGridCountFor(AutoCategory category) => _activeGridsById.values
      .where(
        (b) =>
            b.appInitiated &&
            (botCategories.categoryOf(b.buOrderId) ?? AutoCategory.oneHour) ==
                category,
      )
      .length;

  /// Any non-app-initiated grid currently running on [pairKey] - for
  /// logging/"don't touch it" purposes only, never for deciding whether the
  /// app's own grid exists.
  GridBot? _manualGridForKey(String pairKey) =>
      _activeGridsById.values.cast<GridBot?>().firstWhere(
        (b) => b?.pairKey == pairKey && b?.appInitiated != true,
        orElse: () => null,
      );

  /// True if Pionex is currently running ANY grid (app-owned or manual) on
  /// [pairKey].
  bool _anyGridForKey(String pairKey) =>
      _activeGridsById.values.any((b) => b.pairKey == pairKey);

  /// The candle-gate reference symbol decides whether the ENTIRE cycle runs
  /// a full checkup this tick — so a single chronically-broken symbol stuck
  /// at the front of the Red List (e.g. an invalid/delisted ticker that will
  /// never resolve on TradingView, not a transient load hiccup) must never
  /// be allowed to freeze every other pair forever. Picks the first Red List
  /// symbol that hasn't racked up too many consecutive indicator-load
  /// failures, falling through to the next one instead — the Red List
  /// itself is never touched here, only your own edits in TradingView can
  /// change it; this just stops trusting a specific entry as the gatekeeper.
  static const _referenceFailureThreshold = 3;

  String? _pickReferenceSymbol(List<String> redList) {
    if (redList.isEmpty) return null;
    for (final symbol in redList) {
      final fails = _indicatorWaitFailures[symbol] ?? 0;
      if (fails < _referenceFailureThreshold) {
        if (symbol != redList.first) {
          logger.log(
            'CANDLE GATE: skipping ${redList.first} as reference (>= $_referenceFailureThreshold consecutive '
            'indicator-load failures) - using $symbol instead. Red list itself left untouched.',
          );
        }
        return symbol;
      }
    }
    // Every candidate is currently stuck - still attempt the first one
    // rather than silently doing nothing, so the failure keeps logging.
    logger.log(
      'CANDLE GATE: every Red-list symbol has >= $_referenceFailureThreshold consecutive indicator-load failures - '
      'falling back to ${redList.first} anyway.',
    );
    return redList.first;
  }

  void _onLoopTick() {
    _checkPowerUpEdge();
    unawaited(_runCycleGuarded());
  }

  /// Fires the Pionex-futures-listing refresh exactly once per Power-up -
  /// detected as the PAUSE file going from present to absent (or the
  /// engine's very first tick with it already absent, i.e. a fresh start
  /// with Power already on). Per the user (2026-09-06): this must happen
  /// on Power-up, not on every tick while Power stays on.
  void _checkPowerUpEdge() {
    // Power ON starts this process, so its first tick is the Power-up
    // (Auto is a separate switch now and no longer marks it).
    final justPoweredUp = _pauseFileLastSeen == null;
    _pauseFileLastSeen = false;
    if (justPoweredUp) {
      logger.log('POWER UP: refreshing the Pionex futures listing.');
      unawaited(_refreshPionexFuturesListing());
    }
  }

  /// Categories waiting for their turn at the shared chart (2026-09-07) -
  /// added whenever a category's own force-trigger finds the chart busy
  /// (with Checkup, a pair action, or a DIFFERENT category), when
  /// Checkup/a pair action preempts the ONE category currently running, or
  /// (2026-09-19) when a routine tick's own candle boundary is genuinely
  /// due while a DIFFERENT category holds the chart - see
  /// [_runAutoCheckupGuarded]'s 2026-09-19 revision. Drained (one at a
  /// time) the moment anything frees the chart - see
  /// [_wakePendingAutoCategory].
  final Set<AutoCategory> _autoPendingCategories = {};

  void _wakePendingAutoCategory() {
    if (_autoPendingCategories.isEmpty) return;
    final next = _autoPendingCategories.first;
    _autoPendingCategories.remove(next);
    logger.log('autoCheckup[${next.label}]: taking its turn at the chart now.');
    unawaited(_runAutoCheckupGuarded(next, force: true));
  }

  Future<void> _runCycleGuarded() async {
    if (_mainLoopRunning ||
        _pairActionRunning ||
        _anyAutoRunning ||
        _stopLossLockRunning ||
        _pairActionResumeSymbols != null) {
      // An explicit fresh-checkup request (Check now, or Start) always wins
      // over whatever's already running: flag the in-flight work to cancel
      // itself early (see the per-pair loop in _runCycle/_runAutoCheckup)
      // rather than silently dropping this request or leaving it to queue.
      // The CHECKNOW file itself is left untouched here - the fresh cycle
      // that follows consumes it normally, exactly once.
      if (_mainLoopRunning && storage.fileExists(storage.checknowFile)) {
        _freshCycleRequested = true;
        logger.log(
          'mainLoop: fresh checkup requested while a cycle is already running - cancelling it now to start clean.',
        );
        return;
      }
      if (_mainLoopRunning && storage.fileExists(storage.pairActionFile)) {
        _cycleCancelledForPairAction = true;
        logger.log(
          'mainLoop: a Controls-screen pair action is waiting for the chart - cancelling the in-progress cycle now so it can run immediately.',
        );
        return;
      }
      if (_anyAutoRunning && storage.fileExists(storage.checknowFile)) {
        // Per the user: an explicit Check Now/Start always postpones a
        // running auto-checkup (never cancels it outright) - it resumes
        // once this checkup finishes, see the finally block below.
        final running = _runningAutoCategory;
        _autoCheckupCancelledForCheckup = true;
        if (running != null) _autoPendingCategories.add(running);
        logger.log(
          'mainLoop: fresh checkup requested while auto-checkup${running != null ? '[${running.label}]' : ''} has the chart - postponing it, it resumes once this finishes.',
        );
        return;
      }
      logger.log(
        _pairActionRunning
            ? 'mainLoop: a Controls-screen pair action is running - skipping this tick (single TradingView chart, never navigate it from two places at once)'
            : (_anyAutoRunning
                  ? 'mainLoop: auto-checkup is running - skipping this tick (no Checknow pending, so it is not owed the chart right now)'
                  : 'mainLoop: previous cycle still running - skipping this tick (not starting a second overlapping cycle)'),
      );
      return;
    }
    // Checkup is on-demand only (Check Now/Start) since 2026-09-04 - it no
    // longer runs automatically on a timer. Consuming the CHECKNOW file
    // happens inside _runCycle itself further down; this is just "is there
    // any reason to run at all right now" so a routine timer tick with
    // nothing pending is a true no-op, not an empty sweep.
    if (_checkupResumePairs == null &&
        !storage.fileExists(storage.checknowFile)) {
      return;
    }
    // Bug fixed 2026-09-16, per the user ("why every time i click on
    // thunder icon in waiting pair it give 'time out'" / "why waiting
    // engine is idel while there are no current running auto trade"): a
    // pair action (Ignite/Stop/Last/Check/etc, see pairActionFile) that
    // arrives while Checkup is mid-sweep correctly sets
    // _cycleCancelledForPairAction and pauses at the next per-pair
    // checkpoint (see the busy-guard block above) - but once paused,
    // _mainLoopRunning goes false and this routine timer tick (_loopTimer,
    // every pollIntervalSec) had no idea a pair action was still waiting:
    // it just saw _checkupResumePairs != null and barreled ahead resuming
    // the sweep, re-grabbing the chart before _onPairActionTick's own 2s
    // poll ever got a turn - and starving the Auto-checkup/waiting-bases
    // track the same way, since it's gated behind the same busy-guard.
    // Confirmed live: this raced _pairActionTimer over and over, ~every
    // 10s, for 35+ seconds straight before the pair action finally won -
    // past the GUI's 45s timeout. The correct handoff already exists
    // (_resumeWhateverWasPausedForPairAction, called from
    // _onPairActionTick's finally block once the action is actually done)
    // - this routine tick must defer to it instead of resuming on its own.
    if (storage.fileExists(storage.pairActionFile)) {
      return;
    }
    _mainLoopRunning = true;
    var watchdogTripped = false;
    final watchdog = Timer(CoreConstants.mainLoopWatchdog, () {
      watchdogTripped = true;
      _consecutiveWatchdogTrips++;
      logger.log(
        'MAINLOOP WATCHDOG: cycle exceeded ${CoreConstants.mainLoopWatchdog.inSeconds}s (stuck) - aborting cycle, dropping CDP client '
        '(consecutive=$_consecutiveWatchdogTrips)',
        level: 'CRITICAL',
      );
      if (_consecutiveWatchdogTrips >= _chronicWatchdogThreshold) {
        logger.log(
          'MAINLOOP WATCHDOG: $_consecutiveWatchdogTrips consecutive stuck cycles - this looks chronic, not a one-off '
          'hiccup. Likely needs manual attention (a stuck dialog, a crashed TradingView renderer, or a hung network call) '
          'rather than another automatic retry.',
          level: 'CRITICAL',
        );
      }
      _cdp?.close();
      _cdp?.dead = true;
      _mainLoopRunning = false;
    });
    try {
      await _runCycle();
      if (!watchdogTripped) _consecutiveWatchdogTrips = 0;
    } catch (e, st) {
      logger.log('mainLoop cycle error: $e', level: 'ERROR');
      logger.log(st.toString(), level: 'ERROR');
    } finally {
      watchdog.cancel();
      _mainLoopRunning = false;
      // Progress (checkupPairIndex/Total) stays as-is while merely paused
      // for a handoff (still conceptually "in progress" - the Check Now
      // button should keep showing it) - only cleared once the pass has
      // genuinely ended, so it doesn't linger showing a stale "12/27" once
      // Checkup is actually idle.
      _writeStatus(
        message: _checkupResumePairs != null
            ? 'Paused, waiting to resume...'
            : '',
        busy: false,
        checkupPairIndex: _checkupResumePairs != null ? null : 0,
        checkupPairTotal: _checkupResumePairs != null ? null : 0,
      );
    }
    if (_cycleCancelledForPairAction) {
      _cycleCancelledForPairAction = false;
      // Deliberately NOT restarting a cycle here (unlike the fresh-checkup
      // branch below) - the pair action just needed the chart free, not a
      // whole new sweep. _pairActionTick's own timer picks the pending
      // request up on its next poll once _mainLoopRunning is false; normal
      // cycling resumes on the main loop's own schedule regardless.
      logger.log(
        'mainLoop: cycle cancelled for a pending pair action - not auto-restarting a sweep here.',
      );
    }
    if (_cycleCancelledForAutoCheckup) {
      _cycleCancelledForAutoCheckup = false;
      // Same reasoning as the pair-action case above - the queued Auto
      // category (already added to _autoPendingCategories at the point of
      // cancellation) is what needs the chart, not a whole new Check Now
      // sweep. _wakePendingAutoCategory() below hands it the chart; Check
      // Now's own remaining pairs stay in _checkupResumePairs for its next
      // natural mainLoop tick to pick back up once that category is done.
      logger.log(
        'mainLoop: cycle cancelled for a pending Auto category - not auto-restarting a sweep here.',
      );
    }
    if (_freshCycleRequested) {
      _freshCycleRequested = false;
      logger.log(
        'mainLoop: starting the fresh cycle that cancelled the previous one.',
      );
      // Bug fixed 2026-09-09: the cancelled cycle already consumed (deleted)
      // CHECKNOW before it ever reached the point where it noticed this
      // flag and broke out - so without re-touching it here, the restarted
      // _runCycleGuarded() call hits the "on-demand only" gate (needs
      // CHECKNOW present or a resume pending, neither true here) and
      // silently no-ops forever. The whole checkup would then appear to
      // just stop dead after whichever single pair it had reached, with
      // nothing left to explain why - exactly what made "Check Now" look
      // like it wasn't running any category at all.
      storage.touchFile(storage.checknowFile);
      unawaited(_runCycleGuarded());
      return;
    }
    // Hands the chart to whichever Auto category (if any) is waiting for
    // its turn - the one Checkup itself just preempted (if any), or any
    // other that queued up in the meantime.
    _wakePendingAutoCategory();
  }

  void _onAutoLoopTick(AutoCategory category) {
    final forced = storage.fileExists(storage.autoCheckNowFileFor(category));
    if (forced)
      storage.deleteFileIfExists(storage.autoCheckNowFileFor(category));
    unawaited(_runAutoCheckupGuarded(category, force: forced));
  }

  /// Drives one category's Auto-checkup track. [force] is only ever true
  /// for that category's explicit "on" trigger (and its own relaunch after
  /// waiting its turn) - routine timer ticks never set it.
  /// Concurrency model, revised 2026-09-11 (was: "this category never
  /// preempts anything," 2026-09-07): if the chart is busy ONLY because
  /// Check Now/Start has it, and this category's own candle boundary has
  /// genuinely come due (or it was force-triggered), it now preempts that
  /// sweep - see [_cycleCancelledForAutoCheckup] - rather than queuing
  /// behind it. A busy pair action still keeps the original rule: this
  /// category just queues itself in [_autoPendingCategories] (when force)
  /// or waits for its own next routine tick (when not). Checkup and pair
  /// actions can still preempt THIS category if it's the one currently
  /// running - see
  /// [_autoCheckupCancelledForCheckup]/[_autoCheckupCancelledForPairAction].
  ///
  /// Revised again 2026-09-19, live (per the user - 1H silently never ran
  /// once for 7+ minutes straight while 3m stayed continuously busy): a
  /// DIFFERENT already-running category no longer means "just wait for my
  /// own next routine tick" - if this category's own boundary is
  /// genuinely due (or force), it now queues in [_autoPendingCategories]
  /// exactly like the Check Now/Start case, so [_wakePendingAutoCategory]
  /// picks it up the instant the other category's pass ends, rather than
  /// depending on an idle gap that a saturated category may never leave.
  /// Still never preempts/cancels the other category's in-progress pass -
  /// only Check Now/Start are ever preempted.
  Future<void> _runAutoCheckupGuarded(
    AutoCategory category, {
    bool force = false,
  }) async {
    if (_mainLoopRunning ||
        _pairActionRunning ||
        _anyAutoRunning ||
        _stopLossLockRunning) {
      if (_autoRunning[category] == true) {
        // Re-entrant: this SAME category was triggered again while its own
        // pass is still running. Only a genuine explicit re-trigger (force)
        // counts as the "second trigger" the user's rule 2 means - per the
        // doc comment above, routine (non-force) timer ticks must NEVER set
        // this, or a single pass running even slightly long (e.g. repeated
        // pairAction contention) causes this category to relaunch itself
        // forever the instant it finishes, without ever going idle. Bug
        // fixed 2026-09-07 (was unconditional): a pure routine tick landing
        // on a busy pass is simply dropped - the category gets its next
        // real chance on its own schedule.
        if (force) _autoForceRequested[category] = true;
        return;
      }
      // Per the user (2026-09-11): an Auto category's own genuine candle
      // boundary always takes priority over an in-progress Check Now
      // sweep OR a multi-symbol Start - whichever has the chart pauses
      // (resuming once this category finishes), rather than this category
      // just waiting/queuing behind it. Extended 2026-09-11 (same day) to
      // cover Start too, per the user: "if auto cycle check started while
      // start now process, auto cycle will override and pause start now
      // process... once auto cycle finishes, start now process will
      // resume." Deliberately still scoped to ONLY these two specific
      // busy-reasons - a single-symbol check/add/remove pair action or a
      // DIFFERENT already-running Auto category keep their own separate,
      // pre-existing priority rules (this category still just
      // queues/waits for those, below).
      final checkNowBusy = _mainLoopRunning && !_pairActionRunning;
      final startBusy = _pairActionRunning && _pairActionIsStart;
      // With Auto (or this category) off there is nothing to run, so it must
      // never take the chart from Check Now (found live: it preempted Check
      // Now every 5s, did nothing, and Check Now restarted forever).
      final categoryOff =
          _forceStopActive() ||
          storage.fileExists(storage.autoCategoryPausedFileFor(category));
      if (!categoryOff &&
          (checkNowBusy || startBusy) &&
          _runningAutoCategory == null &&
          (force || _isNewCandleDueFor(category))) {
        if (checkNowBusy) {
          _cycleCancelledForAutoCheckup = true;
          logger.log(
            'autoCheckup[${category.label}]: candle boundary reached while Check Now has the chart - preempting it, Check Now resumes once this finishes.',
          );
        } else {
          _pairActionCancelledForAutoCheckup = true;
          logger.log(
            'autoCheckup[${category.label}]: candle boundary reached while Start has the chart - preempting it, Start resumes once this finishes.',
          );
        }
        _autoPendingCategories.add(category);
        return;
      }
      // Bug fixed 2026-09-19, live (per the user: "the status of 1H is not
      // ok" - confirmed via log evidence: 112 consecutive mainLoop ticks
      // over 7+ minutes with ZERO 1H activity, because 3m's own sweep
      // never once went idle in that window). A DIFFERENT auto category
      // already running used to mean a routine (non-force) tick simply
      // gave up here and waited for its OWN next routine timer tick, per
      // the 2026-09-11 design - a reasonable assumption back when each
      // category's sweep was short enough to leave regular idle gaps
      // between passes. With 5 categories now, and one (3m, grown to 13
      // auto-managed bases) able to run one long uninterrupted pass right
      // after another with no natural gap at all, that assumption silently
      // starved 1H indefinitely - not delayed, genuinely never running.
      // Fixed the same way Check Now/Start busy already works above: if
      // THIS category's own candle boundary has genuinely come due (or it
      // was force-triggered) while a DIFFERENT category holds the chart,
      // queue it - `_wakePendingAutoCategory()` (called at the end of
      // every category's own pass) picks it up the moment that OTHER
      // category's current pass ends, instead of gambling on an idle gap
      // that may never come. Deliberately still never cancels/preempts the
      // other category's in-progress pass - only Check Now/Start ever get
      // preempted; one Auto category simply waits its turn behind another.
      if (_runningAutoCategory != null &&
          (force || _isNewCandleDueFor(category))) {
        _autoPendingCategories.add(category);
        logger.log(
          'autoCheckup[${category.label}]: candle boundary reached while ${_runningAutoCategory!.label} has the chart - queued, will run as soon as it frees up.',
        );
        return;
      }
      if (!force) return;
      // Force-triggered but the chart belongs to something else right now -
      // queue this category rather than fighting for the chart; whoever's
      // using it wakes the next queued category the moment they're done
      // (see _wakePendingAutoCategory).
      _autoPendingCategories.add(category);
      logger.log(
        'autoCheckup[${category.label}]: chart is busy - queued, will run as soon as it frees up.',
      );
      return;
    }
    _autoRunning[category] = true;
    try {
      await _runAutoCheckup(category, force: force);
    } catch (e, st) {
      logger.log('autoCheckup[${category.label}] error: $e', level: 'ERROR');
      logger.log(st.toString(), level: 'ERROR');
    } finally {
      _autoRunning[category] = false;
      _writeStatus(
        category: category,
        autoMessage: _autoResumePairs[category] != null
            ? 'Paused, waiting to resume...'
            : '',
        autoBusy: false,
      );
    }
    // Captured BEFORE clearing, below - if pairAction cancelled this pass,
    // it only stopped early because a pairAction needs the chart; that
    // pairAction's OWN completion (_onPairActionTick's next poll, once
    // _anyAutoRunning genuinely reads false and it actually reads+processes
    // the pending request) is what must wake the queue, never this pass
    // itself. Bug fixed 2026-09-07: this used to fall through to
    // _wakePendingAutoCategory() unconditionally below, which - since this
    // very category had just queued itself in _onPairActionTick's own
    // preemption branch - woke itself right back up before the real
    // pairAction ever got a chance to run, an infinite self-relaunch loop
    // that starved pairAction forever and kept flipping the shared chart
    // between whatever bases this category was mid-sweep on (the reported
    // symptom: TradingView flipping between two symbols every second,
    // forever). Checkup's cancellation is different - the checknowFile
    // check below IS its legitimate handoff (checkup relies on this pass
    // noticing checknowFile still exists to actually start itself), so only
    // pairAction's cancellation needs suppressing here.
    final cancelledForPairAction = _autoCheckupCancelledForPairAction;
    // Both flags MUST get reset regardless of which (if either) actually
    // fired - a stuck flag here would make every future auto-checkup pass
    // for THIS category cancel itself instantly at the first base forever.
    _autoCheckupCancelledForCheckup = false;
    _autoCheckupCancelledForPairAction = false;
    if (_pairActionResumeSymbols != null) {
      // Per the user (2026-09-11): a paused Start resumes before a paused
      // Check Now does - Start was the MORE RECENT interruption (Check
      // Now, if it's also waiting, was paused for Start in the first
      // place, before this category ever got involved), and
      // _resumePausedStartAction itself calls
      // _resumeWhateverWasPausedForPairAction once Start is genuinely,
      // finally done - so Check Now's own turn still comes, just after
      // Start's, not instead of it.
      unawaited(_resumePausedStartAction());
    } else if (_checkupResumePairs != null ||
        storage.fileExists(storage.checknowFile)) {
      // Freeing the chart here means a paused/pending checkup can continue
      // (or start) right away, rather than waiting on the next routine
      // timer tick (which, being on-demand only, is otherwise the only
      // other thing that would ever pick it up).
      unawaited(_runCycleGuarded());
    } else if (cancelledForPairAction) {
      // Do nothing - see the comment above. Relaunching or waking the queue
      // ourselves here would race the real pairAction for the chart it just
      // asked for.
    } else if (_autoForceRequested[category] == true) {
      _autoForceRequested[category] = false;
      logger.log(
        'autoCheckup[${category.label}]: relaunching the force-requested pass that was queued behind this one.',
      );
      unawaited(_runAutoCheckupGuarded(category, force: true));
    } else {
      _wakePendingAutoCategory();
    }
  }

  /// How long after a real candle boundary the auto-checkup cycle waits
  /// before treating it as "due" (2026-09-15, per the user: "if you view
  /// ll/hh at the beginning of the candle cycle, trading view still not
  /// sure if this is true ll/hh or fake ll/hh... you can shift the cycle
  /// of auto to start after 10 seconds of candle show"). Applied inside
  /// [_candleBoundary] itself so every caller shifts together, including
  /// the waiting engine's own "yield to the real 3m pass" check
  /// (`_isNewCandleDueFor` in `_runWaitingEngine`) - confirmed with the
  /// user this is wanted, not just tolerated: the waiting engine gets 10s
  /// MORE uninterrupted retry time per cycle before it hands the chart
  /// over, not less. Its own retry cadence (20s cooldown, per-base order)
  /// is untouched either way - only the moment it yields shifts.
  static const _candleBoundarySettleDelay = Duration(seconds: 10);

  /// [category]'s own candle boundary right now, at that category's own
  /// cadence (top of the current minute/hour/day, UTC) - offset back by
  /// [_candleBoundarySettleDelay] so a boundary only counts as "reached"
  /// once the new candle has had a few seconds to actually settle on
  /// TradingView, not the instant it opens.
  ///
  DateTime _candleBoundary(DateTime nowUtc, AutoCategory category) {
    nowUtc = nowUtc.subtract(_candleBoundarySettleDelay);
    switch (category) {
      case AutoCategory.oneHour:
        return DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day, nowUtc.hour);
    }
  }

  /// Pure peek at whether [category]'s candle boundary has genuinely moved
  /// on since its last real check - same wall-clock comparison
  /// `_runAutoCheckup`'s own candle gate uses, but read-only (never touches
  /// `_lastAutoCandleTs`). Added 2026-09-11 so `_runAutoCheckupGuarded` can
  /// decide whether THIS tick is worth preempting a running Check Now
  /// sweep for, before ever reaching the real gate (which only runs once
  /// the chart is actually free).
  bool _isNewCandleDueFor(AutoCategory category) {
    final boundaryMs = _candleBoundary(
      DateTime.now().toUtc(),
      category,
    ).millisecondsSinceEpoch;
    return _lastAutoCandleTs[category] != boundaryMs;
  }

  /// The last "nothing to do" line each category logged, so it is written
  /// once per change instead of every tick.
  final Map<AutoCategory, String> _lastIdleNote = {};

  /// Categories whose Power-on reverse check has run in this process.
  final Set<AutoCategory> _reverseCheckDone = {};

  Future<void> _runAutoCheckup(
    AutoCategory category, {
    bool force = false,
  }) async {
    final tag = '[${category.label}]';
    // Auto off, or this category's own chip off: skipped entirely, the same
    // as tradingMT5 - nothing is read and nothing closes, "Last"-marked bots
    // included.
    final paused =
        _forceStopActive() ||
        storage.fileExists(storage.autoCategoryPausedFileFor(category));
    // Auto watches ONLY auto-managed bases - never manual bots.
    final bases = paused
        ? <String>{}
        : autoManagedByCategory[category]!.loadAutoManagedBases();
    if (bases.isEmpty) {
      // Bug fixed 2026-09-14, confirmed live: this early return used to skip
      // the candle-gate write below entirely - an EMPTY category could
      // never mark its own boundary as seen, so _isNewCandleDueFor stayed
      // permanently true for the rest of the hour/day/minute, and this
      // category preempted Check Now/Start on every single timer tick
      // forever (confirmed: Check Now stuck re-checking the same first pair
      // in a loop, checkup_pair_index never advancing past 1). Mark it seen
      // here too - there's no per-base work being gated when there's
      // nothing to check anyway.
      _lastAutoCandleTs[category] = _candleBoundary(
        DateTime.now().toUtc(),
        category,
      ).millisecondsSinceEpoch;
      // Logged once per change, not every 5s tick.
      final note = paused
          ? 'autoCheckup$tag: Auto off - nothing read, nothing done.'
          : 'autoCheckup$tag: no auto-managed bases to check right now.';
      if (_lastIdleNote[category] != note) {
        _lastIdleNote[category] = note;
        logger.log(note);
      }
      return;
    }
    _lastIdleNote.remove(category);
    // Reverse check, as tradingMT5's `_reverseCheckOnTechniqueSwitchIfNeeded`:
    // the first pass with Auto on after Power ON (this process's start) -
    // Power ON with Auto already on, or Auto switched on later - sweeps every
    // auto-managed pair now instead of waiting for the next candle. Each
    // pair's first check is the immediate one (`_worm10StartupChecked`):
    // still triple-read, acting on a closed candle without the extra-candle
    // wait.
    if (_reverseCheckDone.add(category)) {
      force = true;
      logger.log(
        'autoCheckup$tag: Power on / Auto on - reverse-checking every '
        'auto-managed pair now.',
      );
    }
    final resuming = _autoResumePairs[category] != null;
    // Bug fixed 2026-09-27, real-money-adjacent (per the user: "why when i
    // terminate a bot ... everything stuck" - traced to the GUI, not the
    // engine: sustained 100-170% CPU in the Flutter process, confirmed live
    // via `pidstat`). Root cause: this write used to fire UNCONDITIONALLY
    // on every single tick of this function, including the routine idle
    // (non-boundary) tick that runs every `pollIntervalSec` (~5s) and
    // returns immediately after `_runWaitingEngine()` a few lines below -
    // that early-return path never reaches this function's own
    // status-clearing write near its tail, so `autoBusy` for this category
    // read `true` almost permanently, not just during a genuine connect.
    // The GUI's own `ReuseStatusLight.evaluateAuto` treats ANY category's
    // `busy` as "blinking", which keeps `DashboardScreen._ensureBlink`'s
    // Timer.periodic alive indefinitely - rebuilding the whole Auto+Manual
    // bot tables (now heavier, with the Entry-signal column) every
    // 180-500ms forever. Only write it when a real connect is about to
    // happen (`_cdp == null`, matching the exact condition `_cdp ??=
    // await _connect()` below actually gates on) - `_connect()` itself
    // already writes its own accurate "Connecting to chart..." the moment
    // it genuinely needs to open a fresh WebSocket, so nothing about a real
    // reconnect's visibility is lost.
    if (_cdp == null) {
      _writeStatus(
        category: category,
        autoMessage: 'Connecting to chart...',
        autoBusy: true,
      );
    }
    _cdp ??= await _connect();
    if (_cdp == null) {
      logger.log(
        'autoCheckup$tag: could not connect to TradingView - skipping this pass.',
      );
      return;
    }

    // Per the user (2026-09-05, extended 2026-09-07 to 3 categories): each
    // category only actually re-checks at the start of its OWN new candle
    // (1m/1H/1D), not continuously every poll tick. force=true (that
    // category's own explicit trigger, or Start's own trigger) and a
    // resumed mid-pause pass both bypass this - a mid-pause resume already
    // passed the gate when the pass first began.
    // Deliberately wall-clock, NOT a chart read: an earlier version probed
    // a reference symbol via _checkBuySellOnPair to decide whether to
    // skip - that read is itself a full chart/indicator round trip, so it
    // ran every 5s tick just to conclude "unchanged, skip" every time,
    // hammering the chart constantly and starving the real per-base loop
    // (which is what actually refreshes the Auto Bots report) for the
    // entire candle. The gate itself must cost nothing.
    if (!force && !resuming) {
      final boundaryMs = _candleBoundary(
        DateTime.now().toUtc(),
        category,
      ).millisecondsSinceEpoch;
      if (_lastAutoCandleTs[category] != null &&
          boundaryMs == _lastAutoCandleTs[category]) {
        // Bug fixed 2026-09-26, live (per the user: "why waiting engine is
        // not working? why it is waiting for the next H1 cycle?" - traced
        // to 4 real bases, AVAX/BCH/DOGE/SHIB, sitting in Waiting for 6-11+
        // minutes after genuinely closing via the new opposite-signal rule
        // that now lets a tagged bot close on signal - confirmed the real
        // cause: `_runWaitingEngine()` was ONLY ever reachable from the
        // tail of a category's pass that got PAST both this candle gate
        // and the earlier "off, nothing to watch" one - with every other
        // category paused (confirmed live: AUTO_PAUSED_* files for 1m/5m/
        // 15m/1D all present) and 1H's own real boundary only once an
        // hour, the waiting engine's whole "retry ASAP, don't wait for the
        // next cycle" design was starved down to an hourly cadence. This
        // category's own idle (non-boundary) ticks already run every
        // `pollIntervalSec` regardless - riding the waiting engine along on
        // THEM too (already-connected `_cdp`, already inside this
        // category's own `_autoRunning` guard, same safe context the
        // matching call at this function's tail already uses) restores the
        // original near-immediate retry cadence without needing a whole
        // separate concurrency-aware timer. The function itself is a fast
        // no-op the moment the waiting list is genuinely empty, so this
        // costs nothing on the (normal) case where nothing is waiting.
        // Explicitly idles this category's own status before handing off
        // (2026-09-27, part of the same fix as the `_cdp == null` guard
        // above) - this idle tick may have just written "Connecting to
        // chart..." moments ago if a fresh connect genuinely happened, and
        // this early return skips the tail-of-function clear a real
        // per-base pass would otherwise reach.
        _writeStatus(category: category, autoMessage: '', autoBusy: false);
        await _runWaitingEngine(category);
        return;
      }
      _lastAutoCandleTs[category] = boundaryMs;
      // Bug fixed 2026-09-12, per the user - a genuine new candle-gated
      // sweep for this category just started, so its cycle marker advances
      // (see AutoCategoryStatus.cycleMarkerIndex's doc). Deliberately only
      // here, inside the real candle gate - a force-triggered/manual check
      // isn't a new scheduled interval, so it reuses whatever marker is
      // already current instead of advancing it.
      _cycleMarkerIndex[category] = ((_cycleMarkerIndex[category] ?? 0) + 1) % 3;
      logger.log(
        'autoCheckup$tag CANDLE GATE: new candle ($boundaryMs) - running the check.',
      );
    } else if (force && !resuming) {
      // Bug fixed 2026-09-14, confirmed live: a force:true run only ever
      // happens via _wakePendingAutoCategory, i.e. AFTER this category's
      // own candle boundary was already found genuinely due and preempted
      // whatever had the chart - but the block above (which marks that
      // boundary "seen") was skipped entirely for force, so the very
      // condition that caused the preemption never cleared. Every
      // following routine tick (and the waiting engine's own internal
      // `_isNewCandleDueFor` check, deeper in this function) kept seeing
      // "still due" and preempted again, forever - confirmed live: a
      // pending Start (ADAUSDT) sat starved behind an infinite
      // preempt/yield loop between this category and Check Now until it
      // hit the GUI's own 75s timeout. Deliberately still skips the
      // cycle-marker advance (per the comment above - a force-triggered
      // check isn't a new scheduled slot) - only marks the boundary seen.
      _lastAutoCandleTs[category] = _candleBoundary(
        DateTime.now().toUtc(),
        category,
      ).millisecondsSinceEpoch;
    }
    // Per the user (2026-09-05): a base already genuinely running on
    // Pionex was getting treated as brand-new (in-memory
    // _activeGridsById was still empty, since only Checkup - on-demand
    // only - ever refreshed it) and blocked by the exchange's own
    // per-symbol position cap instead of being adopted - which also meant
    // it never made it into the Auto Bots report. Auto-checkup must sync
    // this itself, not assume Checkup already has.
    await _refreshActiveGrids();
    // Per the user (2026-09-06): no qualifySymbol/"BINANCE:" guessing here
    // either - a bare "${b}USDT" lets TradingView resolve the exchange
    // itself, same as everywhere else this was fixed.
    final remaining = List<String>.from(
      _autoResumePairs[category] ?? bases.map((b) => '${b}USDT'.toUpperCase()),
    );
    _autoResumePairs[category] = null;
    if (resuming) {
      logger.log(
        'autoCheckup$tag: resuming the paused pass - ${remaining.length} base(s) left to check.',
      );
    } else if (remaining.isEmpty) {
      logger.log('autoCheckup$tag: no auto-managed bases to check right now.');
      return;
    } else {
      logger.log(
        'autoCheckup$tag: checking ${remaining.length} auto-managed base(s): ${remaining.join(', ')}',
      );
    }

    // Tracks whether the loop below yielded the chart early (vs. running
    // every base it had) - the 1m fast-retry sub-pass added after this
    // loop must not run in that case, same as the main loop itself
    // backing off.
    var interrupted = false;
    while (remaining.isNotEmpty) {
      final symbol = remaining.removeAt(0);
      if (_autoCheckupCancelledForCheckup ||
          _autoCheckupCancelledForPairAction) {
        remaining.insert(0, symbol);
        _autoResumePairs[category] = remaining;
        logger.log(
          'autoCheckup$tag: pausing at $symbol (${remaining.length} base(s) left) - '
          '${_autoCheckupCancelledForCheckup ? "a checkup" : "a pair action"} needs the chart. Resuming once it is done.',
        );
        interrupted = true;
        break;
      }
      if (_forceStopActive()) {
        interrupted = true;
        break;
      }

      // Bug fixed 2026-09-12, per the user ("waiting engine check waiting
      // list and auto engine check ONLY running auto list... give auto
      // engine more time to check because now auto engine check both
      // waiting list and auto list too"): a base with no running grid
      // used to still get its full signal check + open attempt here
      // (indicator wait, range/TP-SL, grid-count probes, sometimes many
      // shrink retries) as part of the REGULAR pass - duplicated work,
      // since the waiting engine retries the exact same base again right
      // after anyway (with no delay, per the same-day one-attempt-per-
      // cycle fix). That duplicated work was real chart time the regular
      // pass should have spent on its actual, higher-priority job -
      // watching already-running positions for their close signal.
      // Skipped entirely here now (no signal check, no chart time at
      // all) - 100% deferred to the waiting engine, which already covers
      // every no-grid base across all 3 categories on its own list, so
      // nothing is orphaned, just no longer duplicated.
      final runningGrid = _appGridForKey(_gridKey(_baseOf(symbol)), category);
      if (runningGrid == null) {
        continue;
      }
      // "Never filled" zero-position safety check MOVED 2026-09-27, per the
      // user ("i want you to change the cycle per each interval to be 3
      // min ... even if the interval is 3m/5m/15m/1H/1D") - now runs on its
      // own fixed-cadence timer (`_runNeverFilledSweep`, every 3 minutes,
      // independent of whichever category the bot is tagged with) instead
      // of being gated by this category's own candle boundary, which used
      // to mean a 1H-tagged never-filled bot could sit uncancelled for up
      // to 2 hours. See that function for the full check.

      // Stop Loss Lock chart-time skip REMOVED 2026-09-25, per the user's
      // exact spec reworking the primary open/close signal rule: a tagged
      // base's already-running bot can now be closed by the normal signal
      // rule too, exactly like an untagged one (previously it could only
      // ever end via real Pionex TP/SL) - so its signal read here is no
      // longer wasted chart time, it's load-bearing again. This also
      // retires the need for the standalone `_adoptOpenEntryIfNeeded` call
      // that used to live here: `_manageGridPair`'s own "GRID ALREADY
      // RUNNING" branch already does that adoption inline, and now runs
      // for tagged bases again too.

      _writeStatus(
        category: category,
        autoMessage: 'Checking $symbol...',
        autoBusy: true,
      );
      _recordCycleMarker(_baseOf(symbol), category);
      final entryKey = '${_gridKey(_baseOf(symbol))}|${category.wireValue}';
      Worm10Event? confirmedEvent;
      try {
        confirmedEvent = await _confirmedWorm10Event(
          entryKey,
          symbol,
          category,
          immediate: _worm10StartupChecked.add(entryKey),
        );
      } catch (e) {
        logger.log('autoCheckup$tag CHECKUP $symbol error: $e');
      }
      _announceChartSignalIfFresh(symbol, category, confirmedEvent);
      final pairConfig = GridPairConfig(
        symbol: symbol,
        investment: pairInvestments.investmentOf(symbol),
      );
      try {
        // REVERTED (2026-09-10, per the user - recycle-reopen restored):
        // this used to be createBlocked:true unconditionally, per a
        // 2026-09-09 mandate that autonomous auto-checkup must NEVER open
        // ANY grid on its own initiative - that mandate was written after a
        // live incident where bases still sitting on the auto-managed list
        // reopened unexpectedly the moment an unrelated accounting bug got
        // fixed. The user has since clarified the actual, narrower rule: a
        // BRAND-NEW base the app has never opened still can never be
        // auto-created (still enforced elsewhere - see _runCycle's
        // createBlocked and _pairActionStart being the only paths that can
        // ever add a base to this list), but a base that IS already on
        // this list - which, per addBase's only two call sites, can only
        // happen after a real app-initiated grid the user explicitly
        // Started - should keep recycling through close-then-reopen on its
        // own from here on, exactly as the original design intended (see
        // the addBase call and comment in the create branch below). Safe:
        // `existing == null` (the precondition for the create branch to
        // even run) can only become true here via this SAME base's own
        // prior close, which - unless just-retired via "Last", handled by
        // the removeBase calls elsewhere - is exactly the reopen this
        // change restores.
        await _manageGridPair(
          pairConfig,
          confirmedEvent,
          checkNowTriggered: false,
          createBlocked: false,
          category: category,
        );
      } catch (e) {
        logger.log('autoCheckup$tag manageGridPair($symbol) error: $e');
      }
    }
    // Per the user (2026-09-11): "if the bot is in waiting (even if the
    // bot is set 1H and 1D) still the next try cycle is 1m - this is to
    // avoid any delay in starting the bot asap." Rides along on whichever
    // category's own pass just finished cleanly (same connection, same
    // concurrency guards already satisfied by getting this far) rather
    // than a whole separate track - only for bases that are auto-managed
    // but have NO running bot yet; an already-running bot's real
    // signal/close checks are completely unaffected - still exactly once
    // per that category's own cadence, as before.
    //
    // Bug fixed 2026-09-20, live (per the user: "i selected a list of 5 m
    // pairs in next trade table... they are now on waiting" / "5m engine
    // is not working... none of waiting bot started"): this used to only
    // ride along on the 3m pass specifically (`category ==
    // AutoCategory.oneMinute`), from back when only 3 categories existed
    // total. Confirmed live: with 3m switched OFF and only 5m switched
    // on, `_runWaitingEngine` never ran even once - 11 real waiting bases
    // sat untouched for nearly 2 hours, since NOTHING else in the regular
    // per-base auto-checkup loop ever attempts to open a no-grid base
    // (that's 100% this function's job, per the 2026-09-12 fix right
    // above). Now rides along on ANY category's clean pass, not just 3m's
    // - the loop inside is naturally idempotent (stops the instant the
    // waiting list is genuinely empty), so being triggered from more than
    // one category's pass back-to-back is harmless, just occasionally
    // redundant for a few iterations.
    if (!interrupted) {
      // Bug fixed 2026-09-12, per the user ("i feel 3m (auto) and waiting
      // are overlapping ... this should not occur"): confirmed via the
      // log that execution genuinely never overlaps (strictly sequential
      // timestamps, one `await` chain) - this was a display bug, not a
      // concurrency one. The `finally` block in `_runAutoCheckupGuarded`
      // that clears this category's `autoMessage`/`autoBusy` only runs
      // once `_runAutoCheckup` itself returns - but `_runAutoCheckup`
      // doesn't return until `_runWaitingEngine()` below ALSO finishes, so
      // the 3m status line stayed frozen on "Checking <last real base>..."
      // with busy=true for the entire waiting-engine phase, which can run
      // far longer than the auto pass itself. Cleared here, right before
      // the waiting engine takes over, so the 3m line correctly reads
      // idle the instant its own real work is done - matching what
      // actually happens underneath, not just looking like it might.
      _writeStatus(category: category, autoMessage: '', autoBusy: false);
      await _runWaitingEngine(category);
    }
  }

  /// "Support engine" (2026-09-11, per the user): once a category's own
  /// auto-checkup pass above finishes cleanly, if ANY auto-managed base
  /// across every category is still waiting (auto-managed but with no
  /// running grid yet), keep retrying the whole waiting list back-to-back
  /// with no delay between sweeps, instead of leaving a waiting base to sit
  /// idle until that category's own next scheduled tick. [category] is
  /// whichever pass just called this (threaded through only so the yield
  /// check below knows which category's own real scheduled pass to give
  /// way to - originally hardcoded to the since-removed `oneMinute`
  /// category back when it was the only trigger; generalized 2026-09-30
  /// when that category was removed entirely). Rides along on the exact
  /// same chart session/"this category's auto-checkup has the chart" busy
  /// state the pass above already holds (`_autoRunning[category]` stays
  /// true the whole time this runs, since it's called from inside that
  /// pass, before `_runAutoCheckupGuarded`'s finally block clears it) - so
  /// everything that already knows how to preempt/queue behind that state
  /// (Check Now, Start, a different Auto category, Power off) keeps
  /// working completely unmodified, via the exact same flags/checks the
  /// main loop above uses.
  ///
  /// Stops only when either condition the user described is no longer true:
  ///  - the waiting list is empty (nothing left to do), or
  ///  - the chart is genuinely needed elsewhere (Check Now, a pair action,
  ///    or a force-stop) - real competing chart usage, not a scheduling
  ///    formality.
  ///
  /// Bug fixed 2026-09-11, per the user, after two narrower timing fixes
  /// still wouldn't satisfy them: this used to ALSO stop the moment a new
  /// 3m candle boundary was due, on the theory that the real scheduled
  /// cycle should always preempt a lower-priority background sweep. Two
  /// increasingly-targeted attempts to patch around that check (skip it on
  /// entry only, then skip it for one guaranteed base too) both still left
  /// the waiting engine stopping after at most one base per invocation,
  /// because a full checkup pass runs right at the edge of its own 3-minute
  /// window (confirmed live: ~3 minutes for 11 bases, three specific
  /// symbols each taking ~25s longer than the rest to load) - meaning a new
  /// boundary was almost always already due the instant this got invoked.
  /// The user was explicit this isn't a bug to patch around at the margins:
  /// "waiting engine was create to minimize waiting list so it have to run
  /// once 3m stopped and it keep trying to launch auto bots in waiting
  /// list... i dont want waiting engine to wait until next cycle... until
  /// all waiting list bot launched." The candle-boundary check is removed
  /// entirely - this now runs until the waiting list is genuinely empty or
  /// something with a real claim on the chart needs it, with no time limit
  /// of its own. The regular checkup track can still run on its own normal
  /// schedule once this returns (or if Check Now/a pair action preempts it
  /// directly, exactly like every other chart user).
  /// True if the waiting engine already checked this exact (base,
  /// category) chart at least once during [category]'s CURRENT candle -
  /// meaning a re-check right now is guaranteed to hit the chart during
  /// the same candle a real attempt already covered. Read-only, no chart
  /// access - just a lookup plus two [_candleBoundary] computations.
  ///
  /// Bug fixed 2026-09-20, live (per the user: "why waiting in 1H having
  /// too many h1 waiting bots" / confirmed live: the waiting engine held
  /// the chart continuously for 28+ minutes, cycling through the same
  /// still-waiting 1H bases roughly every ~90s, each cycle spending a
  /// real ~6s confirmation-read on the chart only to rediscover the same
  /// "nothing newer yet" result). First version of this fix compared
  /// against [_freshEntrySignalBaseline] (the last SIGNAL actually
  /// seen) instead of [_waitingEngineLastAttemptAt] (the last time the
  /// chart was actually CHECKED) - wrong: a base whose real signal has
  /// been stale for many candles in a row keeps a baseline from way
  /// back, so "has the candle advanced past the baseline" was true again
  /// within seconds of the very next candle starting, and the exact same
  /// every-~90s hammering resumed on the very next hour. Gating on the
  /// last CHECK instead - not the last signal - correctly limits every
  /// base to at most one real chart check per candle, no matter how
  /// stale its actual signal is.
  bool _alreadyCheckedThisCandle(
    AutoCategory category,
    String triedKey,
  ) {
    final last = _waitingEngineLastAttemptAt[triedKey];
    if (last == null) return false;
    final lastCandle = _candleBoundary(last.toUtc(), category);
    final currentCandle = _candleBoundary(DateTime.now().toUtc(), category);
    return !currentCandle.isAfter(lastCandle);
  }

  Future<void> _runWaitingEngine(AutoCategory category) async {
    final categories = allAutoCategories;
    while (true) {
      // Bug fixed 2026-09-11, per the user, live ("ltc was already running
      // in auto.. but waiting engine still checking it??? why" / "engine
      // memory is not updated once bot unlisted in waiting list"):
      // [_appGridForKey] (used just below to decide who's still waiting)
      // reads `_activeGridsById`, which used to only get refreshed once,
      // by [_refreshActiveGrids], at the START of the regular checkup pass
      // - never again during THIS loop's own lifetime. That was fine back
      // when a candle boundary capped how long this loop could run; now
      // that it runs unbounded until the waiting list is genuinely empty
      // (see the "removed the candle-boundary stop entirely" fix, same
      // day), a base that successfully opens partway through - confirmed
      // live for LTC, then BCH - kept reading as "still has no grid" for
      // the rest of this run, since nothing here ever told
      // `_activeGridsById` a new one now exists. Re-fetching the live grid
      // list at the top of every iteration keeps that check honest for as
      // long as this loop actually runs.
      //
      // Bug fixed 2026-09-12, per the user, live ("3m engine is not
      // running and also waiting engine is not running??? keep eye on
      // both"): watching both statuses together over an actual minute
      // showed the 3m category's own busy/message staying blank the
      // WHOLE time - not a display glitch this time, a real one. Making
      // the waiting engine retry forever without ever returning (this
      // same day's cooldown fix, replacing the per-cycle throttle) meant
      // `_runAutoCheckup(oneMinute)` never returned either (this function
      // is called from its own tail), so `_autoRunning[oneMinute]` never
      // went back to false, and the REAL scheduled 3m pass - the one that
      // checks all the OTHER already-running bots for their close signal
      // - could never start again for as long as even one base (XRP,
      // confirmed live) kept failing to open. That starves the higher-
      // priority job this whole waiting engine is supposed to be
      // SUBORDINATE to (per the user's own same-day correction: "auto
      // engine is more priority than waiting engine"). Fixed by yielding
      // the moment a fresh 3m boundary is genuinely due - a cheap,
      // read-only wall-clock check, same one `_runAutoCheckup`'s own
      // candle gate uses - so the real scheduled pass always gets its
      // turn on time; it calls this function again at its own tail once
      // it finishes, resuming retries right where they left off. This is
      // NOT a return of the 2026-09-11 "stop retrying at the boundary"
      // design the user explicitly rejected that day - that version gave
      // up on the waiting list itself at each boundary; this one only
      // ever pauses retrying, briefly, to let the higher-priority real
      // job run, then keeps going.
      if (_isNewCandleDueFor(category)) {
        logger.log(
          'autoCheckup[${category.label}] waiting engine: a new ${category.label} cycle is due - yielding so the real scheduled pass can run, resuming after.',
        );
        _writeStatus(
          waitingEngineCurrentBase: '',
          waitingEngineIdleReason: 'new_cycle',
        );
        return;
      }
      await _refreshActiveGrids();
      // REVERSED 2026-09-14, per the user ("even if the bot is retired...
      // it should be shown in waiting list" - then, once shown, "why did
      // it not start" made clear the retired-base skip here was also
      // silently blocking the actual open attempt, not just the display):
      // a retired base's ONLY meaning is "don't auto-recreate it once it
      // closes" - it was never meant to also block a currently-queued
      // waiting base from ever being tried. Matches the same-day GUI-side
      // fix in `EngineControlRepository.waitingBases`.
      final waiting = <(AutoCategory, String)>[];
      for (final cat in categories) {
        if (storage.fileExists(storage.autoCategoryPausedFileFor(cat))) {
          continue;
        }
        for (final base in autoManagedByCategory[cat]!.loadAutoManagedBases()) {
          if (_appGridForKey(_gridKey(base), cat) != null) continue;
          waiting.add((cat, base));
        }
      }
      if (waiting.isEmpty) {
        logger.log(
          'autoCheckup[${category.label}] waiting engine: waiting list is empty - stopping.',
        );
        _writeStatus(
          waitingEngineCurrentBase: '',
          waitingEngineIdleReason: 'empty',
        );
        return;
      }
      // Bug fixed 2026-09-12, per the user: a base that keeps failing to
      // open (PONSUSDT: 33+ failed attempts over 15+ hours) never leaves
      // `waiting` (it never gets a grid), so this loop kept retrying it
      // every ~35s indefinitely - burning real Pionex calls and starving
      // every other waiting base behind it. Throttled to a per-base
      // cooldown ([_waitingEngineRetryCooldown]) instead of hammering it
      // every single loop iteration - see that constant's doc for why a
      // short cooldown, not a per-cycle gate (this replaced an earlier,
      // over-corrected same-day version of this exact fix that left the
      // chart sitting fully idle for whatever remained of a 3-minute
      // cycle once every waiting base had used its one attempt).
      final now = DateTime.now();
      final retryable = waiting.where((w) {
        final triedKey = _waitingEngineTriedKey(w.$1, w.$2);
        final last = _waitingEngineLastAttemptAt[triedKey];
        if (last == null) return true;
        if (now.difference(last) < _waitingEngineRetryCooldown) return false;
        // Already checked at least once this candle - skip the real
        // chart re-check entirely (no CDP access, no 6s confirmation
        // delay) until its own category's candle has genuinely moved on.
        // See `_alreadyCheckedThisCandle`'s doc for the live incident
        // this fixes (1H bases retried every ~90s for a full hour, doing
        // nothing but re-confirming the same "nothing newer yet" result
        // every time, starving every other category of chart time).
        return !_alreadyCheckedThisCandle(w.$1, triedKey);
      }).toList();
      // Per the user (2026-09-12): "if in any waiting cycle, pair is
      // having trouble, then in next cycle it will become the last one
      // in list for checkup." A base with no entry in
      // [_waitingEngineLastAttemptAt] has never been attempted yet (or
      // just succeeded and left `waiting` entirely) - genuinely fresh, no
      // sign of trouble. A base that DOES have an entry has failed at
      // least once already (success removes it from `waiting`, so a
      // still-present entry can only mean a past attempt didn't stick) -
      // sorted after every fresh base so a persistently-failing pair
      // (XRPUSDT, confirmed live - 100+ attempts, all rejected the same
      // way) never keeps a genuinely new/healthier waiting base waiting
      // behind it. Stable sort - only reorders by "has trouble or not",
      // never re-orders two bases within the same group relative to each
      // other.
      retryable.sort((a, b) {
        final aTried =
            _waitingEngineLastAttemptAt[_waitingEngineTriedKey(a.$1, a.$2)] !=
            null;
        final bTried =
            _waitingEngineLastAttemptAt[_waitingEngineTriedKey(b.$1, b.$2)] !=
            null;
        if (aTried == bTried) return 0;
        return aTried ? 1 : -1;
      });
      if (retryable.isEmpty) {
        if (_autoCheckupCancelledForCheckup ||
            _autoCheckupCancelledForPairAction ||
            _forceStopActive()) {
          logger.log(
            'autoCheckup[${category.label}] waiting engine: chart needed elsewhere - stopping, resumes normally via the usual handoff.',
          );
          _writeStatus(
            waitingEngineCurrentBase: '',
            waitingEngineIdleReason: 'chart_busy',
          );
          return;
        }
        // Every waiting base is on cooldown right now, but the list isn't
        // genuinely empty - a short, responsive sleep (not a return) so
        // this loop stays resident and picks a base back up the moment
        // its own cooldown elapses, instead of sitting idle until the
        // next full 3m auto-checkup pass gets around to re-invoking this
        // function. Chart-needed-elsewhere is re-checked every time this
        // fires, so Check Now/a pair action still preempts promptly.
        _writeStatus(
          waitingEngineCurrentBase: '',
          waitingEngineIdleReason: 'cooldown',
        );
        await Future<void>.delayed(_waitingEngineIdleSleep);
        continue;
      }
      logger.log(
        'autoCheckup[${category.label}] waiting engine: ${retryable.length} waiting base(s) - retrying now.',
      );
      for (final (cat, base) in retryable) {
        if (_autoCheckupCancelledForCheckup ||
            _autoCheckupCancelledForPairAction ||
            _forceStopActive()) {
          logger.log(
            'autoCheckup[${category.label}] waiting engine: chart needed elsewhere - stopping, resumes normally via the usual handoff.',
          );
          _writeStatus(
            waitingEngineCurrentBase: '',
            waitingEngineIdleReason: 'chart_busy',
          );
          return;
        }
        if (storage.fileExists(storage.autoCategoryPausedFileFor(cat))) {
          continue;
        }
        if (_appGridForKey(_gridKey(base), cat) != null) continue;
        final symbol = '${base}USDT'.toUpperCase();
        // Backs the "waiting" status line the user asked for (2026-09-11):
        // "add status below waiting to show user what is going on now once
        // waiting engine is running" - names exactly which base/category
        // combination is being retried right now, cleared at every return
        // point above/below so a finished/interrupted pass never leaves a
        // stale name on screen.
        _writeStatus(
          waitingEngineCurrentBase: '$symbol/${cat.label}',
          waitingEngineIdleReason: '',
        );
        _recordCycleMarker(base, cat);
        // Marked BEFORE attempting, not after, so a thrown exception still
        // starts this base's cooldown - the whole point is to stop
        // hammering a base that keeps failing, not just one that keeps
        // failing cleanly.
        _waitingEngineLastAttemptAt[_waitingEngineTriedKey(cat, base)] =
            DateTime.now();
        final waitingEntryKey = '${_gridKey(base)}|${cat.wireValue}';
        Worm10Event? confirmedEvent;
        try {
          confirmedEvent = await _confirmedWorm10Event(
            waitingEntryKey,
            symbol,
            cat,
            immediate: _worm10StartupChecked.add(waitingEntryKey),
          );
        } catch (e) {
          logger.log(
            'autoCheckup[${category.label}] waiting engine[${cat.label}] CHECKUP $symbol error: $e',
          );
          continue;
        }
        try {
          await _manageGridPair(
            GridPairConfig(
              symbol: symbol,
              investment: pairInvestments.investmentOf(symbol),
            ),
            confirmedEvent,
            checkNowTriggered: false,
            createBlocked: false,
            category: cat,
          );
        } catch (e) {
          logger.log(
            'autoCheckup[${category.label}] waiting engine[${cat.label}] manageGridPair($symbol) error: $e',
          );
        }
        // Per the user (2026-09-12): "if the waiting pair failed to
        // start after 5 waiting cycles, app will terminate this auto
        // trade before relaunching again" - see
        // [_waitingEngineFailCount]'s doc for exactly what counts as a
        // real failure vs. a benign skip.
        //
        // Bug fixed same day, live (confirmed: POLUSDT logged "confirmed
        // RUNNING - launched OK" immediately before being counted as a
        // FAILURE): `_appGridForKey` reads `_activeGridsById`, which this
        // loop only refreshes once per OUTER iteration
        // (`_refreshActiveGrids`, top of the while-loop) - a base that
        // opens successfully mid-pass still reads as "no grid yet" for
        // the rest of that same pass, since nothing here re-fetches the
        // live list per base. `_openEntryByPair` is the right signal
        // instead - `_manageGridPair`'s success branch sets it
        // synchronously the moment `createFuturesGrid` is accepted,
        // before it ever calls `_waitForGridRunning`, so it's never
        // stale within the same pass.
        final triedKey = _waitingEngineTriedKey(cat, base);
        final entryKey = '${_gridKey(base)}|${cat.wireValue}';
        if (_openEntryByPair.containsKey(entryKey)) {
          _waitingEngineFailCount.remove(triedKey);
        } else if (_lastCreateSkipReason == null) {
          final fails = (_waitingEngineFailCount[triedKey] ?? 0) + 1;
          if (fails >= _waitingEngineMaxFailuresBeforeTerminate) {
            _waitingEngineFailCount.remove(triedKey);
            _waitingEngineLastAttemptAt.remove(triedKey);
            retired.addRetiredBases([(base: base, category: cat)]);
            logger.log(
              'autoCheckup[${category.label}] waiting engine[${cat.label}]: '
              '$symbol failed to open $fails consecutive times - terminating '
              'its auto trade instead of relaunching again. It can still be '
              'started manually from the Next Trade table.',
            );
          } else {
            _waitingEngineFailCount[triedKey] = fails;
            logger.log(
              'autoCheckup[${category.label}] waiting engine[${cat.label}]: '
              '$symbol failed to open (strike $fails/$_waitingEngineMaxFailuresBeforeTerminate).',
            );
          }
        }
      }
    }
  }

  Future<void> _runCycle() async {
    // Auto off works like tradingMT5's (2026-11-07, per the user: "match
    // MT5"): the whole decision cycle is skipped - no chart reads, no opens,
    // no closes. Protection of bots already running (TP/SL ratchet, Stop
    // Loss Lock) runs on its own timers and keeps going.
    // An explicit Check Now still runs its scan with Auto off (found live
    // 2026-11-07: v1.0.5's early return made Check Now do nothing) - with
    // `tradingPaused` threaded into _manageGridPair, it reports only and
    // opens/closes nothing.
    final tradingPaused = _forceStopActive();
    final checkNowPending = storage.fileExists(storage.checknowFile);
    // The Check Now table is filled only by a Check Now press (per the user,
    // 2026-11-07: Power must not run any checkup on it) - no hourly
    // automatic sweep. A sweep paused mid-way for a pair action still
    // resumes.
    if (!checkNowPending && _checkupResumePairs == null) {
      _writeStatus(message: '', busy: false);
      return;
    }
    // Consume the request now, not after the 20s reference read: every 5s
    // tick that still saw the file restarted the sweep (found live).
    if (checkNowPending) storage.deleteFileIfExists(storage.checknowFile);
    if (tradingPaused && !checkNowPending && _checkupResumePairs == null) {
      if (!_forceStopLogged) {
        logger.log('Auto paused - no reads, no opens, no closes until Auto is on.');
        _forceStopLogged = true;
      }
      _writeStatus(message: 'Auto paused', busy: false);
      return;
    } else if (tradingPaused) {
      logger.log('Check Now with Auto off - scanning and reporting only, no opens or closes.');
    } else if (_forceStopLogged) {
      _forceStopLogged = false;
      logger.log('Auto on - resuming normal operation.');
    }

    _writeStatus(message: 'Checking TradingView connection...', busy: true);
    _cdp = await _connect();
    final tvHealthy = _cdp != null;
    if (!tvHealthy) {
      if (_prevTvHealthy)
        logger.log(
          'TV/CDP DOWN: TradingView connection lost - retrying on next poll',
        );
      _prevTvHealthy = false;
      return;
    }
    if (!_prevTvHealthy) {
      logger.log(
        'TV/CDP RECOVERED: TradingView connection restored - will run immediate full checkup',
      );
      _healthRecoveryPending = true;
      _prevTvHealthy = true;
    }

    _writeStatus(message: 'Syncing bot memory with Pionex...', busy: true);
    await _refreshActiveGrids();

    final redList = await _readRedList(_cdp!);
    final configBySymbol = {for (final p in config.gridPairs) p.symbol: p};

    final refSymbol =
        _pickReferenceSymbol(redList) ??
        (config.gridPairs.isNotEmpty ? config.gridPairs.first.symbol : null);
    final checkNowTriggered = checkNowPending;
    // Bug fixed 2026-09-11, per the user ("why is syncing bot memory
    // taking so long - check log and power toggle status"): a sweep
    // paused mid-pair for an Auto category (_checkupResumePairs set, see
    // the per-pair loop below) used to still be subject to THIS candle
    // gate on its very next tick. Since barely any time has passed, the
    // gate almost always finds the reference candle unchanged and
    // returns early - before ever reaching the line that clears
    // _checkupResumePairs - so the resume state never got consumed OR
    // cleared. Every following 5s tick then saw _checkupResumePairs still
    // non-null, ran this whole function again, and hit the exact same
    // early return - an invisible infinite loop that could never
    // actually resume, visible only as the status flapping between
    // "Syncing bot memory with Pionex..." and "Paused, waiting to
    // resume..." forever. The candle gate is only meant to decide whether
    // to START a fresh sweep - a pending resume is already-started work,
    // so it must bypass the gate the same way an explicit Check Now does.
    final resumingPending = _checkupResumePairs != null;
    if (refSymbol != null) {
      int? refBarTime;
      try {
        // Clarified 2026-09-10 (per the user, after a live false alarm):
        // this reads $refSymbol's 1H chart purely as a wall-clock reference
        // ("has an hour passed yet") to decide whether the SEPARATE full
        // Red-list checkup cycle (Check Now/Start's own sweep) should run
        // again - it has nothing to do with $refSymbol's own trading
        // decision or its OWN category's auto-management, which runs
        // entirely independently (see autoCheckup[3m]/[1H]/[1D] and their
        // own per-category candle gates). Without this line, the very next
        // log entry ("CHECKUP $refSymbol 60: BUY=.. SELL=..", emitted by
        // _checkBuySellOnPair below) looked indistinguishable from a real
        // 1H signal check on a pair whose actual running bot is on a
        // completely different category (e.g. 1m) - confirmed live: the
        // user saw "CHECKUP DOGEUSDT 60" while DOGEUSDT's own bot is 1m and
        // reasonably read it as the app checking the wrong interval.
        logger.log(
          'CANDLE GATE: using $refSymbol\'s 1H chart as a reference clock '
          'only (not a signal check for $refSymbol\'s own trading/category) '
          '- picked because it is currently first on the Red List.',
        );
        refBarTime = (await _readWorm10Candidate(refSymbol)).latestBarTime;
      } catch (e) {
        logger.log('CANDLE GATE $refSymbol read error: $e');
      }
      final forceNow =
          _healthRecoveryPending || checkNowTriggered || resumingPending;
      if (checkNowTriggered) {
        storage.deleteFileIfExists(storage.checknowFile);
        logger.log(
          'CHECKNOW TRIGGER: running immediate full Red-list checkup regardless of candle',
        );
      }
      if (refBarTime == null) {
        logger.log(
          'CANDLE GATE: could not read reference 1H bar time on $refSymbol - skipping cycle',
        );
        // Deliberate fix vs. the original: its own log line here claimed
        // "skipping cycle" but the original code fell through and ran the
        // full checkup anyway. This return makes the behavior match the
        // message it logs.
        return;
      } else if (forceNow) {
        _healthRecoveryPending = false;
        _lastHourlyCandleTs = refBarTime;
        logger.log(
          'CANDLE GATE: subsystem RECOVERED / checknow - running immediate full checkup regardless of candle (bar $refBarTime)',
        );
      } else if (_lastHourlyCandleTs != null &&
          refBarTime == _lastHourlyCandleTs) {
        logger.log(
          'CANDLE GATE: 1H candle open $refBarTime unchanged on $refSymbol - sleeping until the next hourly candle is created',
        );
        return;
      } else {
        _lastHourlyCandleTs = refBarTime;
        logger.log(
          'CANDLE GATE: new 1H candle detected on $refSymbol (open time $refBarTime) - running Red-list checkup',
        );
      }
    } else if (_healthRecoveryPending || checkNowTriggered || resumingPending) {
      _healthRecoveryPending = false;
      logger.log(
        'CANDLE GATE: immediate trigger (recovery or checknow) with no reference symbol - running full checkup',
      );
    }

    // Check Now reads the pairs the table is showing, in its sort order
    // (2026-11-07, per the user). Fallbacks: the trending list, then the Red
    // list.
    final table = _readCheckNowTablePairs();
    if (table != null && table.round != _checkNowRound) {
      _checkNowRound = table.round;
      _checkedInRound.clear();
    }
    final trending = table == null ? await _trendingUniverse() : null;
    if (table == null && trending == null) {
      logger.log('TRENDING: Pionex tickers unavailable - using the Red list.');
    }
    final pairUniverse =
        table?.symbols ??
        trending ??
        (redList.isNotEmpty
            ? redList
            : config.gridPairs.map((p) => p.symbol).toList());
    if (table != null) {
      logger.log(
        'CHECK NOW: ${table.symbols.length} pair(s) from the table (round '
        '${table.round}), ${_checkedInRound.length} already read this round.',
      );
    }

    Set<String>? pendingSelection;
    final pendingRaw = storage.readJsonArray(storage.pendingCreateFile);
    if (pendingRaw != null) {
      pendingSelection = pendingRaw
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toSet();
      logger.log(
        'SELECTION: restricting new-grid creation to ${pendingSelection.isEmpty ? '(empty)' : pendingSelection.join(', ')} for this cycle',
      );
      // A pair can already be recorded in _openEntryByPair from an earlier
      // UNSELECTED cycle - in confirm/dry-run mode, "[CONFIRM] Would create
      // grid" still records the in-memory OpenEntry (so a genuinely-opened
      // pair's later opposite-signal close still works), and the dedup
      // check right before that log line (`already.entryTime ==
      // signal.time && already.direction == direction`) can't tell "already
      // simulated as a passive candidate nobody asked for" apart from "a
      // real/confirmed open". The user explicitly selecting this pair now
      // (Start) is a genuine new request, even if the signal hasn't moved
      // since it merely showed up in the report - clear any stale entry so
      // this cycle actually attempts it instead of silently no-op'ing.
      for (final basePerp in pendingSelection) {
        final base = basePerp.replaceAll('.PERP', '').toUpperCase();
        final removed = _openEntryByPair.remove(_gridKey(base));
        if (removed != null) {
          logger.log(
            'SELECTION: $basePerp was already recorded from an earlier '
            'unselected cycle - clearing so this explicit selection is '
            'actually attempted.',
          );
        }
      }
    }
    final persistentRetired = retired.loadRetiredBases();

    // True pause/resume (per the user, 2026-09-04): a checkup interrupted by
    // a Controls-screen pair action picks back up on the pairs it hadn't
    // reached yet, rather than restarting the whole Red-list sweep from
    // scratch. _checkupResumePairs is only ever non-null right after such a
    // pause; consuming it here (and clearing report entries only on a
    // genuinely fresh pass) is what makes that possible.
    //
    // Bug fixed 2026-09-11, per the user ("if a pair is removed from the
    // red list, it needs to be removed from the Next Trade table; if
    // added, it needs to appear"): an explicit Check Now press used to
    // still silently continue a STALE pending resume (queued from an
    // earlier, now-irrelevant interruption) instead of starting fresh -
    // `remaining` came from that old resume list (built from whatever the
    // red list looked like when THAT original pass started), never the
    // just-re-read, current `pairUniverse`. A red-list change made after
    // the original pass started but before the stale resume finally
    // drained could go unreflected in the table indefinitely. Superseded
    // 2026-09-11 by `_reconcileNextTradeWithRedList` below, which
    // reconciles the PERSISTED file directly against the current red list
    // the moment a fresh Check Now starts - an explicit Check Now must
    // always win and start clean.
    final resuming = _checkupResumePairs != null && !checkNowTriggered;
    final remaining = List<String>.from(
      resuming
          ? _checkupResumePairs!
          : pairUniverse.where((s) => !_checkedInRound.contains(s)),
    );
    _checkupResumePairs = null;
    if (resuming) {
      logger.log(
        'mainLoop: resuming the checkup that was paused - ${remaining.length} pair(s) left to check.',
      );
    } else {
      _runningBotsReportEntries.clear();
    }

    // Per the user (2026-09-06): Check Now refreshes which Red List bases
    // Pionex actually lists as tradeable futures right now - never guessed,
    // never stale from a much earlier Power-up. Also covers the rare case
    // where no refresh has ever succeeded yet.
    if (checkNowTriggered || _pionexFuturesBases == null) {
      await _refreshPionexFuturesListing();
    }

    // Per the user (2026-09-11): "once check now occures... check the list
    // of redlist pairs and compare it with current next trade list. if
    // there is extra pairs in red list not in next trade table, it will be
    // added as row with '-'... if there are pairs in next trade are not in
    // red list, they will be removed." Only on a genuinely fresh start
    // (never mid-resume - the table's already reconciled from when THIS
    // sweep started) so the table reflects the red list immediately,
    // instead of the user waiting for the whole sequential sweep to reach
    // (or never reach, if it gets interrupted) each pair.
    if (!resuming) {
      _reconcileNextTradeWithRedList(pairUniverse, persistentRetired);
      unawaited(_reconcilePnlSettlement());
      _checkupCycleMarkerIndex = (_checkupCycleMarkerIndex + 1) % 3;
    }

    perPairLoop:
    while (true) {
      // "Show more" while this scan runs: the table's newly shown pairs join
      // the end of this same round.
      final latest = _readCheckNowTablePairs();
      if (latest != null && latest.round == _checkNowRound) {
        for (final s in latest.symbols) {
          if (!_checkedInRound.contains(s) && !remaining.contains(s)) {
            remaining.add(s);
          }
        }
      }
      if (remaining.isEmpty) break;
      final symbol = remaining.removeAt(0);
      _checkedInRound.add(symbol);
      if (_freshCycleRequested) {
        logger.log(
          'mainLoop: cancelling this cycle at $symbol - a fresh checkup was requested (see _runCycleGuarded).',
        );
        break;
      }
      if (_cycleCancelledForPairAction) {
        remaining.insert(0, symbol);
        _checkupResumePairs = remaining;
        logger.log(
          'mainLoop: pausing this checkup at $symbol (${remaining.length} pair(s) left) - '
          'a pair action needs the chart. Resuming once it is done.',
        );
        break;
      }
      if (_cycleCancelledForAutoCheckup) {
        remaining.insert(0, symbol);
        _checkupResumePairs = remaining;
        logger.log(
          'mainLoop: pausing this checkup at $symbol (${remaining.length} pair(s) left) - '
          'an Auto category\'s candle boundary needs the chart. Resuming once it is done.',
        );
        break;
      }
      // Per the user (2026-09-05): this used to break the whole sweep the
      // instant PAUSE was seen, which is exactly what made Check Now/Start
      // do nothing at all while Auto was off (it always is, right up until
      // Start's own onStart handler clears it) - `tradingPaused` (checked
      // once at the top of _runCycle, threaded into _manageGridPair below)
      // already blocks the actual open/close action, so the scan itself
      // must keep going through every pair regardless.

      // Names the pair currently being examined - backs the small status
      // line under the Power/Auto toggles so the user can see the sweep is
      // actually moving, not just a generic "busy" spinner. Written per-pair
      // rather than once per cycle since a single slow pair (indicator
      // wait-ladder) can otherwise leave a stale name on screen for up to
      // 30s. checkupPairIndex is 1-based ("pair 5 of 27") - pairUniverse.length
      // minus what's left in `remaining` after this pair was just popped off.
      _writeStatus(
        message: 'Checking $symbol...',
        busy: true,
        checkupPairIndex: pairUniverse.length - remaining.length,
        checkupPairTotal: pairUniverse.length,
        checkupCurrentBase: _baseOf(symbol),
      );
      _recordCheckupCycleMarker(_baseOf(symbol));

      // REVERSED 2026-09-12, per the user ("list should match exactly
      // redlist"): the 2026-09-11 version of this comment argued the "-"
      // placeholder should clear the instant a pair is picked up, before
      // it's even checked, so a skip branch that never reaches
      // _mergeLastReportEntry (most commonly: no BUY/SELL signal on any of
      // the 3 categories - see the `signal == null` return near line 4206)
      // wouldn't leave a "stale" "-" row. In practice this made every
      // no-signal red-list pair vanish from the Next Trade table entirely
      // the moment the sweep reached it - no entry (nothing was ever
      // merged), no more "-" (already cleared here first) - breaking the
      // very invariant this table exists to guarantee: every red-list,
      // non-retired, Pionex-listed pair always shows SOME row. A "-" row
      // for a pair with genuinely no signal isn't stale, it's correct -
      // there is nothing more to show until a real signal appears.
      // Pending is now cleared in exactly one place:
      // _mergeLastReportEntry, the instant any of the 3 categories
      // actually produces a real preview - never preemptively here.

      final key = _gridKey(_baseOf(symbol));

      // Per the user (2026-09-06): a Red List pair Pionex doesn't actually
      // offer as futures can never be opened - tagged and skipped entirely,
      // no TradingView chart-switch, no Pionex call, before reading
      // anything else about it. Never skips a pair with an existing grid
      // (app-initiated or manual) even if Pionex's listing changed since it
      // was opened - that grid still needs watching for its close signal.
      if (!_anyGridForKey(key) && _isUnlistedOnPionexFutures(symbol)) {
        // Per the user (2026-09-11): Next Trade updates incrementally now -
        // _reconcileNextTradeWithRedList already wrote a fresh, complete
        // `unlisted` list for the whole red list before this loop even
        // started (Pionex's listing doesn't change mid-sweep), so there's
        // nothing further to persist here.
        logger.log(
          'SKIP $symbol: not listed in Pionex futures - no chart/Pionex call, tagged in the report.',
        );
        continue;
      }

      // Per the user (2026-09-08): Check Now always pulls all 3 engines'
      // data for every pair, not just whichever category the knob currently
      // has selected - so switching the Next Trade knob after the fact
      // shows genuinely-fresh data for that category instead of relabeling
      // the same numbers. The pair's SAVED knob choice is still what
      // decides which category is allowed to actually open a new grid
      // (createBlocked forced true below for the other 2) - starting one is
      // still an explicit, single-category action, only the preview scan
      // now covers all 3.
      final primaryCategory = pairCategories.categoryOf(symbol);
      // REVERSED 2026-09-09 (was "2026-09-08, very urgent" - see git/PRD
      // history): that prior rule allowed a THIRD, no-click path to open a
      // grid - a pair already on a category's own auto-managed list could
      // reopen itself purely from a candle-gated pass with zero explicit
      // action, as a "legitimate recycle/reopen". That carve-out is exactly
      // what caused a live incident (multiple bases sat stale for hours
      // behind an unrelated bug, then all reopened at once, unattended, the
      // moment that bug was fixed - see §20 in the PRD). Mandatory now, no
      // exceptions: a grid is ONLY ever created by an explicit Start click
      // (Next Trade table, or Controls' Check-then-Start) - never by this
      // sweep on its own, auto-managed list or not.
      final basePerp = '${_baseOf(symbol)}.PERP'.toUpperCase();
      final selectionActive = pendingSelection != null;
      final inSelection =
          selectionActive && pendingSelection.contains(basePerp);
      final isRetired =
          _sessionRetiredPairs.contains(symbol) ||
          retired.isRetiredBase(_baseOf(symbol), primaryCategory);
      final hasExistingGrid = _anyGridForKey(key);
      if (isRetired && !inSelection && !hasExistingGrid) {
        logger.log(
          'SKIP $symbol: retired (Last) - no existing grid to check, no new grid trade',
        );
        continue;
      }
      if (isRetired && !inSelection && hasExistingGrid) {
        // Per the user (2026-09-04): a "Last"-marked bot must still get its
        // signal checked every checkup until it actually closes on an
        // opposite signal - it just never reopens. createBlocked below
        // covers the "never reopen" half; the close-check itself
        // (_manageGridPair's opposite-signal branch) doesn't look at
        // createBlocked at all, so it still runs normally here.
        logger.log(
          'CHECKING $symbol: retired (Last) with an existing grid - watching for the close signal, will not reopen.',
        );
      }
      if (isRetired && inSelection) {
        logger.log(
          'RE-ENABLE $symbol: retired but explicitly selected - allowed to run again',
        );
      }

      final pairConfig =
          configBySymbol[symbol] ??
          GridPairConfig(
            symbol: symbol,
            investment: pairInvestments.investmentOf(symbol),
          );

      for (final category in allAutoCategories) {
        // Bug fixed 2026-09-12, per the user ("fix it so it can run more
        // faster" - the 3m auto-checkup was sitting 8+ minutes overdue
        // because Check Now only checked for a higher-priority preemption
        // request BETWEEN whole pairs, never between a single pair's own 3
        // categories. A pair needing several grid-count probe retries per
        // category (TRXUSDT, PUMPUSDT - confirmed live, several minutes
        // each) could hold the chart for its entire multi-category
        // duration even after the higher-priority track had already asked
        // for it back. Same re-queue pattern as the outer per-pair check
        // just above - re-processes this pair's 3 categories fresh on
        // resume (a little redundant work, never incorrect - each
        // category's result gets overwritten with current data anyway).
        if (_cycleCancelledForPairAction || _cycleCancelledForAutoCheckup) {
          remaining.insert(0, symbol);
          _checkupResumePairs = remaining;
          logger.log(
            'mainLoop: pausing this checkup at $symbol[${category.label}] (${remaining.length} pair(s) left) - '
            "${_cycleCancelledForPairAction ? 'a pair action' : "an Auto category's candle boundary"} needs the chart. Resuming once it is done.",
          );
          break perPairLoop;
        }
        // Stop Loss Lock chart-time skip REMOVED 2026-09-25 - see the
        // matching removal + doc comment in `_runAutoCheckup`'s per-base
        // loop for the full reasoning: a tagged base's already-running bot
        // can now be closed by the normal signal rule too, so this read is
        // load-bearing again, not wasted.
        final checkNowEntryKey = '${_gridKey(_baseOf(symbol))}|${category.wireValue}';
        Worm10Event? confirmedEvent;
        try {
          confirmedEvent = await _confirmedWorm10Event(
            checkNowEntryKey,
            symbol,
            category,
            skipCooldown: true,
          );
          if (confirmedEvent != null) {
            brain.recordDecision({
              'type': 'worm10-check',
              'pair': symbol,
              'category': category.wireValue,
              'eventType': confirmedEvent.kind.name,
              'eventTime': confirmedEvent.time,
            });
          }
        } catch (e) {
          logger.log('CHECKUP $symbol[${category.label}] error: $e');
        }

        try {
          await _manageGridPair(
            pairConfig,
            confirmedEvent,
            checkNowTriggered: checkNowTriggered,
            // MANDATORY (2026-09-09, per the user, after a live incident):
            // a grid is only ever created by an explicit Start click - not
            // even a "legitimate recycle/reopen" of a base this category
            // was already auto-managing is allowed to open on its own any
            // more (that carve-out, from 2026-09-08, is exactly what
            // caused the incident: this candle-gated pass runs
            // continuously, with no explicit action, and used to be
            // allowed to reopen a primaryAlreadyAutoManaged base with zero
            // human click involved). Only the pair's own saved/primary
            // category can ever open a NEW grid here at all - the other 2
            // are preview-only for this scan (existing grids under them
            // still get their close-signal checked above regardless, since
            // that branch returns before createBlocked is ever consulted).
            createBlocked: category == primaryCategory
                ? (tradingPaused || !inSelection)
                : true,
            tradingPaused: tradingPaused,
            category: category,
          );
        } catch (e) {
          logger.log('manageGridPair($symbol[${category.label}]) error: $e');
        }
      }
    }

    // Per the user (2026-09-05): a real race here caused a selection to be
    // silently lost. If THIS cycle read the just-written selection but got
    // cancelled (fresh-restart or pause-to-resume) before ever reaching the
    // selected pair, deleting the file now would strand the fresh/resumed
    // cycle with no selection to restrict to - it must survive until a
    // cycle actually runs to genuine completion with it.
    if (pendingSelection != null &&
        storage.fileExists(storage.pendingCreateFile) &&
        !_freshCycleRequested &&
        _checkupResumePairs == null) {
      storage.deleteFileIfExists(storage.pendingCreateFile);
      logger.log(
        'SELECTION: consumed & cleared - engine back to normal checkup next cycle.',
      );
    }

    // Per the user (2026-09-05, revised 2026-09-11): "Next Trade table
    // reset (empty)"/"it should be updated only, not reset". This used to
    // be a bulk overwrite of the WHOLE persisted report from an in-memory
    // accumulator (`_lastReportEntries`/`_unlistedReportEntries`), gated
    // to only run on genuine completion so a cancelled/interrupted pass
    // couldn't clobber everything down to just the few pairs it reached.
    // That entire mechanism is retired now: Next Trade updates
    // incrementally from start to finish instead -
    // `_reconcileNextTradeWithRedList` (add/remove rows the instant a
    // fresh Check Now starts) plus `_mergeLastReportEntry`/
    // `_removeLastReportEntry` (every pair, the moment it actually
    // produces a real preview, by whichever tracker checks it) - so
    // the persisted file is already exactly correct at every point during
    // the sweep, resumed or not. A second, wholesale "replace everything"
    // write at the end can now only ever make it WORSE (racing a
    // concurrent Auto-checkup pass's own direct writes, or a reprice
    // request's, with a stale in-memory snapshot this function alone
    // tracked) - removed entirely, per the user's explicit instruction.
    // Only the separate Auto Bots report (a different file, a different
    // concern, not what was reported broken) still bulk-writes here.
    if (!_freshCycleRequested && _checkupResumePairs == null) {
      storage.writeJson(
        storage.runningBotsReportFile,
        RunningBotsReport(
          generatedAtMs: DateTime.now().millisecondsSinceEpoch,
          entries: List.of(_runningBotsReportEntries),
        ).toJson(),
      );
    }
    // Per the user (2026-09-06): clear the "currently checking" marker the
    // moment this pass stops touching pairs (completed, cancelled, or
    // paused for another track) - a resumed/fresh pass sets it again on
    // its own next pair, so this never leaves a row's loading indicator
    // stuck on once the sweep has actually moved past it.
    _writeStatus(checkupCurrentBase: '');
  }

  /// Per the user (2026-09-05): while Power is on, the app must keep
  /// checking - on its own, continuously, every
  /// [CoreConstants.indicatorVerifyInterval] - that TradingView is actually
  /// connected and both custom indicators are genuinely loaded, not just
  /// once at Power-on or only after something already failed. This is
  /// deliberately read-only (no clicking/removing/reopening here) - it only
  /// flags [_indicatorRetryPending] on a problem, and the existing
  /// connect+verify+repair flow (`_refreshRedListNow`, driven by that same
  /// flag via `_onPairActionTick`) does the actual fix - one repair
  /// pathway, not two. Silent when everything's fine, since logging on
  /// every tick at this frequency would flood the log for no reason.
  /// Per the user (2026-09-10): internet reachability/latency must be
  /// traceable too, distinct from Pionex-specific errors (a dead Pionex
  /// API and a dead internet connection look identical from inside a
  /// try/catch, but need very different fixes). A plain DNS lookup against
  /// Pionex's own domain is enough to answer "is there internet at all"
  /// without adding a second external dependency. Same anti-spam
  /// convention as the rest of this tick: logs only on a state change
  /// (up->down or down->up), never on every steady-state tick.
  Future<void> _checkInternet() async {
    final sw = Stopwatch()..start();
    try {
      final result = await InternetAddress.lookup(
        'pionex.com',
      ).timeout(const Duration(seconds: 5));
      sw.stop();
      final reachable = result.isNotEmpty;
      if (reachable && !_prevInternetHealthy) {
        logger.log(
          'INTERNET RECOVERED: reachable again (DNS lookup ${sw.elapsedMilliseconds}ms).',
        );
        _clearWorm10AuditCache('Internet recovered');
      } else if (!reachable) {
        logger.log(
          'INTERNET: DNS lookup returned no address after ${sw.elapsedMilliseconds}ms.',
        );
      }
      _prevInternetHealthy = reachable;
    } catch (e) {
      sw.stop();
      if (_prevInternetHealthy) {
        logger.log(
          'INTERNET DOWN: DNS lookup failed after ${sw.elapsedMilliseconds}ms - $e',
          level: 'CRITICAL',
        );
      }
      _prevInternetHealthy = false;
    }
  }

  Future<void> _onVerifyTick() async {
    if (_mainLoopRunning ||
        _pairActionRunning ||
        _anyAutoRunning ||
        _stopLossLockRunning) {
      return;
    }
    unawaited(_checkInternet());
    if (_cdp == null || _cdp!.dead) {
      _indicatorRetryPending = true;
      return;
    }
    try {
      await dismissUpgradeDialog(_cdp!);
      final verified = await verifyCustomScripts(_cdp!);
      if (verified.ok) {
        _writeStatus(message: 'Ready', busy: false);
      } else {
        logger.log(
          'HEALTH CHECK: custom scripts not both loaded (MSB=${verified.msbPresent}, RSI=${verified.rsiPresent}) - triggering automatic repair.',
        );
        _indicatorRetryPending = true;
      }
    } catch (e) {
      logger.log('HEALTH CHECK error: $e');
      _indicatorRetryPending = true;
    }
  }

  /// Controls screen's single-pair "check/add/remove" requests (see
  /// [CoreStorage.pairActionFile]) - a lightweight PAUSE/STOP/CHECKNOW-style
  /// file handshake, polled every 2s. Mutually exclusive with the main
  /// per-pair sweep (`_mainLoopRunning`/`_pairActionRunning` guard each
  /// other) since both drive the same single TradingView chart - it can only
  /// show one symbol at a time.
  /// Called once a pair action finishes freeing the chart - resumes
  /// whichever of Checkup/auto-checkup was paused for it, if either was.
  /// Checkup takes priority since it's always the more explicit, more
  /// recent user request when both happen to be waiting.
  void _resumeWhateverWasPausedForPairAction() {
    if (_checkupResumePairs != null) {
      unawaited(_runCycleGuarded());
      return;
    }
    _wakePendingAutoCategory();
  }

  /// Continues a multi-symbol Start request that an Auto category preempted
  /// mid-list (2026-09-11, per the user) - picks up exactly where
  /// [_pairActionStart] left off (remaining symbols, everything already
  /// opened/skipped), same resume-not-restart discipline [_runCycle] uses
  /// for a paused Check Now. Called from the Auto category's own
  /// finally-cleanup once its pass is done - see [_runAutoCheckupGuarded].
  /// If ANOTHER Auto category's boundary comes due before this finishes
  /// too, it pauses again the same way, rather than assuming one
  /// resumption is always enough.
  Future<void> _resumePausedStartAction() async {
    final id = _pairActionResumeId!;
    final symbols = _pairActionResumeSymbols!;
    final openedSoFar = _pairActionResumeOpened!;
    final skippedSoFar = _pairActionResumeSkipped!;
    _pairActionResumeId = null;
    _pairActionResumeSymbols = null;
    _pairActionResumeOpened = null;
    _pairActionResumeSkipped = null;
    logger.log(
      'PAIR ACTION [$id]: resuming the paused start - ${symbols.length} '
      'symbol(s) left to check.',
    );
    _pairActionRunning = true;
    _pairActionIsStart = true;
    Map<String, dynamic> result;
    try {
      result = await _pairActionStart(
        id,
        symbols,
        alreadyOpened: openedSoFar,
        alreadySkipped: skippedSoFar,
      );
    } catch (e) {
      _persistStartInProgress(id, const [], const [], const {});
      result = {'ok': false, 'message': 'Error: $e'};
    }
    _pairActionIsStart = false;
    if (result['paused'] == true) {
      _pairActionResumeId = id;
      _pairActionResumeSymbols = (result['remaining'] as List).cast<String>();
      _pairActionResumeOpened = (result['opened'] as List).cast<String>();
      _pairActionResumeSkipped = (result['skipped'] as Map)
          .cast<String, String>();
      logger.log(
        'PAIR ACTION [$id]: start paused again - another Auto category\'s '
        'candle boundary needs the chart '
        '(${_pairActionResumeSymbols!.length} symbol(s) left). Resuming '
        'once it is done.',
      );
      _pairActionRunning = false;
      return;
    }
    // Genuinely done (not paused again) - nothing left waiting.
    _persistStartInProgress(id, const [], const [], const {});
    storage.writeJson(storage.pairActionResultFile, {
      'id': id,
      'action': 'start',
      'symbols': symbols,
      'completedAtMs': DateTime.now().millisecondsSinceEpoch,
      ...result,
    });
    logger.log(
      'PAIR ACTION [$id]: start -> ok=${result['ok']} ${result['message']}',
    );
    _pairActionRunning = false;
    // The ORIGINAL Start may itself have preempted a Check Now sweep
    // before this Auto category ever got involved - that resume is still
    // owed once this Start is genuinely, finally done.
    _resumeWhateverWasPausedForPairAction();
  }

  Future<void> _onPairActionTick() async {
    // Reprice requests (investment edited mid-sweep) are chart-free - see
    // _repriceRunning's doc comment - so they're peeked for and dispatched
    // BEFORE any of the chart-ownership gates below, never waiting behind
    // Check Now/Auto-checkup/a chart-bound pair action. Only actually
    // consumes pairActionFile when it's genuinely a 'reprice' request -
    // anything else falls through to the normal gated dispatch below,
    // completely unaffected.
    if (!_repriceRunning) {
      final peek = storage.readJsonObject(storage.pairActionFile);
      if (peek != null && '${peek['action']}' == 'reprice') {
        storage.deleteFileIfExists(storage.pairActionFile);
        _repriceRunning = true;
        unawaited(
          _handleRepriceRequest(
            peek,
          ).whenComplete(() => _repriceRunning = false),
        );
        return;
      }
    }
    // A paused Start (waiting on an Auto category, see
    // _pairActionResumeSymbols) must not be raced by a brand-new pair
    // action picking up the chart first - the Auto category's own
    // finally-cleanup is what resumes it (_resumePausedStartAction).
    if (_mainLoopRunning ||
        _pairActionRunning ||
        _stopLossLockRunning ||
        _pairActionResumeSymbols != null) {
      return;
    }
    if (_anyAutoRunning) {
      // Auto-checkup also owns the single shared chart - pause it the same
      // way a running checkup gets paused, rather than letting this tick
      // navigate the chart out from under it.
      final hasWork =
          storage.fileExists(storage.refreshRedListFile) ||
          storage.fileExists(storage.pairActionFile) ||
          _fillQueue.isNotEmpty ||
          _indicatorRetryPending;
      if (hasWork) {
        final running = _runningAutoCategory;
        _autoCheckupCancelledForPairAction = true;
        if (running != null) _autoPendingCategories.add(running);
        logger.log(
          'pairAction: a request is waiting for the chart - pausing auto-checkup${running != null ? '[${running.label}]' : ''} so it can run now.',
        );
      }
      return;
    }
    // Checked first, and deliberately NOT gated on `_cdp != null` like the
    // rest of this tick below - this is exactly what establishes _cdp when
    // it's still null (e.g. Power ON while Auto/the main loop, which
    // normally connects, is still off). _indicatorRetryPending (set by
    // _refreshRedListNow itself whenever indicators still aren't both
    // confirmed loaded) keeps this firing on every tick with no manual
    // Check Now/Power-cycle needed - per the user (2026-09-05): the app
    // must keep automatically checking on its own, not wait to be told.
    if (storage.fileExists(storage.refreshRedListFile) ||
        _indicatorRetryPending) {
      storage.deleteFileIfExists(storage.refreshRedListFile);
      _pairActionRunning = true;
      try {
        await _refreshRedListNow();
      } finally {
        _pairActionRunning = false;
        _resumeWhateverWasPausedForPairAction();
      }
      return;
    }
    if (_cdp == null) return;
    final req = storage.readJsonObject(storage.pairActionFile);
    if (req == null) {
      if (_fillQueue.isNotEmpty) {
        await _fillNextQueued();
      } else if (_favoriteDue()) {
        await _runFavoriteStep();
      }
      return;
    }
    storage.deleteFileIfExists(storage.pairActionFile);
    _pairActionRunning = true;
    try {
      // Watchdog (2026-09-27, per the user: "why i am need to push you to
      // check this ... why app is not having self healing system?" -
      // confirmed live, real-money: a DOGEUSDT Ignite hung for 7+ minutes
      // with zero progress, holding `_pairActionRunning` forever since the
      // `finally` below never runs while the awaited Future itself never
      // completes - every later PAIR ACTION request (two ETHUSDT Ignites)
      // queued silently behind it, with nothing in the app able to notice
      // or recover on its own; needed a manual engine restart). The hang
      // wasn't a plain `cdp.send`/`evaluate()` - those already carry their
      // own 60s `cdpRequestTimeout` internally, and this ran for well over
      // that - so it was stuck in some other unbounded step of the action
      // itself. Rather than chase every individual call site for its own
      // timeout, this wraps the ENTIRE pair action as one last line of
      // defense: any future hang, wherever it originates, self-clears
      // after 120s instead of requiring a human (or me) to notice and
      // restart the engine. `_cdp` is deliberately dropped on timeout too
      // - whatever left this hung very likely left the connection/chart in
      // a broken state, and reusing it as-is risks the exact same hang on
      // the very next action; a full fresh reconnect is cheap and safe.
      await _processPairAction(req).timeout(
        const Duration(seconds: 120),
        onTimeout: () {
          final action = '${req['action']}';
          final target = '${req['symbol'] ?? req['symbols'] ?? ''}';
          logger.log(
            'PAIR ACTION WATCHDOG: $action $target did not complete within '
            '120s - forcibly releasing the chart lock so the app keeps '
            'working instead of staying stuck. Forcing a fresh CDP '
            'reconnect before the next action.',
            level: 'CRITICAL',
          );
          _cdp?.close();
          _cdp = null;
          storage.writeJson(storage.pairActionResultFile, {
            'id': '${req['id']}',
            'action': action,
            'symbol': target,
            'completedAtMs': DateTime.now().millisecondsSinceEpoch,
            'ok': false,
            'message': 'Timed out after 120s with no progress - try again.',
          });
        },
      );
    } finally {
      _pairActionRunning = false;
      _resumeWhateverWasPausedForPairAction();
    }
  }

  /// One fill-now attempt for the next pair Start put in Waiting. Skipped if
  /// the pair left Waiting meanwhile (removed, or already running). If it
  /// can't fill, the pair simply stays in Waiting.
  Future<void> _fillNextQueued() async {
    final symbol = _fillQueue.removeAt(0);
    final base = _baseOf(symbol);
    final category = pairCategories.categoryOf(symbol);
    final managed =
        autoManagedByCategory[category]?.isAutoManaged(base) ?? false;
    if (!managed || _appGridForKey(_gridKey(base), category) != null) {
      logger.log('FILL NOW $symbol: skipped - no longer in Waiting.');
      return;
    }
    _pairActionRunning = true;
    try {
      final fill = await _pairActionIgnite(symbol).timeout(
        const Duration(seconds: 120),
        onTimeout: () {
          _cdp?.close();
          _cdp = null;
          return {'ok': false, 'message': 'timed out after 120s'};
        },
      );
      logger.log(
        fill['ok'] == true
            ? 'FILL NOW $symbol: filled. ${fill['message'] ?? ''}'
            : 'FILL NOW $symbol: not filled, stays in Waiting - ${fill['message']}',
      );
    } catch (e) {
      logger.log('FILL NOW $symbol: error, stays in Waiting - $e');
    } finally {
      _pairActionRunning = false;
      _resumeWhateverWasPausedForPairAction();
    }
  }

  /// Favorite trades (2026-11-11, per the user - rules in
  /// `favorite_trades_store.dart`). Candidates waiting to be checked, one per
  /// pair-action tick, so the chart is never held for long.
  final List<({String symbol, bool short})> _favoriteQueue = [];
  DateTime? _favoriteNoMoneyLoggedAt;

  bool _favoriteDue() =>
      !_forceStopActive() &&
      (_favoriteQueue.isNotEmpty || favoriteTrades.isDue(DateTime.now()));

  /// Free for new trades, computed the same way the dashboard shows it:
  /// Pionex's free USDT minus Waiting bookings minus booked SLL top-ups.
  Future<double> _freeForNewTradesUsdt() async {
    final free = (await pionex.getBalance('USDT')).free;
    var booked = stopLossLockState.totalOwed;
    final running = <String>{};
    for (final g in _activeGridsById.values) {
      if (!g.appInitiated) continue;
      final cat = botCategories.categoryOf(g.buOrderId) ?? AutoCategory.oneHour;
      final bare = g.base
          .toUpperCase()
          .replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '');
      running.add('$bare|${cat.wireValue}');
    }
    for (final cat in allAutoCategories) {
      for (final base in autoManagedByCategory[cat]!.loadAutoManagedBases()) {
        if (running.contains('$base|${cat.wireValue}')) continue;
        if (retired.isRetiredBase(base, cat)) continue;
        booked +=
            _nextInvestmentByPair['${_gridKey(base)}|${cat.wireValue}'] ??
            pairInvestments.investmentOf('${base}USDT');
      }
    }
    return free - booked;
  }

  Future<void> _runFavoriteStep() async {
    if (_favoriteQueue.isEmpty) {
      await _buildFavoriteQueue(DateTime.now());
      return;
    }
    final c = _favoriteQueue.removeAt(0);
    _pairActionRunning = true;
    try {
      final opened = await _tryFavorite(c.symbol, short: c.short).timeout(
        const Duration(seconds: 180),
        onTimeout: () {
          logger.log(
            'FAVORITE ${c.symbol}: check did not finish in 180s - skipped, '
            'forcing a fresh TradingView connection.',
            level: 'ERROR',
          );
          _cdp?.close();
          _cdp = null;
          return false;
        },
      );
      if (opened) {
        favoriteTrades.recordOpened(
          _baseOf(c.symbol),
          short: c.short,
          now: DateTime.now(),
        );
        _favoriteQueue.clear();
        logger.log(
          'FAVORITE: ${favoriteTrades.openedToday(DateTime.now())}/5 today - '
          'next check at ${favoriteTrades.nextCheckAt?.toUtc().toIso8601String()} UTC.',
        );
      } else if (_favoriteQueue.isEmpty) {
        favoriteTrades.recordNothing(DateTime.now());
        logger.log(
          'FAVORITE: no candidate matched - next check at '
          '${favoriteTrades.nextCheckAt?.toUtc().toIso8601String()} UTC.',
        );
      }
    } catch (e) {
      logger.log('FAVORITE ${c.symbol}: error - $e', level: 'ERROR');
      if (_favoriteQueue.isEmpty) favoriteTrades.recordNothing(DateTime.now());
    } finally {
      _pairActionRunning = false;
      _resumeWhateverWasPausedForPairAction();
    }
  }

  Future<void> _buildFavoriteQueue(DateTime now) async {
    await _refreshActiveGrids();
    final free = await _freeForNewTradesUsdt();
    if (free < favoriteInvestmentUsdt) {
      final last = _favoriteNoMoneyLoggedAt;
      if (last == null || now.difference(last) > const Duration(hours: 1)) {
        _favoriteNoMoneyLoggedAt = now;
        logger.log(
          'FAVORITE: \$${free.toStringAsFixed(2)} free for new trades - needs '
          '\$${favoriteInvestmentUsdt.toStringAsFixed(0)}, nothing done.',
        );
      }
      favoriteTrades.recordNothing(now);
      return;
    }
    final momentum = PriceMomentum()
      ..loadJson(storage.readJsonObject(storage.priceMomentumFile), now);
    final lastAt = momentum.lastAt;
    if (lastAt == null ||
        now.difference(lastAt) > const Duration(minutes: 3) ||
        momentum.span < const Duration(minutes: 50)) {
      logger.log(
        'FAVORITE: the star lists need about an hour of fresh readings '
        '(have ${momentum.span.inMinutes} min) - trying again next candle.',
      );
      favoriteTrades.recordNothing(now);
      return;
    }
    final scores = {
      for (final e in momentum.readings().entries)
        e.key: e.value.now - e.value.then,
    };
    final exclude = <String>{...favoriteTrades.basesToday(now)};
    for (final g in _activeGridsById.values) {
      if (!g.appInitiated) continue;
      exclude.add(
        g.base.toUpperCase().replaceAll(RegExp(r'\.PERP$', caseSensitive: false), ''),
      );
    }
    for (final cat in allAutoCategories) {
      exclude.addAll(autoManagedByCategory[cat]!.loadAutoManagedBases());
    }
    final candidates = favoriteCandidates(
      scores,
      wantShorts: favoriteTrades.canShort(now),
      wantLongs: favoriteTrades.canLong(now),
      exclude: exclude,
    );
    if (candidates.isEmpty) {
      favoriteTrades.recordNothing(now);
      return;
    }
    _favoriteQueue.addAll(candidates);
    logger.log(
      'FAVORITE: checking ${candidates.length} pair(s): '
      '${candidates.map((c) => '${c.symbol}(${c.short ? 'short' : 'long'})').join(', ')}',
    );
  }

  /// Opens [symbol] as a favorite trade if its hybrid decision is the right
  /// OPEN1 (short: HH + Supertrend buy; long: LL + Supertrend sell) and RSI
  /// at that candle is yellow (short) / blue (long) - green and purple do
  /// not count here. $10, then marked Last.
  Future<bool> _tryFavorite(String symbol, {required bool short}) async {
    const category = AutoCategory.oneHour;
    final base = _baseOf(symbol);
    final entryKey = '${_gridKey(base)}|${category.wireValue}';
    // The hybrid decision exactly as Auto uses it (per the user: no change),
    // including its wait for the signal's candle plus one more candle.
    final event = await _confirmedWorm10Event(entryKey, symbol, category);
    final want = short ? Worm10EventKind.sellOpen1 : Worm10EventKind.buyOpen1;
    if (event == null || event.kind != want) {
      logger.log(
        'FAVORITE $symbol: no ${short ? 'HH short' : 'LL long'} signal '
        '(${event == null ? 'none confirmed' : event.kind.name}) - skipped.',
      );
      return false;
    }
    final check = await _readWorm10Chart(symbol, category.signalResolution);
    RsiZone? zone;
    for (final z in check?.rsiZones ?? const <RsiZoneSample>[]) {
      if (z.time == event.time) zone = z.zone;
    }
    final wantZone = short ? RsiZone.yellow : RsiZone.blue;
    if (zone != wantZone) {
      logger.log(
        'FAVORITE $symbol: ${event.kind.name}@${event.time} but RSI was '
        '${zone?.name ?? 'unknown'} (needs ${wantZone.name}) - skipped.',
      );
      return false;
    }
    final free = await _freeForNewTradesUsdt();
    if (free < favoriteInvestmentUsdt) {
      logger.log(
        'FAVORITE $symbol: only \$${free.toStringAsFixed(2)} free now - skipped.',
      );
      return false;
    }
    if (_nextInvestmentByPair.remove(entryKey) != null) {
      _persistPendingInvestment(base, category, null);
    }
    retired.removeRetiredBases([(base: base, category: category)]);
    autoManagedByCategory[category]!.addBase(base);
    final hadEntryBefore = _openEntryByPair.containsKey(entryKey);
    _lastCreateSkipReason = null;
    await _manageGridPair(
      GridPairConfig(symbol: symbol, investment: favoriteInvestmentUsdt),
      event,
      checkNowTriggered: true,
      createBlocked: false,
      category: category,
      bypassFreshSignalGate: true,
    );
    final opened = !hadEntryBefore && _openEntryByPair.containsKey(entryKey);
    if (!opened) {
      autoManagedByCategory[category]!.removeBase(base);
      logger.log(
        'FAVORITE $symbol: Pionex did not open it'
        '${_lastCreateSkipReason == null ? '' : ' ($_lastCreateSkipReason)'} - skipped.',
      );
      return false;
    }
    // Last: once it closes, for any reason, it never reopens.
    retired.addRetiredBases([(base: base, category: category)]);
    final newId = _openEntryByPair[entryKey]?.buOrderId;
    if (newId != null) favoriteTrades.markFavoriteBot(newId);
    await _refreshActiveGrids();
    logger.log(
      'FAVORITE $symbol: opened ${short ? 'SHORT' : 'LONG'} \$'
      '${favoriteInvestmentUsdt.toStringAsFixed(0)} on ${event.kind.name}@'
      '${event.time} (RSI ${zone!.name}) - marked Last.',
    );
    return true;
  }

  /// Connects to TradingView if needed and re-reads the Red List, writing
  /// it into status.json - read-only, no trading decision, safe to run
  /// regardless of PAUSE. Requested via [CoreStorage.refreshRedListFile].
  Future<void> _refreshRedListNow() async {
    logger.log('REFRESH REDLIST: requested (Power on).');
    final cdp = await _connect();
    if (cdp == null) {
      logger.log(
        'REFRESH REDLIST: could not connect to TradingView - skipped.',
      );
      // _connect() leaves the status stuck on whichever "Connecting..."
      // message it last wrote before failing (it never clears busy itself
      // on a failure path) - without this, the GUI would show "Connecting
      // to chart..." forever after a failed Power-on, looking like a hang
      // that's still in progress when the engine has actually already
      // given up and moved on.
      // Keeps this retrying automatically (see _indicatorRetryPending on
      // the indicator-check branch below) - a failed connection is just as
      // much "not done yet" as unresolved indicators, and must not require
      // a manual Check Now/Power-cycle to try again either.
      _indicatorRetryPending = true;
      _writeStatus(
        message:
            'Could not connect to TradingView - checking again automatically.',
        busy: false,
      );
      return;
    }
    _cdp = cdp;
    // A prior failure (this function's own, or a Checkup cycle's) may have
    // left _prevTvHealthy false via _markTvUnhealthy() - _runCycle() clears
    // it on its own successful reconnect, but Checkup is on-demand only and
    // may not run again for a while, so this path must clear it too or
    // cdp_healthy in status.json (and the Power switch's health light)
    // would keep reporting unhealthy long after the connection and
    // indicators are genuinely fine again.
    if (!_prevTvHealthy) {
      logger.log(
        'TV/CDP RECOVERED: TradingView connection restored (Power on).',
      );
      _prevTvHealthy = true;
    }
    await _readRedList(_cdp!);
    // Per the user: Power ON must check indicators are actually loading,
    // not just that the chart connects and the watchlist reads - reuses
    // the exact same verification the main checkup itself relies on.
    // reportStatus:true - this IS a genuine Power/connectivity milestone,
    // unlike the routine per-pair callers of this same function.
    final indicatorsOk = await _ensureCustomScripts(reportStatus: true);
    // Per the user (2026-09-05): the app must keep automatically checking
    // on its own until both indicators are confirmed loaded - no manual
    // Check Now / Power-cycle should ever be required. Setting this true
    // makes _onPairActionTick call this function again on its very next
    // tick (every 2s), and it keeps doing so - each attempt clearing the
    // flag on success or re-setting it on failure - until it succeeds.
    _indicatorRetryPending = !indicatorsOk;
    // busy: false in both branches - per the user (2026-09-05), the Power
    // switch's light should be solid green once idle/Ready, only blinking
    // while an actual check is in progress, never continuously while
    // merely on (whether healthy or waiting on the next auto-retry tick).
    _writeStatus(
      message: indicatorsOk
          ? 'Ready'
          : 'Red list refreshed, but indicators did not load - checking again automatically.',
      busy: false,
    );
  }

  Future<void> _processPairAction(Map<String, dynamic> req) async {
    final id = '${req['id']}';
    final action = '${req['action']}';
    // Per the user (2026-09-05): Start does an on-spot check of ONLY the
    // selected pair(s), not a full Red-list sweep - it takes a plural
    // `symbols` list rather than the single-symbol shape every other pair
    // action uses, so it's handled as its own branch before the
    // single-symbol dispatch below.
    if (action == 'start') {
      // Per the user (2026-09-05): use the symbol exactly as the Red List
      // named it - no qualifySymbol rebuilding.
      final symbols = ((req['symbols'] as List?) ?? const [])
          .map((s) => '$s')
          .toList();
      logger.log('PAIR ACTION [$id]: start ${symbols.join(', ')} requested.');
      _pairActionIsStart = true;
      Map<String, dynamic> result;
      try {
        result = await _pairActionStart(id, symbols);
      } catch (e) {
        _persistStartInProgress(id, const [], const [], const {});
        result = {'ok': false, 'message': 'Error: $e'};
      }
      _pairActionIsStart = false;
      // Per the user (2026-09-11): an Auto category preempted this Start
      // mid-list - save exactly where it left off (remaining symbols plus
      // everything already opened/skipped) instead of writing an
      // incomplete result. Deliberately returns here with NO write to
      // pairActionResultFile - the GUI's poll loop just keeps waiting, the
      // same as it silently would for a slow-but-uninterrupted Start;
      // _resumePausedStartAction picks this back up once the Auto
      // category that preempted it is done.
      if (result['paused'] == true) {
        _pairActionResumeId = id;
        _pairActionResumeSymbols = (result['remaining'] as List)
            .cast<String>();
        _pairActionResumeOpened = (result['opened'] as List).cast<String>();
        _pairActionResumeSkipped = (result['skipped'] as Map)
            .cast<String, String>();
        logger.log(
          'PAIR ACTION [$id]: start paused - an Auto category\'s candle '
          'boundary needs the chart (${_pairActionResumeSymbols!.length} '
          'symbol(s) left). Resuming once it is done.',
        );
        return;
      }
      // Genuinely done (not paused) - nothing left waiting.
      _persistStartInProgress(id, const [], const [], const {});
      storage.writeJson(storage.pairActionResultFile, {
        'id': id,
        'action': action,
        'symbols': symbols,
        'completedAtMs': DateTime.now().millisecondsSinceEpoch,
        ...result,
      });
      logger.log(
        'PAIR ACTION [$id]: start ${symbols.join(', ')} -> ok=${result['ok']} ${result['message']}',
      );
      return;
    }
    // Per the user (2026-09-06): use exactly what was sent - no
    // qualifySymbol rebuilding, which forced "BINANCE:" onto every
    // symbol regardless of what the caller actually meant.
    final symbol = '${req['symbol']}'.trim().toUpperCase();
    logger.log(
      'PAIR ACTION [$id]: $action $symbol requested from Controls screen.',
    );
    Map<String, dynamic> result;
    try {
      switch (action) {
        case 'check':
          result = await _pairActionCheck(symbol);
        case 'add':
          result = await _pairActionAdd(symbol);
        case 'remove':
          result = await _pairActionRemove(symbol);
        case 'ignite':
          result = await _pairActionIgnite(symbol);
        default:
          result = {'ok': false, 'message': 'Unknown pair action: $action'};
      }
    } catch (e) {
      result = {'ok': false, 'message': 'Error: $e'};
    }
    storage.writeJson(storage.pairActionResultFile, {
      'id': id,
      'action': action,
      'symbol': symbol,
      'completedAtMs': DateTime.now().millisecondsSinceEpoch,
      ...result,
    });
    logger.log(
      'PAIR ACTION [$id]: $action $symbol -> ok=${result['ok']} ${result['message']}',
    );
  }

  /// Handles one 'reprice' request end-to-end (2026-09-11, per the user) -
  /// dispatched from [_onPairActionTick]'s chart-free early branch, never
  /// through the normal gated `_processPairAction` switch, since it needs
  /// none of that machinery (no chart, no pause/resume, no preemption).
  Future<void> _handleRepriceRequest(Map<String, dynamic> req) async {
    final id = '${req['id']}';
    final symbol = '${req['symbol']}'.trim().toUpperCase();
    final category =
        autoCategoryFromWire('${req['category']}') ?? AutoCategory.oneHour;
    logger.log(
      'PAIR ACTION [$id]: reprice $symbol[${category.label}] requested '
      '(investment edited mid-sweep - Pionex-only pull, no signal recheck).',
    );
    Map<String, dynamic> result;
    try {
      result = await _repriceInvestment(symbol, category);
    } catch (e) {
      result = {'ok': false, 'message': 'Error: $e'};
    }
    storage.writeJson(storage.pairActionResultFile, {
      'id': id,
      'action': 'reprice',
      'symbol': symbol,
      'category': category.wireValue,
      'completedAtMs': DateTime.now().millisecondsSinceEpoch,
      ...result,
    });
    logger.log(
      'PAIR ACTION [$id]: reprice $symbol -> ok=${result['ok']} ${result['message']}',
    );
  }

  /// The actual Pionex-only re-pricing (2026-09-11, per the user: "app will
  /// give priority to this pair so values are pulled from pionex" - but per
  /// the user's own clarification, "pulled from pionex" specifically, not a
  /// TradingView signal recheck). Reuses [symbol]/[category]'s EXISTING
  /// range/direction/leverage/TP/SL from the last real preview computed for
  /// it (liquidation math doesn't depend on investment - no need to redo
  /// it) - only [probeMaxGridCount]'s checkFuturesGrid probe re-runs, against
  /// the pair's CURRENT investment amount, to get fresh actualInvestment/
  /// extraMargin/liquidationPrice/gridCount. Never switches the TradingView
  /// chart, never calls [_checkBuySellOnPair] - genuinely independent of the
  /// single shared chart, so it can't collide with (or need to preempt)
  /// Check Now/Auto-checkup/another pair action.
  ///
  /// Per the user (point 7): a base with no existing preview yet (still
  /// showing "-") has nothing to reprice - the GUI is expected not to even
  /// send this request for such a row, but this refuses gracefully too, as
  /// a second line of defense.
  Future<Map<String, dynamic>> _repriceInvestment(
    String symbol,
    AutoCategory category,
  ) async {
    final base = _baseOf(symbol);
    final current = LastReport.fromJson(
      storage.readJsonObject(storage.lastReportFile) ??
          const <String, dynamic>{},
    );
    PreviewGridPair? existing;
    for (final e in current.entries) {
      if (e.base.toUpperCase() == base.toUpperCase() &&
          e.category == category) {
        existing = e;
        break;
      }
    }
    if (existing == null) {
      const msg = 'No existing preview for this pair/category yet - nothing to reprice.';
      logger.log('PAIR ACTION REPRICE $symbol[${category.label}]: $msg');
      return {'ok': false, 'message': msg};
    }
    if (!pionex.available) {
      const msg = 'Pionex is not configured - cannot reprice.';
      return {'ok': false, 'message': msg};
    }
    final investment = pairInvestments.investmentOf(symbol);
    logger.log(
      'PAIR ACTION REPRICE $symbol[${category.label}]: using investment=\$$investment.',
    );
    final futuresBase = _normalizeBase(base);
    var top = existing.top;
    var bottom = existing.bottom;
    var row = (investment / 10).round().clamp(
      config.technique.minGrids,
      config.technique.effectiveMaxGrids,
    );
    double? actualInvestment;
    double? extraMargin;
    double? liquidationPrice;
    try {
      final resolved = await _resolveQuotePrecision(
        futuresBase: futuresBase,
        top: top,
        bottom: bottom,
        direction: existing.direction,
        leverage: existing.maxLeverage,
        investment: investment.toString(),
      );
      if (resolved != null) {
        top = resolved.top;
        bottom = resolved.bottom;
      }
      Map<String, dynamic>? probeResponse;
      row = await probeMaxGridCount(
        minGrids: config.technique.minGrids,
        maxGrids: config.technique.effectiveMaxGrids,
        checkRowValid: (candidate) async {
          try {
            final resp = await pionex.checkFuturesGrid(
              base: futuresBase,
              quote: 'USDT',
              buOrderData: {
                'top': top.toString(),
                'bottom': bottom.toString(),
                'row': candidate,
                'grid_type': 'arithmetic',
                'trend': existing!.direction.wireValue,
                'leverage': existing.maxLeverage,
                'quoteInvestment': investment.toString(),
                'extraMargin': true,
              },
            );
            probeResponse = resp;
            return true;
          } on RateLimitException {
            rethrow;
          } catch (e) {
            logger.log(
              'PAIR ACTION REPRICE $symbol[${category.label}]: row=$candidate rejected by Pionex checkFuturesGrid: $e',
            );
            return false;
          }
        },
      );
      if (probeResponse != null) {
        actualInvestment = double.tryParse(
          '${probeResponse!['estimateInvestment']}',
        );
        extraMargin = double.tryParse(
          '${probeResponse!['estimateExtraMargin']}',
        );
        liquidationPrice = existing.direction == GridDirection.long
            ? double.tryParse('${probeResponse!['estimateLiquidationPriceDown']}')
            : double.tryParse('${probeResponse!['estimateLiquidationPriceUp']}');
        logger.log(
          'PAIR ACTION REPRICE $symbol[${category.label}]: Pionex returned '
          'actualInvestment=$actualInvestment extraMargin=$extraMargin for '
          'requested investment=\$$investment (row=$row).',
        );
      }
    } on RateLimitException {
      logger.log(
        'PAIR ACTION REPRICE $symbol[${category.label}]: rate limited during checkParams probe - keeping the last known values.',
      );
      return {'ok': false, 'message': 'Rate limited by Pionex - try again shortly.'};
    } catch (e) {
      logger.log(
        'PAIR ACTION REPRICE $symbol[${category.label}]: checkParams probe failed ($e).',
      );
      return {'ok': false, 'message': 'Error: $e'};
    }
    final updated = PreviewGridPair(
      symbol: existing.symbol,
      base: existing.base,
      quote: existing.quote,
      direction: existing.direction,
      top: top,
      bottom: bottom,
      stable: existing.stable,
      widenApplied: existing.widenApplied,
      takeProfitPrice: existing.takeProfitPrice,
      stopLossPrice: existing.stopLossPrice,
      maxLeverage: existing.maxLeverage,
      leverage: existing.leverage,
      gridCount: row,
      entryPrice: existing.entryPrice,
      actualInvestment: actualInvestment,
      extraMargin: extraMargin,
      liquidationPrice: liquidationPrice,
      category: category,
    );
    _mergeLastReportEntry(updated);
    return {'ok': true, 'message': 'Repriced $symbol (${category.label}) against Pionex.'};
  }

  /// Item 5 ("Check"): reports whether [symbol] is on the live Red List
  /// right now, then computes the SAME live signal/range/leverage/grid-count
  /// preview `_recordReportPreview` would, once per category (2026-09-08) -
  /// same practice as Check Now: all 3 engines' data is pulled every time,
  /// so switching the Check card's knob afterward shows genuinely-fresh
  /// numbers for that category, not a relabeled copy of whichever one was
  /// selected at Check time. Read-only: never creates or modifies anything,
  /// same guarantee as the dashboard's Last report preview.
  Future<Map<String, dynamic>> _pairActionCheck(String symbol) async {
    // Per the user (2026-09-06): the Controls-screen Check button refreshes
    // the Pionex futures listing too (same as Power-up/Check Now), then -
    // same concept as the full sweep - a pair Pionex doesn't list is tagged
    // and skipped entirely, no TradingView chart read at all. Add/Remove
    // still stays available (checked below via inRedList), only Start is
    // withheld (see controls_screen.dart's pionexListed gate).
    await _refreshPionexFuturesListing();
    final primaryCategory = pairCategories.categoryOf(symbol);
    final inRedList = _redListSymbols.contains(symbol);
    final key = _gridKey(_baseOf(symbol));
    if (!_anyGridForKey(key) && _isUnlistedOnPionexFutures(symbol)) {
      logger.log(
        'PAIR ACTION CHECK $symbol: not listed in Pionex futures - no chart/Pionex read.',
      );
      return {
        'ok': true,
        'inRedList': inRedList,
        'symbolVerified': true,
        'pionexListed': false,
        'message': UnlistedRedListPair.message,
      };
    }
    final byCategory = <String, Map<String, dynamic>>{};
    for (final category in allAutoCategories) {
      byCategory[category.wireValue] = await _computeCategoryCheckPreview(
        symbol,
        category,
      );
    }
    final primary = byCategory[primaryCategory.wireValue]!;
    return {
      'ok': true,
      'inRedList': inRedList,
      'pionexListed': true,
      // The symbol is real if ANY category's chart loaded - a resolution
      // that transiently failed to load shouldn't hide "Add to Red List"
      // when the others confirm the symbol exists.
      'symbolVerified': byCategory.values.any(
        (r) => r['symbolVerified'] == true,
      ),
      'message': primary['message'],
      'preview': primary['preview'],
      'previewByCategory': byCategory,
    };
  }

  /// One category's own share of [_pairActionCheck] - factored out so it
  /// can be called once per category (2026-09-08) instead of only ever for
  /// whichever one the Check card's knob happened to have selected.
  Future<Map<String, dynamic>> _computeCategoryCheckPreview(
    String symbol,
    AutoCategory category,
  ) async {
    final read = await _readWorm10Candidate(
      symbol,
      resolution: category.signalResolution,
    );
    if (read.latestBarTime == null) {
      // This category's chart itself never loaded for this symbol - e.g. it
      // doesn't actually exist on TradingView (a typo, or a concatenated
      // string like "BTCETH").
      const msg =
          'Could not read chart/indicator data right now (may still be loading).';
      logger.log('NO DATA $symbol[${category.label}]: $msg');
      return {'symbolVerified': false, 'message': "$symbol's $msg"};
    }
    // From here on the chart genuinely loaded - the symbol is real and
    // chart-loadable, regardless of whether a full preview can be computed
    // below.
    final event = read.event;
    if (event == null) {
      final msg = 'No Worm10 event on the ${category.label} chart right now.';
      logger.log('NO DATA $symbol[${category.label}]: $msg');
      return {'symbolVerified': true, 'message': "$symbol's $msg"};
    }
    final direction = worm10EventDirection(event.kind) == TradeDirection.long
        ? GridDirection.long
        : GridDirection.short;
    final lines = await _readZigzagLines(
      symbol,
      resolution: category.rangeResolution,
    );
    if (lines == null) {
      final msg =
          'Could not read the ${category.rangeResolution} chart (MSB/OB range) data.';
      logger.log('NO DATA $symbol[${category.label}]: $msg');
      return {'symbolVerified': true, 'message': "$symbol's $msg"};
    }
    final zigzag = detectZigzagRange(
      lines,
      swingCount: config.technique.rangeSwingCount,
    );
    if (zigzag == null || !zigzag.isValid) {
      final msg = 'No valid ${category.rangeResolution} MSB/OB range yet.';
      logger.log('NO DATA $symbol[${category.label}]: $msg');
      return {'symbolVerified': true, 'message': "$symbol's $msg"};
    }
    final maxLev = await _maxLeverageFor(symbol);
    if (maxLev == null) {
      const msg = 'Could not read max leverage from Pionex.';
      logger.log('NO DATA $symbol[${category.label}]: $msg');
      return {'symbolVerified': true, 'message': "$symbol's $msg"};
    }
    // A Worm10Event carries no price (pure indicator-plot derivation) - a
    // live ticker read stands in, same as the real decision path, falling
    // back to the range's own midpoint only if even that is unreachable.
    final entryPricePreview =
        await pionex.getTickerPrice('${_baseOf(symbol)}_USDT_PERP') ??
        (zigzag.top + zigzag.bottom) / 2;
    final lvl = computeLiquidationLevels(
      top: zigzag.top,
      bottom: zigzag.bottom,
      entry: entryPricePreview,
      direction: direction,
    );
    var range = zigzag;
    if (lvl.widenApplied) {
      range = range.copyWith(top: lvl.gridTop, bottom: lvl.gridBottom);
    }

    // Per the user (2026-09-09): the pair's own custom initial investment
    // (Next Trade/Check-card text field), defaulting to $10 - this preview
    // must reflect the SAME amount a real Start would actually use.
    final investment = pairInvestments.investmentOf(symbol);
    // Diagnostic added 2026-09-10 (per the user's "log everything so we can
    // trace it" standing rule): the user reported a fresh Pionex pull
    // sometimes returning actualInvestment/extraMargin computed against the
    // OLD investment amount, not the one just typed. investmentOf() reloads
    // pair-investments.json fresh on every call and setInvestment() writes
    // it synchronously before this ever runs, so no stale-read bug is
    // visible from reading the code alone - this line records exactly what
    // value THIS check actually used, so the next occurrence can be
    // compared against what the user had just typed instead of guessing.
    logger.log('PAIR ACTION CHECK $symbol[${category.label}]: using investment=\$$investment.');
    final base = _baseOf(symbol);
    final futuresBase = _normalizeBase(base);
    var row = (investment / 10).round().clamp(
      config.technique.minGrids,
      config.technique.effectiveMaxGrids,
    );
    double? actualInvestment;
    double? extraMargin;
    double? liquidationPrice;
    if (pionex.available) {
      try {
        // Bug fixed 2026-09-09: this preview used to send the raw,
        // unrounded top/bottom straight to checkFuturesGrid - Pionex
        // rejects any price with more decimals than that pair's own
        // (undiscoverable-except-by-probing) required precision with
        // BOT_INVALID_ARGUMENT "top/bottom not match quote precision".
        // _manageGridPair's real-open path and _recordReportPreview both
        // already resolve this first (see _resolveQuotePrecision); this
        // preview never did, so EVERY category's actual investment/extra
        // margin came back permanently null the instant a user edited the
        // investment or switched the interval (which both route through
        // this function) - looked like "no data" for a pair that, in fact,
        // just needed its price rounded first.
        final resolved = await _resolveQuotePrecision(
          futuresBase: futuresBase,
          top: range.top,
          bottom: range.bottom,
          direction: direction,
          leverage: maxLev,
          investment: investment.toString(),
        );
        if (resolved != null) {
          range = range.copyWith(top: resolved.top, bottom: resolved.bottom);
        }
        Map<String, dynamic>? probeResponse;
        row = await probeMaxGridCount(
          minGrids: config.technique.minGrids,
          maxGrids: config.technique.effectiveMaxGrids,
          checkRowValid: (candidate) async {
            try {
              final resp = await pionex.checkFuturesGrid(
                base: futuresBase,
                quote: 'USDT',
                buOrderData: {
                  'top': range.top.toString(),
                  'bottom': range.bottom.toString(),
                  'row': candidate,
                  'grid_type': 'arithmetic',
                  'trend': direction.wireValue,
                  'leverage': maxLev,
                  'quoteInvestment': investment.toString(),
                  'extraMargin': true,
                },
              );
              probeResponse = resp;
              return true;
            } on RateLimitException {
              rethrow;
            } catch (e) {
              // Bug fixed 2026-09-09: this used to be `catch (_) { return
              // false; }` - completely silent. Pionex genuinely rejecting
              // EVERY candidate row (the common real case: probeMaxGridCount
              // falls back to minGrids and actualInvestment/extraMargin stay
              // null forever) looked identical in the log to "nothing was
              // ever attempted" - impossible to tell an actual Pionex
              // rejection reason (investment too small for this range/
              // leverage, a real API error, ...) apart from a code bug.
              logger.log(
                'PAIR ACTION CHECK $symbol[${category.label}]: row=$candidate rejected by Pionex checkFuturesGrid: $e',
              );
              return false;
            }
          },
        );
        if (probeResponse != null) {
          actualInvestment = double.tryParse(
            '${probeResponse!['estimateInvestment']}',
          );
          extraMargin = double.tryParse(
            '${probeResponse!['estimateExtraMargin']}',
          );
          liquidationPrice = direction == GridDirection.long
              ? double.tryParse(
                  '${probeResponse!['estimateLiquidationPriceDown']}',
                )
              : double.tryParse(
                  '${probeResponse!['estimateLiquidationPriceUp']}',
                );
          logger.log(
            'PAIR ACTION CHECK $symbol[${category.label}]: Pionex returned '
            'actualInvestment=$actualInvestment extraMargin=$extraMargin for '
            'requested investment=\$$investment (row=$row).',
          );
        }
      } on RateLimitException {
        logger.log(
          'PAIR ACTION CHECK $symbol[${category.label}]: rate limited during checkParams probe - preview shows a rough estimate.',
        );
      } catch (e) {
        logger.log(
          'PAIR ACTION CHECK $symbol[${category.label}]: checkParams probe failed ($e) - rough estimate.',
        );
      }
    }

    final preview = PreviewGridPair(
      symbol: symbol,
      base: base,
      quote: 'USDT',
      direction: direction,
      top: range.top,
      bottom: range.bottom,
      stable: lvl.stable,
      widenApplied: lvl.widenApplied,
      takeProfitPrice: lvl.takeProfitPrice,
      stopLossPrice: lvl.stopLossPrice,
      maxLeverage: maxLev,
      leverage: maxLev,
      gridCount: row,
      entryPrice: entryPricePreview,
      actualInvestment: actualInvestment,
      extraMargin: extraMargin,
      liquidationPrice: liquidationPrice,
      category: category,
    );
    // Per the user (2026-09-09): editing a pair's initial investment must
    // immediately pull fresh actual investment/extra margin from Pionex,
    // not wait for the next full Check Now sweep - merging this fresh
    // preview into the persisted Next Trade report right away is what
    // makes that show up on the table's very next poll. Harmless to do
    // unconditionally (every Controls-screen Check benefits the same way).
    _mergeLastReportEntry(preview);

    return {
      'symbolVerified': true,
      'message': 'Live preview computed for $symbol (${category.label}).',
      'preview': preview.toJson(),
    };
  }

  /// Items 1/2 ("Add"/"Remove" from the TradingView Red List watchlist) -
  /// FINAL. Per the user: the chart's own legend (top-left, next to the
  /// active symbol name) shows a "Flag symbol"/"Unflag symbol" button
  /// (title attribute confirms which state it's in) that TOGGLES the
  /// active symbol's membership in the currently-selected colored
  /// watchlist - a single, reliable mechanism for both directions, driven
  /// entirely by whatever symbol the chart shows. This replaced two earlier
  /// approaches that didn't pan out: the watchlist row's hover-revealed
  /// icons gave contradictory/unlabeled results across live runs, and a
  /// search-dialog-based add worked but had no remove counterpart. Every
  /// call re-verifies the ACTUAL watchlist afterward via `readWatchlist` -
  /// never trusts that a click "should" have worked.
  Future<void> _dispatchMouseMove(double x, double y) => _cdp!.send(
    'Input.dispatchMouseEvent',
    {'type': 'mouseMoved', 'x': x, 'y': y, 'button': 'none'},
  );

  Future<void> _dispatchMouseClick(double x, double y) async {
    await _dispatchMouseMove(x, y);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await _cdp!.send('Input.dispatchMouseEvent', {
      'type': 'mousePressed',
      'x': x,
      'y': y,
      'button': 'left',
      'clickCount': 1,
    });
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await _cdp!.send('Input.dispatchMouseEvent', {
      'type': 'mouseReleased',
      'x': x,
      'y': y,
      'button': 'left',
      'clickCount': 1,
    });
  }

  Future<Map<String, dynamic>> _toggleRedListFlag(
    String symbol, {
    required bool wantOnList,
  }) async {
    final switched = await setChartView(_cdp!, symbol, '60');
    if (!switched.ok) {
      return {
        'ok': false,
        'message':
            'Could not switch the chart to $symbol: ${switched.error ?? 'timeout'}',
      };
    }
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final probe = await _cdp!.evaluate(_findFlagButtonExpr) as Map?;
    final btn = probe?['button'] as Map?;
    if (btn == null) {
      logger.log(
        'PAIR ACTION FLAG-TOGGLE $symbol: flag button not found -> ${jsonEncode(probe)}',
      );
      return {
        'ok': false,
        'message':
            'Could not find the Flag/Unflag button for $symbol - see engine.log.',
      };
    }
    final title = '${btn['title'] ?? ''}';
    final currentlyFlagged = title.toLowerCase().contains('unflag');
    if (currentlyFlagged == wantOnList) {
      // Already in the state we want - the flag applies to whichever
      // colored list is active, so this can't distinguish "on Red List"
      // from "on some other list" without a click; treat it as already
      // matching the last _readRedList()/readWatchlist() truth instead.
      return {
        'ok': true,
        'inRedList': _redListSymbols.contains(symbol),
        'message':
            '$symbol\'s flag is already ${wantOnList ? 'set' : 'unset'}.',
      };
    }
    await _dispatchMouseClick(
      (btn['x'] as num).toDouble(),
      (btn['y'] as num).toDouble(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final verify = await readWatchlist(_cdp!, wantName: _redListName);
    final nowSymbols = verify.symbols.toSet();
    final nowOnList = nowSymbols.contains(symbol);
    _redListSymbols = nowSymbols.toList();
    if (nowOnList == wantOnList) {
      logger.log(
        'PAIR ACTION FLAG-TOGGLE $symbol: confirmed ${wantOnList ? 'added to' : 'removed from'} the Red List.',
      );
      return {
        'ok': true,
        'inRedList': nowOnList,
        'message':
            '$symbol ${wantOnList ? 'added to' : 'removed from'} the Red List.',
      };
    }
    logger.log(
      'PAIR ACTION FLAG-TOGGLE $symbol: clicked the flag toggle but Red '
      'List membership is now=$nowOnList (wanted $wantOnList) - see '
      'engine.log. Current list: ${verify.symbols.join(', ')}',
    );
    return {
      'ok': false,
      'inRedList': nowOnList,
      'message':
          'Clicked the flag toggle but $symbol\'s Red List membership '
          'didn\'t change as expected - see engine.log.',
    };
  }

  /// "Ignite" (2026-09-15, per the user): the thunder icon on a waiting
  /// pair - opens it right now on the current Worm10 confirmed event
  /// (still gated by `_confirmedWorm10Event`'s closed-candle rule, per the
  /// user's Worm10 spec §8 - a bare zigzag is allowed to open here, unlike
  /// a normal open). Goes through the exact same `_manageGridPair` open path every other
  /// real open uses - per the user, once opened it's a completely normal
  /// auto-managed bot, no special tracking or different close behavior.
  /// Opposite-direction re-entry after a raw -50% baseline SL hit
  /// (2026-09-18, per the user: "if current bot xrp 3m short triggered sl
  /// for -50%, then next bot xrp 3m should be long... ignited immediately
  /// with new trading view calculations for price range" - a raw -50% loss
  /// means the original direction was wrong, so this re-enters the OPPOSITE
  /// direction right away instead of waiting for a fresh confirming signal).
  /// Deliberately does NOT special-case the close side of the new bot - per
  /// the user ("for stopping this new bot... you should wait as usual for
  /// the hh yellow/green/purple"), it closes via the exact same standing
  /// opposite-signal mechanism every other bot already uses, unchanged.
  /// Fire-and-forget from the reconciliation loop - failures are logged,
  /// never rethrown, since the real close that triggered this has already
  /// happened regardless of whether the re-entry succeeds.
  Future<void> _reigniteOpposite(
    String symbol,
    AutoCategory category,
    GridDirection forcedDirection,
  ) async {
    final base = _baseOf(symbol);
    if (retired.isRetiredBase(base, category)) {
      logger.log(
        'SL RE-IGNITE $symbol[${category.label}]: base is retired (Last) - not reopening.',
      );
      return;
    }
    if (_appGridForKey(_gridKey(base), category) != null) {
      logger.log(
        'SL RE-IGNITE $symbol[${category.label}]: already running - nothing to do.',
      );
      return;
    }
    final reigniteEntryKey = '${_gridKey(base)}|${category.wireValue}';
    final confirmedEvent = await _confirmedWorm10Event(
      reigniteEntryKey,
      symbol,
      category,
      immediate: true,
    );
    if (confirmedEvent == null) {
      logger.log(
        'SL RE-IGNITE $symbol[${category.label}]: no confirmed Worm10 event available right now - could not reopen ${forcedDirection.wireValue}.',
      );
      return;
    }
    _lastCreateSkipReason = null;
    await _manageGridPair(
      GridPairConfig(symbol: symbol, investment: pairInvestments.investmentOf(symbol)),
      confirmedEvent,
      checkNowTriggered: true,
      createBlocked: false,
      category: category,
      bypassFreshSignalGate: true,
      forcedDirection: forcedDirection,
    );
    if (_lastCreateSkipReason != null) {
      logger.log(
        'SL RE-IGNITE $symbol[${category.label}]: refused - $_lastCreateSkipReason.',
      );
      return;
    }
    logger.log(
      'SL RE-IGNITE $symbol[${category.label}]: opening ${forcedDirection.wireValue} now (previous bot hit its raw -50% baseline stop-loss).',
    );
  }

  Future<Map<String, dynamic>> _pairActionIgnite(String symbol) async {
    final base = _baseOf(symbol);
    final category = pairCategories.categoryOf(symbol);
    // Bug fixed 2026-09-24, live (per the user: two genuinely-Waiting bases
    // - GALA and DOT, both had just closed for real - refused Ignite with
    // "already running") - same root cause as the matching fix just below
    // (Ignite never refreshing `_activeGridsById` after it opens a bot) and
    // the identical 2026-09-20 fix already applied to `_pairActionStart`:
    // this "already running" check read a stale cache that still thought a
    // long-since-closed bot was live. One extra, cheap API call up front
    // guarantees this decision is made against genuinely current data,
    // exactly like Start's own equivalent guard already does.
    await _refreshActiveGrids();
    if (_appGridForKey(_gridKey(base), category) != null) {
      return {
        'ok': false,
        'message': '$symbol[${category.label}] is already running - nothing to ignite.',
      };
    }
    // Retry loop added 2026-09-24, live (per the user - TRXUSDT Ignite
    // refused with "No swing/oscillator data" while BUY=0 SELL=0 was
    // logged, then a manual retry 15s later succeeded with BUY=15 SELL=27
    // on the very same chart/timeframe): `_checkBuySellOnPair`'s own wait
    // loop only waits for `latestBarTime` (the chart's latest candle) to
    // load - it does NOT guarantee the indicator's full buy/sell plotshape
    // history has finished populating by the time that bar timestamp first
    // appears, a separate, slightly slower step. Every OTHER caller of this
    // signal (the routine auto-checkup/Check Now per-pair loop) tolerates
    // an occasional empty read fine since it just checks again next cycle
    // a few minutes later - but Ignite is a single user-triggered shot that
    // used to fail hard on this exact transient instead of giving the
    // indicator a moment to finish catching up. Up to 3 attempts total, 5s
    // apart (15s worst case, well within what a user waits for Ignite to
    // resolve) before genuinely giving up and reporting "no signal".
    final entryKey = '${_gridKey(base)}|${category.wireValue}';
    Worm10Event? confirmedEvent;
    for (var attempt = 1; attempt <= 3; attempt++) {
      confirmedEvent = await _confirmedWorm10Event(
        entryKey,
        symbol,
        category,
        immediate: true,
      );
      if (confirmedEvent != null) break;
      if (attempt < 3) {
        logger.log(
          'IGNITE $symbol: attempt $attempt/3 found no confirmed Worm10 '
          'event yet - retrying in 5s in case the indicator is still '
          'catching up.',
        );
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }
    if (confirmedEvent == null) {
      return {
        'ok': false,
        'message':
            'No confirmed Worm10 event for $symbol right now - nothing to ignite from.',
      };
    }
    // Bug fixed 2026-09-15, per the user ("if reading (data from trading
    // view, pionex) fails, it stays in waiting with snackbar message"):
    // `_lastCreateSkipReason` only covers REFUSALS decided before ever
    // calling Pionex (already running, margin-safety, etc.) - a genuine
    // Pionex `create` failure (e.g. the BOT_INTERNAL_ERROR intermittency
    // investigated earlier) is caught and retried INSIDE
    // `_manageGridPair`'s own loop and never rethrown, so this used to
    // report success regardless of whether Pionex actually accepted
    // anything. `_openEntryByPair[entryKey]` is what a genuine create
    // success sets (before the PREPARE-confirm wait even starts) - a
    // before/after check here is the reliable way to tell "really opened"
    // from "tried and Pionex rejected every attempt", since a duplicate
    // real grid was already ruled out above and `_activeGridsById` (what
    // `_appGridForKey` reads) only refreshes on its own separate cycle,
    // too slow to check synchronously right after this call returns.
    final hadEntryBefore = _openEntryByPair.containsKey(entryKey);
    _lastCreateSkipReason = null;
    await _manageGridPair(
      GridPairConfig(
        symbol: symbol,
        investment: pairInvestments.investmentOf(symbol),
      ),
      confirmedEvent,
      checkNowTriggered: true,
      createBlocked: false,
      category: category,
      bypassFreshSignalGate: true,
    );
    if (_lastCreateSkipReason != null) {
      return {
        'ok': false,
        'message': 'Ignite $symbol: refused - $_lastCreateSkipReason.',
      };
    }
    final opened = !hadEntryBefore && _openEntryByPair.containsKey(entryKey);
    if (!opened) {
      return {
        'ok': false,
        'message':
            'Ignite $symbol: Pionex did not accept the open - staying in waiting, see engine.log for the real error.',
      };
    }
    // Bug fixed 2026-09-24, live (per the user - a real TRX bot Ignited,
    // then tagged for Stop Loss Lock, kept showing -50% SL live on Pionex
    // for 5+ minutes with zero engine action): same root cause the
    // 2026-09-20 Start fix already documented above - `_activeGridsById`
    // only refreshes as a side effect of some OTHER code path, never
    // guaranteed. Confirmed live: the last "ACTIVE GRIDS" refresh was
    // logged BEFORE this exact bot was even created, and nothing else
    // happened to trigger a fresh one for 5+ minutes afterward - so
    // `_runTpSlRatchetSweep`'s loop (which only ever iterates whatever IS
    // in `_activeGridsById`) never once saw this bot exist, and its
    // Stop-Loss-Lock-tagged clear-on-tag branch never got a chance to run.
    // One extra, cheap API call right after a confirmed-successful Ignite
    // guarantees the new bot is immediately visible to every mechanism
    // that reads this cache, not just whatever happens to refresh it next.
    await _refreshActiveGrids();
    return {
      'ok': true,
      'message': 'Ignite $symbol[${category.label}]: opening now.',
    };
  }

  Future<Map<String, dynamic>> _pairActionAdd(String symbol) async {
    if (_redListSymbols.contains(symbol)) {
      return {
        'ok': true,
        'inRedList': true,
        'alreadyExisted': true,
        'message': '$symbol is already on the Red List.',
      };
    }
    return _toggleRedListFlag(symbol, wantOnList: true);
  }

  Future<Map<String, dynamic>> _pairActionRemove(String symbol) async {
    if (!_redListSymbols.contains(symbol)) {
      return {
        'ok': true,
        'inRedList': false,
        'alreadyAbsent': true,
        'message': '$symbol is already not on the Red List.',
      };
    }
    return _toggleRedListFlag(symbol, wantOnList: false);
  }

  /// REDESIGNED 2026-09-13, per the user: "once i choose pair and click
  /// on start, it should immediately appear in waiting ... and waiting
  /// engine will take place to initiate those bots." No longer touches
  /// the chart at all - for each symbol, just registers the app's
  /// ongoing responsibility for that base (adds it to its category's
  /// auto-managed list, same as any recycled base already gets) and
  /// returns near-instantly. `_runWaitingEngine` (already running
  /// continuously) picks it up on its very next pass and does the real
  /// signal-check/open - Waiting shows it immediately since that's the
  /// exact same list it already reads. Fixes a real, live-confirmed bug
  /// the old synchronous-per-symbol design had: it held the shared chart
  /// for the whole batch, one symbol at a time, and could stall a real
  /// Check Now sweep indefinitely if it collided with one (confirmed
  /// live: a 14-symbol Start stalled a 27-pair Check Now sweep at "pair 1
  /// of 27" for 4+ minutes, repeatedly pausing and immediately
  /// re-pausing at the same point with zero forward progress).
  Future<Map<String, dynamic>> _pairActionStart(
    String id,
    List<String> symbols, {
    List<String>? alreadyOpened,
    Map<String, String>? alreadySkipped,
  }) async {
    final opened = <String>[...?alreadyOpened];
    final skipped = <String, String>{...?alreadySkipped};
    final remaining = List<String>.from(symbols);
    // Bug fixed 2026-09-20, live (per the user: "i choose btc 1h from next
    // trade and i check start but it tells s btc already running. while it
    // is not"): `_activeGridsById` (what `_appGridForKey`'s "already
    // running" check below reads) is only ever refreshed as a SIDE EFFECT
    // of the regular auto-checkup pass or the waiting engine's own loop -
    // neither of which is guaranteed to be running at any given moment
    // (confirmed live: the 1H category's own pass hadn't run in 28+
    // minutes, and the waiting engine had already exited once its list
    // emptied out). A bot Stopped directly from the GUI (which calls
    // Pionex's cancel API directly, bypassing the engine entirely) then
    // had no timely way to get reflected here - `_activeGridsById` stayed
    // stale with the already-cancelled bot, so Start kept refusing to
    // reopen it, confirmed against Pionex's own real grid list showing
    // zero BTC grids at all. One extra, cheap API call up front guarantees
    // every Start decision below is made against genuinely current data.
    await _refreshActiveGrids();
    while (remaining.isNotEmpty) {
      // Per the user (2026-09-11): a user-initiated pair still waiting to
      // be checked/opened should show in the Auto bots card's "Waiting"
      // row too, same as a recycled base waiting for its next
      // auto-checkup attempt - not just silently invisible while Start
      // sits paused for an Auto category (which, since today, can
      // genuinely take a minute or two). Also carries `opened`/`skipped`
      // so far (per the user's very next request: "add per-pair feedback
      // as each one resolves, instead of one big summary at the end") -
      // the GUI's own poll loop diffs against what it's already shown and
      // surfaces each newly-resolved symbol the moment this file reflects
      // it, rather than waiting for the whole batch to finish. Refreshed
      // every iteration so it always reflects exactly what's still left
      // and what's been decided so far.
      _persistStartInProgress(id, remaining, opened, skipped);
      // Bug fixed 2026-09-11, per the user: an Auto category's candle
      // boundary can now preempt an in-progress Start the same way it
      // already preempts Check Now - checked here, between symbols, same
      // cooperative-cancellation spot _runCycle uses for its own per-pair
      // loop. Returns a "paused" marker instead of a final result;
      // _processPairAction saves this state and resumes it once the Auto
      // category that preempted it is done, rather than writing an
      // incomplete result to pairActionResultFile.
      if (_pairActionCancelledForAutoCheckup) {
        // Reset right where it's consumed - same discipline
        // _cycleCancelledForAutoCheckup's own reset uses (in
        // _runCycleGuarded's cleanup). A stuck true here would make the
        // very next Start immediately "pause" on its first symbol
        // forever, even with no Auto category actually waiting.
        _pairActionCancelledForAutoCheckup = false;
        return {
          'paused': true,
          'remaining': remaining,
          'opened': opened,
          'skipped': skipped,
        };
      }
      final symbol = remaining.removeAt(0);
      final base = _baseOf(symbol);
      final key = _gridKey(base);
      // Per the user (2026-09-07): which category this pair's knob was set
      // to (Next Trade table/Check card) - defaults to 1H.
      final pairCategory = pairCategories.categoryOf(symbol);
      // Per the user (2026-09-06): a manual grid already running on this
      // pair must never block Start from opening the app's OWN grid
      // alongside it - only an existing APP grid counts as "already
      // running" here.
      if (_appGridForKey(key, pairCategory) != null) {
        skipped[symbol] = 'already running';
        continue;
      }
      // Bug fixed 2026-09-12, live (per the user: "sol is opened but why
      // initial investment is not 5.. i set it 5 ... check if sol is
      // taking old history auto recycle money"): `_manageGridPair`
      // unconditionally prefers `_nextInvestmentByPair`'s recycled "old +
      // P/L" amount over whatever investment its caller passed in - the
      // right call for the AUTOMATIC waiting-engine/auto-checkup path
      // (that's the entire point of recycling for a base the app is
      // continuously managing), but wrong here: an explicit Start is the
      // user's freshest, most deliberate signal about what to invest.
      // Cleared right here, before the waiting engine ever gets a chance
      // to prefer it, so the automatic path's own recycling stays exactly
      // as it was for every other base.
      final startEntryKey = '$key|${pairCategory.wireValue}';
      if (_nextInvestmentByPair.remove(startEntryKey) != null) {
        _persistPendingInvestment(base, pairCategory, null);
        logger.log(
          'PAIR ACTION START $symbol: clearing a stale recycled investment '
          'in favor of the explicitly-set \$${pairInvestments.investmentOf(symbol)}.',
        );
      }
      // REDESIGNED 2026-09-13, per the user: "once i choose pair and
      // click on start, it should immediately appear in waiting ... and
      // waiting engine will take place to initiate those bots." Start's
      // job is now just to register the app's ongoing responsibility for
      // this base - exactly what a recycled base already has the moment
      // it closes - and return immediately; `_runWaitingEngine` (already
      // running continuously, already has its own cooldown/retry/
      // deprioritize/5-strike-termination logic fully built out) picks
      // this up on its very next pass and does the actual signal-check/
      // open. This also fixes a real, live-confirmed bug: the OLD
      // synchronous per-symbol open (`_checkBuySellOnPair` +
      // `_manageGridPair`, right here) held the shared chart for the
      // whole batch, one symbol at a time - confirmed live, a 14-symbol
      // Start stalled a real Check Now sweep at "pair 1 of 27" for 4+
      // minutes with zero forward progress, repeatedly pausing and
      // immediately re-pausing at the same point.
      // Bug fixed 2026-09-13, live (confirmed: EVERY base the user tried
      // to Start - all 18 already on the auto-managed list - was ALSO
      // still in `retired.json` from an earlier "Last"/5-strike
      // termination, so it got added here but then silently skipped
      // right back out by BOTH `waitingBases()`'s display filter and
      // `_runWaitingEngine`'s own `persistentRetired.contains(base)`
      // check - added to the list, doing nothing, forever, exactly
      // matching "i click start, but then nothing happened"). An
      // explicit Start is exactly as deliberate a re-enable as a
      // genuinely successful open already is elsewhere in this file
      // (see the matching `retired.removeRetiredBases([base])` in the
      // create-success path) - clears any stale retirement right here
      // too, so it can never silently block a base the user just asked
      // to run.
      // Bug fixed 2026-09-14, confirmed live TWICE the same day (SOLUSDT):
      // this used to arm the fresh-signal-wait gate unconditionally for
      // EVERY Start click, even when the base was ALREADY auto-managed -
      // i.e. already sitting in the waiting list, already being retried
      // gate-free by `_runWaitingEngine` every ~20s. Starting a base that
      // didn't need Start at all silently added a wait it never had,
      // delaying a base that was already progressing normally. Checked
      // BEFORE `addBase` below (which would make this always true
      // afterward) - the gate now only arms for a base that's genuinely
      // new to auto-management this call, matching the gate's own actual
      // purpose ("wait for a signal genuinely newer than whatever existed
      // when Start was clicked") - re-Starting an already-waiting base
      // isn't a new baseline moment at all.
      // Start does one job (per the user, 2026-11-08): put the pair on
      // Auto's list and fill it NOW on its current signal - tradingMT5's
      // Ignite - with the app's own technique (40/60, price range, leverage,
      // grids, actual investment, extra margin). If it can't fill, the pair
      // just stays in Waiting.
      retired.removeRetiredBases([(base: base, category: pairCategory)]);
      autoManagedByCategory[pairCategory]!.addBase(base);
      // Start is done once the pair is in Waiting (per the user,
      // 2026-11-08): the fill itself runs from [_fillQueue], one pair at a
      // time, so the user can Start more pairs meanwhile.
      if (!_fillQueue.contains(symbol)) _fillQueue.add(symbol);
      opened.add(symbol);
    }
    final message = opened.isEmpty
        ? 'Nothing added (${skipped.entries.map((e) => '${e.key}: ${e.value}').join('; ')}).'
        : 'In Waiting, filling now: ${opened.join(', ')}.'
              '${skipped.isEmpty ? '' : ' Skipped: ${skipped.entries.map((e) => '${e.key} (${e.value})').join(', ')}.'}';
    return {
      'ok': opened.isNotEmpty,
      'opened': opened,
      'skipped': skipped,
      'message': message,
    };
  }

  /// Consecutive `_connect()` failures where TradingView's CDP port was
  /// genuinely reachable (`isCdpUp` true) but the chart/JS layer itself
  /// never cooperated - the signature of TradingView being alive-but-stuck
  /// (frozen behind a dialog, corrupted renderer state, etc.), as opposed
  /// to genuinely not running at all (which the `!up` branch below already
  /// handles by launching it fresh). Reset to 0 on any success. See
  /// [_forceRelaunchTradingViewThreshold]'s doc for what happens once this
  /// climbs too high.
  int _consecutiveConnectFailuresWhileCdpUp = 0;

  /// Self-healing escalation (2026-09-27, per the user's own direct
  /// question about closing every remaining self-healing gap this session
  /// surfaced): every retry inside a single `_connect()` call already has
  /// its own bounded timeout (`connectToChart`'s 5-attempt backoff,
  /// `waitForChartApiReady`'s 60s deadline) - genuinely useful for a
  /// transient stall, but powerless against TradingView being alive-but-
  /// stuck for an EXTENDED period (frozen behind a dialog, a corrupted
  /// renderer, etc.) - every fresh `_connect()` call just fails the exact
  /// same way forever, with nothing ever trying the one thing that
  /// actually fixes a stuck desktop app: killing and relaunching it. Once
  /// [_consecutiveConnectFailuresWhileCdpUp] reaches this many, force-kills
  /// TradingView (`pkill -9`, the same mechanism `launchTradingView` itself
  /// already uses whenever a launch attempt needs to clear a stale
  /// instance first) and lets the next `_connect()` call launch it fresh,
  /// exactly like the "not running at all" branch already does.
  static const int _forceRelaunchTradingViewThreshold = 3;

  /// Whether the watchdog has already reloaded this app's own tab for the
  /// current stuck spell; heavier recovery is tried only after that. Reset on
  /// any successful connect.
  bool _ownTabReloadTried = false;

  /// TradingView sync with tradingMT5 (tv_sync.dart, per the user
  /// 2026-11-13): heartbeat, the shared lock, and restart requests.
  final TvSync tvSync = TvSync(app: TvSync.pionex);
  Timer? _tvSyncTimer;
  bool _peerRestartLogged = false;
  DateTime? _lastRestartRequestAt;

  void _writeTvSyncHeartbeat({bool power = true}) {
    try {
      tvSync.writeHeartbeat(
        power: power,
        tab: _cdp != null && !_cdp!.dead ? 'claimed' : 'missing',
        busy: _mainLoopRunning || _pairActionRunning || _anyAutoRunning,
        tvHealthy: _cdp != null && !_cdp!.dead,
        version: CoreConstants.appVersion,
      );
    } catch (_) {}
  }

  /// Opening a tab takes the shared lock; false (skip) if tradingMT5 holds it.
  bool _lockForTabOpen() {
    final ok = tvSync.tryLock('open_tab');
    if (!ok) {
      logger.log(
        'TV SYNC: tradingMT5 holds the TradingView lock - not opening a tab now.',
      );
    }
    return ok;
  }

  Future<CdpClient?> _connect() async {
    // tradingMT5 is restarting TradingView: pause chart reads until it is
    // done, instead of failing every read meanwhile.
    if (tvSync.peerRestartingTradingView()) {
      if (!_peerRestartLogged) {
        _peerRestartLogged = true;
        logger.log(
          'TV SYNC: tradingMT5 is restarting TradingView - pausing chart reads '
          'until it is done.',
        );
      }
      _writeStatus(
        message: 'TradingView restarting (tradingMT5) - waiting',
        busy: false,
      );
      return null;
    }
    _peerRestartLogged = false;    if (_cdp != null && !_cdp!.dead) {
      // A TradingView restart wipes every tab's owner tag, so the tab this
      // client points at may no longer be ours - re-find it every cycle.
      if (await isOwnTab(_cdp!)) return _cdp;
      logger.log(
        'CDP: this app\'s tab tag is gone (TradingView restarted?) - finding or claiming its tab again.',
      );
      _cdp!.close();
    }
    if (_cdp != null) {
      logger.log('CDP client was dead/timeout - reconnecting fresh.');
      _cdp = null;
    }
    // TradingView is shared with tradingMT5, so this app never launches or
    // kills it (see launch.dart) - it only reports that it needs opening.
    if (!await isCdpUp(config.cdp.host, config.cdp.port)) {
      logger.log(
        'CDP unavailable: TradingView is not reachable on '
        '${config.cdp.host}:${config.cdp.port}. Open TradingView Desktop with '
        '--remote-debugging-port=${config.cdp.port}.',
        level: 'CRITICAL',
      );
      _writeStatus(
        message: 'TradingView not open — open it, then this reconnects by itself',
        busy: false,
      );
      return null;
    }
    try {
      _writeStatus(message: 'Connecting to chart...', busy: true);
      final client = await connectToChart(
        config.cdp.host,
        config.cdp.port,
        layoutName: config.cdp.layoutName,
        beforeOpenTab: _lockForTabOpen,
        afterOpenTab: tvSync.releaseLock,
      );
      logger.log('CDP connected (${config.cdp.host}:${config.cdp.port})');
      final ready = await waitForChartApiReady(client);
      if (!ready) {
        logger.log(
          'Chart API did not become ready in time - aborting this cycle.',
        );
        // A slow/stuck chart load is very often a dead internet connection
        // rather than a TradingView problem - re-check right now instead of
        // waiting for the next (busy-gated) verify tick, so status.json's
        // internetHealthy reflects reality promptly (2026-09-11, per the
        // user: "long time to connect to chart" traced to internet outages
        // that weren't surfaced to the GUI).
        unawaited(_checkInternet());
        client.close();
        await _forceRelaunchTradingViewIfStuck();
        return null;
      }
      _consecutiveConnectFailuresWhileCdpUp = 0;
      _ownTabReloadTried = false;
      return client;
    } catch (e) {
      logger.log('CDP unavailable: $e');
      unawaited(_checkInternet());
      await _forceRelaunchTradingViewIfStuck();
      return null;
    }
  }

  /// See [_forceRelaunchTradingViewThreshold]'s doc for the full rationale.
  /// Only ever called from a path where `isCdpUp` was already confirmed
  /// true THIS call (the CDP port itself is reachable) but the chart/JS
  /// layer still failed - genuinely not-running is already handled by the
  /// ordinary launch branch above and never reaches here.
  Future<void> _forceRelaunchTradingViewIfStuck() async {
    _consecutiveConnectFailuresWhileCdpUp++;
    if (_consecutiveConnectFailuresWhileCdpUp <
        _forceRelaunchTradingViewThreshold) {
      return;
    }
    _consecutiveConnectFailuresWhileCdpUp = 0;
    // First, reload only this app's own tab - TradingView is shared with
    // another app's tab, which a restart would also take down.
    if (!_ownTabReloadTried) {
      _ownTabReloadTried = true;
      try {
        final client = await connectToChart(
        config.cdp.host,
        config.cdp.port,
        layoutName: config.cdp.layoutName,
        beforeOpenTab: _lockForTabOpen,
        afterOpenTab: tvSync.releaseLock,
      );
        if (!tvSync.tryLock('reload_own_tab')) {
          client.close();
          _ownTabReloadTried = false;
          logger.log(
            'TV SYNC: tradingMT5 holds the TradingView lock - not reloading this '
            'app\'s tab now; trying again later.',
          );
          return;
        }
        try {
          await reloadOwnTab(client);
        } finally {
          client.close();
          tvSync.releaseLock();
        }
        logger.log(
          'TRADINGVIEW WATCHDOG: chart did not cooperate $_forceRelaunchTradingViewThreshold '
          'times in a row - reloaded this app\'s own tab only.',
          level: 'CRITICAL',
        );
      } catch (e) {
        logger.log(
          'TRADINGVIEW WATCHDOG: could not reload this app\'s own tab: $e',
          level: 'CRITICAL',
        );
      }
      return;
    }
    // Never kill TradingView: it's shared with tradingMT5's tab. Only
    // tradingMT5 restarts it - ask it to (tv_sync.dart), at most once every
    // 10 minutes and only while it is online.
    final peer = tvSync.peer(TvSync.mt5);
    final lastAsk = _lastRestartRequestAt;
    final canAsk = peer != null &&
        !tvSync.hasPendingRequest(to: TvSync.mt5, type: 'restart_tradingview') &&
        (lastAsk == null ||
            DateTime.now().difference(lastAsk) > const Duration(minutes: 10));
    if (canAsk) {
      _lastRestartRequestAt = DateTime.now();
      tvSync.sendRequest(
        to: TvSync.mt5,
        type: 'restart_tradingview',
        reason:
            'TradingPionex: chart did not cooperate after reloading its own tab',
      );
    }
    logger.log(
      'TRADINGVIEW WATCHDOG: CDP port reachable but the chart never '
      'cooperated $_forceRelaunchTradingViewThreshold times in a row, even '
      'after reloading this app\'s own tab - TradingView looks stuck. '
      '${canAsk ? 'Asked tradingMT5 to restart it.' : peer == null ? 'tradingMT5 is offline - restart TradingView by hand.' : 'A restart request to tradingMT5 is already waiting.'}',
      level: 'CRITICAL',
    );
  }

  /// [reportStatus] controls whether the routine "Verifying chart
  /// indicators..." pre-check write reaches Power's own status line
  /// (2026-09-10, per the user - deep-checked, not guessed: this function
  /// is called from BOTH a genuine connectivity milestone
  /// (`_refreshRedListNow`, Power-on/REFRESH_REDLIST) AND, far more often,
  /// from routine per-pair work (`_checkBuySellOnPair`/`_readZigzagLines`
  /// - called at least twice per pair per category per cycle, for every
  /// pair, in every one of the 3 auto-checkup engines). Writing the
  /// general `message`/`busy` fields unconditionally meant Power's status
  /// line and its "Checking" blink were driven by ordinary 1m/1H/1D
  /// per-pair activity nearly continuously whenever Auto was on - not
  /// actually a Power/connectivity event at all, just this function
  /// getting called as a normal side effect of checking one more pair.
  /// Only the initial connectivity-refresh caller passes true; the two
  /// per-pair callers pass false. A genuine reload/failure below (rare,
  /// always noteworthy regardless of which caller triggered it) is
  /// unaffected - that still always reports.
  Future<bool> _ensureCustomScripts({bool reportStatus = false}) async {
    if (_cdp == null) return false;
    try {
      await dismissUpgradeDialog(_cdp!);
    } catch (e) {
      logger.log('dismissUpgradeDialog: $e');
    }
    if (reportStatus) {
      _writeStatus(message: 'Verifying chart indicators...', busy: true);
    }
    final verifySw = Stopwatch()..start();
    VerifyResult? verified;
    try {
      verified = await verifyCustomScripts(_cdp!);
    } catch (_) {
      verified = null;
    }
    verifySw.stop();
    if (!_loggedCustomScriptSources &&
        verified != null &&
        verified.rawSources.isNotEmpty) {
      _loggedCustomScriptSources = true;
      logger.log(
        'CUSTOM SCRIPT SOURCES (one-time, for spy_9_26 discovery): ${jsonEncode(verified.rawSources)}',
      );
    }
    if (verified != null && verified.ok) {
      logger.log(
        'INDICATORS: verified OK in ${verifySw.elapsedMilliseconds}ms (MSB=${verified.msbPresent}, RSI=${verified.rsiPresent})',
      );
      return true;
    }
    logger.log(
      'CUSTOM SCRIPTS MISSING (verify took ${verifySw.elapsedMilliseconds}ms, MSB=${verified?.msbPresent}, RSI=${verified?.rsiPresent}) - '
      'closing all indicators and reopening the two custom scripts',
    );
    _writeStatus(message: 'Reloading chart indicators...', busy: true);
    final reloadSw = Stopwatch()..start();
    try {
      final enforced = await enforceCustomScripts(
        config.cdp.host,
        config.cdp.port,
      );
      reloadSw.stop();
      if (!enforced.finalMsb || !enforced.finalRsi) {
        logger.log(
          'CRITICAL: could not restore both custom scripts after ${reloadSw.elapsedMilliseconds}ms - SKIPPING all data reads this cycle',
          level: 'CRITICAL',
        );
        _markTvUnhealthy();
        return false;
      }
      logger.log(
        'Custom scripts restored in ${reloadSw.elapsedMilliseconds}ms.',
      );
      return true;
    } catch (e) {
      reloadSw.stop();
      logger.log(
        'ENFORCE FAILED after ${reloadSw.elapsedMilliseconds}ms: $e - SKIPPING all data reads this cycle',
      );
      _markTvUnhealthy();
      return false;
    }
  }

  /// `_connect()` only re-verifies `window.TradingViewApi` when establishing
  /// a brand-new CdpClient (`_cdp!.dead` gates that) - so a TradingView UI
  /// update that breaks the JS bridge mid-session, without the WebSocket
  /// itself closing, would otherwise leave `cdpHealthy` reporting "fine"
  /// forever while every read silently fails. Marking the client dead here
  /// forces a fresh connect (and therefore a fresh `waitForChartApiReady`
  /// check) next cycle, and flips the status the GUI actually shows.
  void _markTvUnhealthy() {
    if (_prevTvHealthy) {
      logger.log(
        'TV/CDP JS BRIDGE BROKEN: chart indicators could not be restored after retrying - '
        'marking TradingView unhealthy and forcing a fresh reconnect next cycle.',
        level: 'CRITICAL',
      );
    }
    _prevTvHealthy = false;
    _cdp?.dead = true;
  }

  /// Worm10 Hybrid Decision technique (2026-10-25) - replaces
  /// `_checkBuySellOnPair`/`readWormSignals` entirely (per the user: "and
  /// remove any old technique from code and from prd"). [resolution] is
  /// the signal timeframe - '60' (1H) for the original/1H category;
  /// per-category callers pass their own [AutoCategory.signalResolution]
  /// instead. The indicator-wait failure ladder is tracked per
  /// symbol+resolution, same as before.
  ///
  /// Reads on Heikin Ashi (per the user's exact spec - `setChartStyle` is
  /// idempotent, a no-op if the chart is already on it), derives the full
  /// event stream, and takes the single latest event - then re-reads TWICE
  /// more, 10 seconds apart, and requires all three reads to agree on
  /// type+time exactly, or the whole cycle is treated as unconfirmed (the
  /// same "1 million sure" flicker-protection `_checkBuySellOnPair` used to
  /// do, carried over unchanged). This is the RAW, per-cycle read only - no
  /// candle-survival wait here; see [_confirmedWorm10Event] for the
  /// stateful gate real trading decisions must go through on top of this.
  Future<({Worm10Event? event, int? latestBarTime})> _readWorm10Candidate(
    String symbol, {
    String resolution = '60',
  }) async {
    final check = await _readWorm10Chart(symbol, resolution);
    if (check == null) return (event: null, latestBarTime: null);
    final events = deriveWorm10Events(check);
    final candidate = events.isEmpty ? null : events.last;
    logger.log(
      'CHECKUP $symbol $resolution: ${events.length} event(s) derived, latest='
      '${candidate == null ? 'none' : '${candidate.kind.name}@${candidate.time}'}',
    );
    if (candidate == null ||
        !await _worm10TripleConfirmed(symbol, resolution, candidate)) {
      return (event: null, latestBarTime: check.latestBarTime);
    }
    return (event: candidate, latestBarTime: check.latestBarTime);
  }

  /// Switches the chart to [symbol]/[resolution] and reads its Worm10 bars, or
  /// returns null rather than risk reading the wrong data: a failed switch is
  /// never read past (the chart may still show another symbol), and after a
  /// real switch the indicators' own plot data must settle first, since it can
  /// lag the chart's label by a few seconds.
  Future<Worm10Check?> _readWorm10Chart(
    String symbol,
    String resolution,
  ) async {
    if (!(await _ensureCustomScripts())) return null;
    final switched = await setChartView(_cdp!, symbol, resolution);
    if (!switched.ok) {
      logger.log(
        'CHECKUP $symbol $resolution SWITCH FAILED: ${switched.error ?? 'timeout'} - '
        'refusing to read signals from a chart that might still be showing a '
        'different symbol.',
        level: 'ERROR',
      );
      return null;
    }
    await setChartStyle(_cdp!, chartStyleHeikinAshi);

    const waitLadderSec = [30, 20, 10, 5, 5];
    final waitKey = '$symbol@$resolution';
    final fails = _indicatorWaitFailures[waitKey] ?? 0;
    final budgetSec = waitLadderSec[fails.clamp(0, waitLadderSec.length - 1)];
    final started = DateTime.now();
    logger.log(
      'INDICATOR WAIT $symbol $resolution: waiting up to ${budgetSec}s for the latest bar to load.',
    );
    Future<Worm10Check> read(String label) => readWorm10Signals(
      _cdp!,
      chartSymbolFor(symbol),
      customScripts[0].scriptIdPart,
      customScripts[1].scriptIdPart,
      onDebugError: (msg) =>
          logger.log('WORM10 DEBUG ($label) $symbol $resolution: $msg'),
    );
    Worm10Check result;
    while (true) {
      result = await read('read');
      if (result.latestBarTime != null) {
        _indicatorWaitFailures.remove(waitKey);
        break;
      }
      if (DateTime.now().difference(started).inSeconds >= budgetSec) {
        // Same floor-retry escape as the original ladder (2026-09-16 fix,
        // carried over unchanged) - see the historical doc in this
        // function's git history for the full "why".
        final nextFails = fails + 1;
        final floorIndex = waitLadderSec.length - 1;
        final atFloorFor = nextFails - floorIndex;
        if (fails >= floorIndex && atFloorFor >= _indicatorWaitFloorRetries) {
          _indicatorWaitFailures[waitKey] = 0;
          logger.log(
            'WORM10 WAIT $symbol $resolution: stuck at the shortest wait (${budgetSec}s) for $atFloorFor extra attempts - '
            'resetting to a full ${waitLadderSec.first}s budget to check whether this has become a transient/systemic issue.',
          );
        } else {
          _indicatorWaitFailures[waitKey] = nextFails;
        }
        logger.log(
          'WORM10 WAIT $symbol $resolution: indicator not applied after ${budgetSec}s (consecutive unloaded=$nextFails) - moving on',
        );
        return null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }

    // tradingMT5's settle rule, unchanged: after a switch the plot data can be
    // empty or still the old symbol's for a few seconds. Stable only when two
    // reads agree on the last zigzag signal (time + tag); an empty read is
    // never stable.
    if (switched.switched) {
      var stable = false;
      const settleAttempts = 10;
      for (var attempt = 0; attempt < settleAttempts; attempt++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final recheck = await read('settle');
        final prevLast = result.zigzag.signals.isEmpty ? null : result.zigzag.signals.last;
        final nextLast = recheck.zigzag.signals.isEmpty ? null : recheck.zigzag.signals.last;
        final agree = nextLast != null &&
            prevLast?.time == nextLast.time &&
            prevLast?.tag == nextLast.tag;
        result = recheck;
        if (agree) {
          stable = true;
          break;
        }
        logger.log(
          nextLast == null
              ? 'WORM10 SETTLE $symbol $resolution: indicator data not calculated yet '
                    'after the symbol switch (attempt ${attempt + 1}/$settleAttempts) - waiting.'
              : 'WORM10 SETTLE $symbol $resolution: signal data still settling after '
                    'the symbol switch (attempt ${attempt + 1}/$settleAttempts) - retrying.',
        );
      }
      if (!stable) {
        logger.log(
          'WORM10 SETTLE $symbol $resolution: signal data never stabilized after '
          'switching charts - skipping rather than risk acting on possibly-stale '
          'data from another symbol.',
          level: 'ERROR',
        );
        return null;
      }
    }
    return result;
  }

  /// "1 million sure" rule (2026-09-27, per the user's own standing rule):
  /// three total reads, 10 seconds apart, must agree on type AND bar time, or
  /// the cycle is skipped (no trade, no close) and retried fresh next cycle.
  /// [first] is read #1.
  Future<bool> _worm10TripleConfirmed(
    String symbol,
    String resolution,
    Worm10Event first,
  ) async {
    for (var confirmAttempt = 1; confirmAttempt <= 2; confirmAttempt++) {
      await Future<void>.delayed(const Duration(seconds: 10));
      final confirm = await readWorm10Signals(
        _cdp!,
        chartSymbolFor(symbol),
        customScripts[0].scriptIdPart,
        customScripts[1].scriptIdPart,
        onDebugError: (msg) =>
            logger.log('WORM10 DEBUG (confirm) $symbol $resolution: $msg'),
      );
      final confirmEvents = deriveWorm10Events(confirm);
      final confirmLatest = confirmEvents.isEmpty ? null : confirmEvents.last;
      if (confirmLatest != first) {
        logger.log(
          'WORM10 FLICKER $symbol $resolution: read #1 '
          '${first.kind.name}@${first.time}, read #${confirmAttempt + 1} '
          '${confirmLatest == null ? 'nothing' : '${confirmLatest.kind.name}@${confirmLatest.time}'} '
          '- disagreement, treating as unconfirmed this cycle.',
          level: 'WARNING',
        );
        return false;
      }
    }
    return true;
  }

  /// The Worm10 decision gate (§5 of the user's spec). Returns the event to
  /// act on now, or null. Never re-delivers an older event while a newer one
  /// is pending: it only ever answers with the chart's latest event.
  ///
  /// Normal check, in order: a pending event mid-wait skips the read entirely;
  /// a 3-minute per-pair cooldown (unless [skipCooldown]); read; the retroactive
  /// audit; triple-read; then a new or changed latest event becomes pending
  /// and waits until its bar time + 2 candle periods (its own candle's close
  /// plus one more full candle). Only an event already pending and past that
  /// wait is returned.
  ///
  /// [immediate] (Power-on's first check of a pair, and Ignite) skips the
  /// cooldown and the extra candle, but only if the signal's own candle has
  /// already closed - a signal on a still-forming candle takes the normal wait.
  /// The triple-read always applies.
  Future<Worm10Event?> _confirmedWorm10Event(
    String entryKey,
    String symbol,
    AutoCategory category, {
    bool immediate = false,
    bool skipCooldown = false,
  }) async {
    final period = category.candlePeriod;
    final resolution = category.signalResolution;
    final pending = _worm10Pending[entryKey];
    if (!immediate &&
        pending != null &&
        !worm10WaitIsOver(pending.time, period, DateTime.now())) {
      return null;
    }
    final lastChecked = _worm10LastCheckedAt[entryKey];
    if (!immediate &&
        !skipCooldown &&
        lastChecked != null &&
        DateTime.now().difference(lastChecked) < _worm10RetryCooldown) {
      return null;
    }
    _worm10LastCheckedAt[entryKey] = DateTime.now();
    _clearWorm10AuditCacheHourly();

    var check = await _readWorm10Chart(symbol, resolution);
    if (check == null) return null;
    var events = deriveWorm10Events(check);
    for (var i = 0; i < 2 && events.isEmpty && immediate; i++) {
      await Future<void>.delayed(const Duration(seconds: 5));
      check = await _readWorm10Chart(symbol, resolution);
      if (check == null) return null;
      events = deriveWorm10Events(check);
    }
    logger.log(
      'CHECKUP $symbol $resolution: ${events.length} event(s) derived, latest='
      '${events.isEmpty ? 'none' : '${events.last.kind.name}@${events.last.time}'}',
    );
    if (events.isEmpty) return null;
    final latest = events.last;

    if (await _auditRunningBot(entryKey, symbol, category, events)) return null;

    if (!await _worm10TripleConfirmed(symbol, resolution, latest)) return null;

    var actNow = false;
    if (immediate) {
      actNow = isCandleClosed(latest.time, period, DateTime.now());
      if (!actNow) {
        logger.log(
          'WORM10 $entryKey: ${latest.kind.name}@${latest.time} is on the '
          'still-forming candle - not acting immediately, it takes the normal '
          'wait instead.',
        );
      }
    }
    if (!actNow && pending != latest) {
      _worm10Pending[entryKey] = latest;
      _persistWorm10Pending(entryKey, latest);
      logger.log(
        'WORM10 PENDING $entryKey: ${latest.kind.name}@${latest.time} triple-confirmed - '
        'waiting for its own candle plus one more full candle to close.',
      );
      return null;
    }
    // An immediate check bypassed the mid-wait skip above, so a candidate
    // already pending must not be acted on early here.
    if (immediate &&
        !actNow &&
        !worm10WaitIsOver(latest.time, period, DateTime.now())) {
      return null;
    }
    logger.log(
      'WORM10 CONFIRMED $entryKey: ${latest.kind.name}@${latest.time} - '
      '${actNow ? 'closed candle, acting immediately' : 'now actionable'}.',
    );
    return latest;
  }

  /// Clears [_worm10AuditedBots] so every running bot gets re-audited, with the
  /// reason logged. Triggers can land together (say an internet recovery right
  /// before the hourly one), so a clear within [_worm10AuditClearDebounce] of
  /// the last one is skipped.
  void _clearWorm10AuditCache(String reason) {
    final now = DateTime.now();
    final last = _worm10AuditLastClearedAt;
    if (last != null && now.difference(last) < _worm10AuditClearDebounce) {
      return;
    }
    logger.log(
      '$reason - clearing the Worm10 audit cache to re-check every running bot '
      'against the full signal history.',
    );
    _worm10AuditedBots.clear();
    _worm10AuditLastClearedAt = now;
  }

  /// Re-arms the audit once per hour, 15 minutes before the next candle, so
  /// signals that print while the engine stays up get replayed too, with time
  /// left to act before that candle opens.
  void _clearWorm10AuditCacheHourly() {
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    const hourMs = 3600 * 1000;
    final epochHour = nowMs ~/ hourMs;
    final untilNextHourMs = hourMs - nowMs % hourMs;
    if (untilNextHourMs > _worm10HourlyAuditLeadTime.inMilliseconds ||
        _worm10LastHourlyAuditEpochHour == epochHour) {
      return;
    }
    _worm10LastHourlyAuditEpochHour = epochHour;
    _clearWorm10AuditCache('Hourly pre-candle audit');
  }

  /// The retroactive audit (§9 of the user's spec): replays the chart's events
  /// through the §4 decision table, and closes and reopens a running bot the
  /// replay says is on the wrong side. Runs once per bot until re-armed (engine
  /// start, hourly, internet recovery). Returns true if it closed the bot.
  ///
  /// The real-time check only compares the newest event with what's running, so
  /// more than one flip between checks (say a long outage) could otherwise land
  /// on the wrong direction. The replay starts from the latest genuine OPEN1
  /// event in the loaded window, whatever actually opened the bot, asking
  /// TradingView for more history if none is loaded.
  ///
  /// Stale data is what makes this dangerous: per the user, a stale signal
  /// shared by 8 trades closed all of them. So [events] only ever comes from
  /// [_readWorm10Chart]'s verified read, the verdict must be past the normal
  /// candle wait, and it must still be there on a fresh re-read before anything
  /// is written or closed.
  Future<bool> _auditRunningBot(
    String entryKey,
    String symbol,
    AutoCategory category,
    List<Worm10Event> events,
  ) async {
    final base = _baseOf(symbol);
    final existing = _appGridForKey(_gridKey(base), category);
    if (existing == null ||
        retired.isRetiredBase(base, category) ||
        _worm10AuditedBots.contains(existing.buOrderId)) {
      return false;
    }
    _adoptOpenEntryIfNeeded(existing, entryKey, base, category);
    final entry = _openEntryByPair[entryKey];
    final runningDirection = entry?.direction ?? existing.trend;
    if (entry == null || runningDirection == null) return false;
    final id = existing.buOrderId;

    Future<List<Worm10Event>> reread(String label) async => deriveWorm10Events(
      (await readWorm10Signals(
        _cdp!,
        chartSymbolFor(symbol),
        customScripts[0].scriptIdPart,
        customScripts[1].scriptIdPart,
        onDebugError: (msg) =>
            logger.log('WORM10 AUDIT ($label) $symbol: $msg'),
      )),
    );
    Worm10Event? latestOpen1(List<Worm10Event> list) {
      for (final e in list.reversed) {
        if (e.kind == Worm10EventKind.buyOpen1 ||
            e.kind == Worm10EventKind.sellOpen1) {
          return e;
        }
      }
      return null;
    }

    var auditEvents = events;
    var start = latestOpen1(auditEvents);
    if (start == null) {
      final extended = await requestMoreChartHistory(_cdp!);
      logger.log(
        'WORM10 AUDIT $entryKey ($id): no OPEN1 event in the ${auditEvents.length} '
        'loaded - history extend returned $extended.',
      );
      if (extended) {
        auditEvents = await reread('extended history');
        start = latestOpen1(auditEvents);
      }
    }
    if (start == null) {
      logger.log(
        'WORM10 AUDIT $entryKey ($id): no OPEN1 event loaded far enough back to '
        'investigate yet, even after requesting more history - will retry on a '
        'later cycle.',
        level: 'WARNING',
      );
      return false;
    }
    _worm10AuditedBots.add(id);

    // tradingMT5's replay, unchanged: start from the latest case-1 event,
    // then walk every later event in time order through worm10DecisionFor.
    final startEvent = start;
    var trueDir = worm10DecisionFor(null, startEvent.kind).resultDirection!;
    var trueStart = startEvent;
    Worm10Event? updateEvent;
    final afterStart = auditEvents.where((e) => e.time > startEvent.time).toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    for (final e in afterStart) {
      final decision = worm10DecisionFor(trueDir, e.kind);
      switch (decision.action) {
        case Worm10Action.none:
          break;
        case Worm10Action.update:
          updateEvent = e;
        case Worm10Action.recycle:
          trueStart = e;
          updateEvent = null;
        case Worm10Action.flip:
        case Worm10Action.openFresh:
          trueDir = decision.resultDirection!;
          trueStart = e;
          updateEvent = null;
      }
    }
    final trueDirection = gridDirectionOf(trueDir);
    final verdict = '${trueStart.kind.name}@${trueStart.time}';

    // tradingMT5's audit also backfills the Update on a bot already running
    // the right way.
    if (trueDirection == runningDirection && updateEvent != null) {
      final at = DateTime.fromMillisecondsSinceEpoch(updateEvent.time * 1000);
      final rec = entrySignalStore.recordFor(id);
      if (rec != null && rec.update?.at != at) {
        entrySignalStore.recordUpdate(id, at: at, type: updateEvent.kind.name);
        logger.log(
          'WORM10 AUDIT $entryKey ($id): backfilled Update '
          '${updateEvent.kind.name}@${updateEvent.time}.',
        );
      }
    }

    if (trueDirection == runningDirection) {
      // Nothing to trade on. The record of what opened the bot is pure
      // bookkeeping, so a never-recorded one needn't wait out the candle gate;
      // correcting an existing one does.
      final neverRecorded = entry.openEventType == null;
      if (entry.openedBy(trueStart) ||
          (!neverRecorded &&
              !worm10WaitIsOver(
                trueStart.time,
                category.candlePeriod,
                DateTime.now(),
              ))) {
        return false;
      }
      if (!(await reread('open record recheck')).contains(trueStart)) {
        logger.log(
          'WORM10 AUDIT $entryKey ($id): $verdict no longer present on re-read - '
          'not recording it.',
          level: 'WARNING',
        );
        return false;
      }
      _openEntryByPair[entryKey] = entry.copyWith(
        openEventType: trueStart.kind,
        openEventTime: trueStart.time,
      );
      logger.log(
        'WORM10 AUDIT $entryKey ($id): ${neverRecorded ? 'recorded' : 'corrected'} '
        'the opening event as $verdict.',
      );
      return false;
    }

    if (!worm10WaitIsOver(
      trueStart.time,
      category.candlePeriod,
      DateTime.now(),
    )) {
      logger.log(
        'WORM10 AUDIT $entryKey ($id): replay landed on $verdict, which has not '
        'waited out its candle yet - deferring until the audit re-arms.',
      );
      return false;
    }
    final paused = storage.fileExists(storage.pauseFile);
    if (paused) {
      // Auto off means no new closes. Re-audit once it's back on.
      _worm10AuditedBots.remove(id);
      logger.log(
        'WORM10 AUDIT $entryKey ($id): running ${runningDirection.wireValue} but the '
        'event chain says ${trueDirection.wireValue} ($verdict) - Auto is paused, not closing.',
      );
      return false;
    }
    logger.log(
      'WORM10 AUDIT $entryKey ($id): running ${runningDirection.wireValue} but the '
      'event chain says ${trueDirection.wireValue} ($verdict) - closing and reopening.',
      level: 'WARNING',
    );
    if (!(await reread('close recheck')).contains(trueStart)) {
      logger.log(
        'WORM10 AUDIT $entryKey ($id): $verdict no longer present on re-read - '
        'skipping the correction.',
        level: 'WARNING',
      );
      return false;
    }
    await _manageGridPair(
      GridPairConfig(
        symbol: symbol,
        investment: pairInvestments.investmentOf(symbol),
      ),
      trueStart,
      checkNowTriggered: false,
      createBlocked: false,
      category: category,
      fromAudit: true,
    );
    return true;
  }

  /// Thin wrapper over [PionexClient.getSettledGridPnl] (2026-09-19) - moved
  /// there so the GUI's own explicit-Stop flow, a separate process with its
  /// own `PionexClient` instance, can share the exact same settle-polling
  /// logic instead of duplicating it. See that method's doc for the full
  /// "why" (a real ADA bot's recycle math used a stale pre-settlement P&L,
  /// later confirmed also affecting two manually-stopped bots the same
  /// day).
  Future<double?> _getSettledGridPnl(String buOrderId) =>
      pionex.getSettledGridPnl(buOrderId);

  Future<void> _refreshActiveGrids() async {
    if (!pionex.available) {
      logger.log('SKIP grid refresh: Pionex keys not configured (.env)');
      return;
    }
    try {
      final orders = await pionex.getActiveGrids();
      // Temporary, one-time diagnostic (2026-09-16, per the user's "is the
      // bot running vs actually working" question) - dumps the real raw
      // Pionex data for one specific bot the user pointed at
      // (b1574697-c6dc-4297-a50a-3bd0aeac5116) so position/totalVolume/
      // gridProfit can be checked directly instead of guessed. Remove
      // after that check is done.
      if (!_loggedSpecificOrderSample) {
        for (final o in orders) {
          if (o['buOrderId'] == 'b1574697-c6dc-4297-a50a-3bd0aeac5116') {
            _loggedSpecificOrderSample = true;
            logger.log(
              'SPECIFIC ORDER SAMPLE (one-time, per the user): ${jsonEncode(o)}',
            );
            break;
          }
        }
      }
      // Diagnostic added 2026-09-10, one-time (per the user: "TP&SL are not
      // reflecting real values ... double check from where they are
      // reading"). GridBot.takeProfitPrice/stopLossPrice are COMPUTED from
      // top/bottom + trend (see grid_bot.dart) - nothing in
      // GridBot.fromPionexOrder ever reads a distinct take-profit/stop-loss
      // field from Pionex's own raw response, because no such field has
      // ever been found/mapped in this codebase. This may be correct (a
      // Pionex futures grid bot's own real TP/SL genuinely might just BE
      // its configured top/bottom range) or it may mean a real field is
      // being missed entirely - dumping one full raw order once, verbatim,
      // is the only way to settle this with evidence instead of guessing.
      if (!_loggedRawOrderSample && orders.isNotEmpty) {
        _loggedRawOrderSample = true;
        logger.log('RAW ORDER SAMPLE (one-time, for TP/SL field audit): ${jsonEncode(orders.first)}');
      }
      // Diagnostic added 2026-09-10, one-time (per the user: "why still i
      // can see initial investment for all recycled bots 5$ but not the
      // recycled money"). GridsTable's "Initial investment" column reads
      // GridBot.initialInvestment, which is Pionex's own reported
      // `initUsdtInvestment` for that specific running bot - this dumps
      // that exact field, per bot, tagged by symbol, so it can be compared
      // directly against this same bot's own "RECYCLE X: using reinvested
      // amount Y" log line to settle whether Pionex is genuinely reporting
      // the recycled amount back or something else (e.g. always the
      // original flat default).
      if (!_loggedInvestmentSample) {
        _loggedInvestmentSample = true;
        for (final raw in orders) {
          final data = (raw['buOrderData'] as Map?)?.cast<String, dynamic>();
          if (data == null) continue;
          logger.log(
            'INVESTMENT SAMPLE ${raw['base']}: initUsdtInvestment='
            '${data['initUsdtInvestment']} usdtInvestment='
            '${data['usdtInvestment']} quoteInvestment='
            '${data['quoteInvestment']} extraMargin=${data['extraMargin']}',
          );
        }
      }
      if (!_prevPionexHealthy) {
        logger.log(
          'PIONEX RECOVERED: connection restored - scheduling immediate full checkup',
        );
        _healthRecoveryPending = true;
        _prevPionexHealthy = true;
      }
      final runningIds = <String>{};
      final interruptedIds = <String>{};
      _activeGridsById.clear();
      for (final raw in orders) {
        final buOrderId =
            (raw['buOrderId'] ?? (raw['buOrderData'] as Map?)?['buOrderId'])
                ?.toString();
        final bot = GridBot.fromPionexOrder(
          raw,
          appInitiated: createdBots.isAppInitiated(buOrderId),
          widenApplied: widenApplied.isWidenApplied(buOrderId),
        );
        runningIds.add(bot.buOrderId);
        if (bot.isManuallyInterrupted) interruptedIds.add(bot.buOrderId);
        _activeGridsById[bot.buOrderId] = bot;
      }

      for (final id in createdBots.listAppBots()) {
        if (runningIds.contains(id) && !interruptedIds.contains(id)) continue;
        final wasInterrupted = interruptedIds.contains(id);
        if (wasInterrupted) {
          if (_manualInterruptAcknowledged.contains(id)) {
            // Already gave the one-time notice - still manual, not yet
            // really closed. Keep silently watching, no re-log/re-record.
            continue;
          }
          final snapshot = _activeGridsById[id];
          if (snapshot != null) _interruptedBotSnapshot[id] = snapshot;
          _manualInterruptAcknowledged.add(id);
        }
        final why = wasInterrupted
            ? 'manually paused or being canceled'
            : 'no longer running';
        logger.log(
          wasInterrupted
              ? 'MANUAL INTERRUPT DETECTED: app bot $id $why - still tracking it for its eventual real close (created-bots list untouched, Pionex untouched)'
              : 'MANUAL INTERRUPT DETECTED: app bot $id $why - forgetting it (created-bots list only, Pionex untouched)',
        );
        var bot = _activeGridsById[id] ?? _interruptedBotSnapshot[id];
        // Real gap fixed 2026-09-27, real-money, per the user's own direct
        // question ("why i am need to push you to check this ... why app
        // is not having self healing system?"): a bot cancelled entirely
        // outside this app's own tracking (confirmed live: a direct Pionex
        // cancel for XRP, done from outside the running engine) has NO
        // snapshot in EITHER `_activeGridsById` (just refreshed fresh from
        // Pionex, which no longer lists it) or `_interruptedBotSnapshot`
        // (only ever populated for a `wasInterrupted` bot, not a genuinely
        // gone one) - `bot` stayed null, so `base` stayed null too, and the
        // ENTIRE `if (bot != null)` block below - including the CRITICAL
        // `risk.closePosition` call further down - silently never ran at
        // all. Confirmed live: `GATE BLOCKED grid for XRPUSDT: Max
        // positions ... 1/1` persisted for minutes even though the grid was
        // genuinely gone, only self-healing via a full engine restart's own
        // one-time RiskGate resync. Scoped to the genuine-termination case
        // only (`!wasInterrupted`) - a merely-paused bot might still be
        // running, so there is nothing to recover here for that case, same
        // conservative reasoning already used throughout this block.
        if (bot == null && !wasInterrupted) {
          try {
            final raw = await pionex.getBotOrderByBuOrderId(id);
            if (raw != null) {
              bot = GridBot.fromPionexOrder(
                raw,
                appInitiated: true,
                widenApplied: widenApplied.isWidenApplied(id),
              );
            }
          } catch (e) {
            logger.log(
              'RECONCILE $id: no local snapshot, and the fallback Pionex lookup failed too ($e) - cannot recover this bot\'s close bookkeeping (including its RiskGate slot).',
              level: 'ERROR',
            );
          }
        }
        String? base;
        if (bot != null) {
          // Bug fixed 2026-09-10, live: `bot.base` is Pionex's own raw
          // futures base, which always carries a ".PERP" suffix (e.g.
          // "GALA.PERP") - confirmed live via logs/state.json showing
          // open_positions stuck at 1 for GALAUSDT/HBARUSDT with zero real
          // bots running for either: `risk.closePosition('${base}USDT')`
          // below was building "GALA.PERPUSDT", a symbol RiskGate never
          // had an entry for, silently missing the real "GALAUSDT" key
          // forever - the exact same class of leak as the two already
          // documented and "never regress this" flagged (§18 item 20),
          // just via a symbol-format mismatch instead of a missing call.
          // Three OTHER places in this codebase already strip this same
          // suffix (line ~482's _normalizeBase, ~2769, and
          // engine_control_repository.dart:235) - this call site and the
          // fallback branch below were the two that got missed.
          base = bot.base.replaceAll(
            RegExp(r'\.PERP$', caseSensitive: false),
            '',
          );
          // Bug fixed 2026-09-11, per the user ("confirm the app pulls the
          // p&l from pionex after bot close"): `bot` here is whatever
          // `_activeGridsById` last had for this id - for the `terminated`
          // case (wasInterrupted == false, "no longer running" means THIS
          // fresh listing didn't even see it anymore), that's necessarily a
          // STALE snapshot from an earlier pass, not a fresh read at the
          // moment it actually stopped - the exact same "recorded P/L
          // doesn't match Pionex's real settled total" bug already fixed
          // everywhere else. Re-reads live now, same as the auto-close and
          // Stop paths. Skipped for `convertedToManual` (wasInterrupted ==
          // true) - that bot may only be PAUSED, not actually closed, so a
          // live read there risks the exact same "still-running snapshot
          // recorded as if final" problem "Last" had.
          double? freshPnl;
          if (!wasInterrupted) {
            try {
              // Polls for the SETTLED value (see _getSettledGridPnl's doc)
              // rather than a single immediate read - this figure feeds
              // both the history record below AND the recycled investment
              // further down, so both get the accurate number instead of
              // the recycle amount silently using a stale pre-settlement
              // read.
              freshPnl = await _getSettledGridPnl(bot.buOrderId);
            } catch (e) {
              logger.log(
                'MANUAL INTERRUPT $id: getGridPnl re-read failed ($e) - using the last-known snapshot instead.',
              );
            }
          }
          final reconcileCategory =
              botCategories.categoryOf(bot.buOrderId) ?? AutoCategory.oneHour;
          // Pionex's own real close reason (2026-09-20, per the user - see
          // `_reconciledCloseReason`'s doc comment) - fetched once here,
          // BEFORE recording history, so the History card shows the
          // specific reason instead of the old generic "No longer running
          // on Pionex."; the SL re-ignite check further below reuses this
          // exact same read instead of fetching it again separately.
          Map<String, dynamic>? closedRecord;
          String? reasonBy;
          if (!wasInterrupted) {
            try {
              closedRecord = await pionex.getBotOrderByBuOrderId(
                bot.buOrderId,
              );
              reasonBy =
                  ((closedRecord?['buOrderData'] as Map?)?['reasonBy'] ??
                          closedRecord?['reasonBy'])
                      ?.toString();
            } catch (e) {
              logger.log(
                'RECONCILE $id: could not read the real close reason ($e) - history will show a generic reason.',
              );
            }
          }
          // Entry-signal record: this close isn't signal-driven (real
          // Pionex TP/SL/liquidation/manual cancel), so only the OPEN half
          // is ever available here - attach it if this bot has one on
          // file, and only retire the record on a genuine termination (a
          // "converted to manual" bot is still running).
          final entrySignal = entrySignalStore.recordFor(bot.buOrderId);
          if (!wasInterrupted) entrySignalStore.forget(bot.buOrderId);
          _recordHistory(
            BotHistoryEntry.fromBot(
              bot,
              kind: wasInterrupted
                  ? BotHistoryKind.convertedToManual
                  : BotHistoryKind.terminated,
              detail: wasInterrupted
                  ? 'Paused or being canceled directly in Pionex/TradingView - the app stopped tracking it.'
                  : _withTerminationContext(
                      _reconciledCloseReason(bot.buOrderId, reasonBy),
                      base,
                      reconcileCategory,
                      realizedProfit: freshPnl,
                    ),
              realizedProfitOverride: freshPnl,
              category: reconcileCategory,
            ).withEntrySignal(
              openSignalType: entrySignal?.open.type,
              openSignalZone: entrySignal?.open.zone,
              openSignalValue: entrySignal?.open.value,
              openSignalAt: entrySignal?.open.at,
              stopReason: wasInterrupted
                  ? null
                  : _stopReasonFor(bot.buOrderId, reasonBy),
            ),
          );
          // Recycle the investment forward (2026-09-19, per the user: "the
          // recycled money is not accurate... if xrp started with 5$ then
          // it closed with P&L=0.3, the initial investment for the next bot
          // should be 5.3$") - this exact "old + P/L" computation already
          // existed for the OPPOSITE-SIGNAL close path
          // (`_nextInvestmentByPair[entryKey] = recycled`, further down in
          // this file) but was NEVER wired into THIS path - a bot closed by
          // Pionex's own real TP/SL (which is now the dominant way an auto
          // bot ends, since today's ratchet feature arms a real TP/SL on
          // every one of them) never had its P&L carried forward at all;
          // the next bot on that pair silently fell back to the flat
          // default investment instead of compounding. Only applies to a
          // genuine termination, never a mere pause/manual-interrupt (a
          // "converted to manual" bot may still be running - its capital
          // isn't actually freed to reinvest).
          if (!wasInterrupted && freshPnl != null) {
            final entryKey = '${_gridKey(base)}|${reconcileCategory.wireValue}';
            final entry = _openEntryByPair[entryKey];
            if (entry != null) {
              // Bug fixed 2026-09-24, per the user: "check why money is
              // not recycled in sll?" - `entry.investment` is the ORIGINAL
              // full budget requested at open time (e.g. TRX's real $8),
              // fixed forever - it never reflected any later top-up the
              // +200% Stop Loss Lock investment ratchet added via
              // `investInFuturesGrid` (which only ever grows
              // `bot.actualInvestment`, the "actual"/deployed slice of that
              // budget - `bot.extraMargin` is the untouched reserve
              // slice; actual+extraMargin together is the equivalent
              // whole-budget figure `entry.investment` represents). Using
              // `entry.investment` alone therefore silently dropped every
              // SLL-added dollar from the recycled amount the moment the
              // bot finally closed. Now uses the live bot's real current
              // total (actual+margin) when available, falling back to the
              // original entry investment only if that live data is
              // missing.
              final liveTotal =
                  (bot.actualInvestment != null && bot.extraMargin != null)
                  ? bot.actualInvestment! + bot.extraMargin!
                  : null;
              final baseInvestment = liveTotal ?? entry.investment;
              final recycled = _roundTo2dp(
                (baseInvestment + freshPnl).clamp(0, double.infinity),
              );
              _nextInvestmentByPair[entryKey] = recycled;
              _persistPendingInvestment(base, reconcileCategory, recycled);
              logger.log(
                'RECYCLE $id: closed via Pionex-side reconciliation with P/L=$freshPnl USDT '
                '(base investment=$baseInvestment${liveTotal != null ? ' [live actual+margin]' : ' [original entry, no live snapshot]'}) '
                '- next investment=$recycled',
              );
            }
          }
          // Opposite-direction re-entry on a raw -50% baseline SL hit
          // (2026-09-18, per the user - see _reigniteOpposite's doc
          // comment for the full rationale). Gated on:
          //  - a genuine termination, not a manual pause (!wasInterrupted,
          //    already established by this branch existing at all)
          //  - Pionex's own real close reason genuinely being the loss
          //    stop, not a take-profit hit, manual cancel, or liquidation
          //  - the ratchet never having escalated past the baseline for
          //    this bot (highestThreshold still 0) - a RATCHETED SL hit
          //    (a profit-lock giving back gains) does NOT mean the
          //    direction was wrong, per the user's explicit confirmation.
          //  - the bot was NEVER Stop Loss Lock-managed (bug fixed
          //    2026-09-24: `tpSlRatchet.highestThreshold` never updates for
          //    an SLL-tagged bot at all - the normal ladder is fully
          //    disabled for them - so it always read 0 and satisfied this
          //    branch's condition even when the real cause was a
          //    profitable SLL-locked SL, e.g. +140%, not a genuine
          //    "direction was wrong" raw -50% loss. SLL-managed bots now
          //    have their own dedicated branch below instead.)
          final wasStopLossLockManaged =
              stopLossLockState.lockedUsd(bot.buOrderId) != null;
          if (!wasInterrupted &&
              bot.appInitiated &&
              bot.trend != null &&
              !wasStopLossLockManaged) {
            // Reuses the `reasonBy` already fetched above (for the History
            // detail text) instead of fetching it again - 2026-09-20
            // dedup, same real value either way.
            final highestThreshold = tpSlRatchet.highestThreshold(
              bot.buOrderId,
            );
            if (highestThreshold == 0 && reasonBy == 'loss_stop') {
              final oppositeDirection = bot.trend == GridDirection.long
                  ? GridDirection.short
                  : GridDirection.long;
              final reigniteSymbol = '${base}USDT'.toUpperCase();
              unawaited(
                _reigniteOpposite(
                  reigniteSymbol,
                  reconcileCategory,
                  oppositeDirection,
                ).catchError((e) {
                  logger.log(
                    'SL RE-IGNITE $reigniteSymbol[${reconcileCategory.label}] failed: $e',
                    level: 'ERROR',
                  );
                }),
              );
            }
          }
          // The Stop Loss Lock "hesitation zone" forced-opposite-reignite
          // (2026-09-24) was RETIRED 2026-09-25, per the user's exact spec
          // reworking the primary open/close rule: since a tagged bot can
          // now be closed directly by the normal signal rule too, forcing
          // a specific direction on top of that became unnecessary
          // complexity - the next bot's direction is simply decided by
          // whichever confirmed signal the normal rule sees next, exactly
          // like any other base recycling (per the user: "direction of
          // signal according to new rule whatever the closed trigger
          // scenario was").
        } else {
          final fallback = _openEntryByPair.entries
              .cast<MapEntry<String, OpenEntry>?>()
              .firstWhere((e) => e?.value.buOrderId == id, orElse: () => null);
          // Same fix as the `bot != null` branch above - `fallback.key` is
          // built from `_gridKey`/`_normalizeBase`, which always carries
          // ".PERP" (e.g. "GALA.PERP/USDT|ONE_HOUR"); `_baseOf` alone
          // doesn't strip it since it only splits on ':'/'/'/'_' and
          // removes a literal "USDT" substring.
          base = fallback == null
              ? null
              : _baseOf(
                  fallback.key,
                ).replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '');
          // Bug fixed 2026-09-11, per the user ("all history bots should
          // have p/l .. if not .. pull this data from pionex using bot
          // id"): this branch (no live Pionex snapshot for this id in
          // _activeGridsById, only the app's own in-memory OpenEntry) used
          // to record NO realizedProfit at all - confirmed live, 2 of 56
          // real closed bots had a null P/L and were silently excluded
          // from the Auto bots card's profit/loss sum entirely (not
          // counted as $0 - just missing). `getGridPnl` searches Pionex's
          // 'running' AND 'finished' order lists by buOrderId, so it can
          // usually still find this bot's real total even though it's no
          // longer in the live active-grids snapshot this reconciliation
          // pass just fetched.
          double? fallbackPnl;
          try {
            // Settled-poll only for a genuine termination (see
            // _getSettledGridPnl's doc) - this value also feeds the
            // recycle amount below; a mere pause/manual-interrupt doesn't
            // recycle anything, so it keeps the fast immediate read
            // instead of adding a needless ~25s wait to every such
            // detection.
            fallbackPnl = wasInterrupted
                ? await pionex.getGridPnl(id)
                : await _getSettledGridPnl(id);
          } catch (e) {
            logger.log(
              'RECONCILE $id: getGridPnl lookup failed ($e) - history entry will have no P/L.',
            );
          }
          // Pionex's own real close reason (2026-09-20) - same fetch as
          // the `bot != null` branch above, see `_reconciledCloseReason`'s
          // doc comment.
          String? fallbackReasonBy;
          if (!wasInterrupted) {
            try {
              final closedRecord = await pionex.getBotOrderByBuOrderId(id);
              fallbackReasonBy =
                  ((closedRecord?['buOrderData'] as Map?)?['reasonBy'] ??
                          closedRecord?['reasonBy'])
                      ?.toString();
            } catch (e) {
              logger.log(
                'RECONCILE $id: could not read the real close reason ($e) - history will show a generic reason.',
              );
            }
          }
          final fallbackCategory = fallback == null
              ? null
              : autoCategoryFromWire(fallback.key.split('|').last);
          // Entry-signal record - same reasoning as the `bot != null`
          // branch's own attach/forget above.
          final fallbackEntrySignal = entrySignalStore.recordFor(id);
          if (!wasInterrupted) entrySignalStore.forget(id);
          _recordHistory(
            BotHistoryEntry(
              id: BotHistoryEntry.newId(),
              ts: DateTime.now(),
              kind: wasInterrupted
                  ? BotHistoryKind.convertedToManual
                  : BotHistoryKind.terminated,
              pairKey: fallback?.key ?? 'unknown',
              base: base ?? 'unknown',
              buOrderId: id,
              // `fallback.key` is this entry's own "GRID_KEY|CATEGORY"
              // key (see `_manageGridPair`'s `entryKey`) - a more
              // reliable category source than `BotCategoryStore` here,
              // since this whole branch exists precisely because the
              // live snapshot for this bot is already gone.
              category: fallbackCategory,
              direction: fallback?.value.direction,
              entryPrice: fallback?.value.entryPrice,
              initialInvestment: fallback?.value.investment,
              realizedProfit: fallbackPnl,
              // entryTime is a TradingView bar time - Unix SECONDS, verified
              // live against status.json's last_candle_time_ms (same
              // convention, misleadingly-named field) rather than assumed.
              startTime: fallback?.value.entryTime == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(
                      fallback!.value.entryTime * 1000,
                    ),
              detail: wasInterrupted
                  ? 'Paused or being canceled directly in Pionex/TradingView - the app stopped tracking it.'
                  : _withTerminationContext(
                      _reconciledCloseReason(id, fallbackReasonBy),
                      base ?? 'unknown',
                      fallbackCategory ?? AutoCategory.oneHour,
                      realizedProfit: fallbackPnl,
                    ),
            ).withEntrySignal(
              openSignalType: fallbackEntrySignal?.open.type,
              openSignalZone: fallbackEntrySignal?.open.zone,
              openSignalValue: fallbackEntrySignal?.open.value,
              openSignalAt: fallbackEntrySignal?.open.at,
              stopReason: wasInterrupted
                  ? null
                  : _stopReasonFor(id, fallbackReasonBy),
            ),
          );
          // Same recycle fix as the `bot != null` branch above - this rarer
          // fallback (no live/interrupted snapshot at all, only the app's
          // own in-memory OpenEntry survived) still has everything needed
          // (`fallback.key` IS the entryKey itself, `fallback.value
          // .investment` is the old amount) to carry the real P&L forward
          // into the next bot's investment instead of silently falling
          // back to the flat default.
          if (!wasInterrupted && fallback != null && fallbackPnl != null) {
            final recycled = _roundTo2dp(
              (fallback.value.investment + fallbackPnl).clamp(
                0,
                double.infinity,
              ),
            );
            _nextInvestmentByPair[fallback.key] = recycled;
            _persistPendingInvestment(
              base ?? 'unknown',
              autoCategoryFromWire(fallback.key.split('|').last) ??
                  AutoCategory.oneHour,
              recycled,
            );
            logger.log(
              'RECYCLE $id: closed via Pionex-side reconciliation (fallback path) with P/L=$fallbackPnl USDT - next investment=$recycled',
            );
          }
        }
        // CRITICAL FIX (2026-09-09): this reconciliation path - the one that
        // fires for a grid closed by hitting its own TP/SL directly on
        // Pionex (the normal way most of these bots actually end, since
        // nothing here initiated the close ourselves) - never called
        // risk.closePosition, unlike the two explicit engine-initiated
        // close paths elsewhere in this file. RiskGate's own "never
        // regress this" warning about the original engine's multi-week
        // open_positions leak had regressed here: confirmed live via
        // logs/state.json showing open_positions stuck at 1 for 7 symbols
        // (DOGEUSDT, XRPUSDT, ETHUSDT, BCHUSDT, DOTUSDT, XLMUSDT, OPUSDT)
        // with zero real bots left running for any of them - each one
        // permanently GATE BLOCKED ("Max positions for X: 1/1") on every
        // future open attempt, in any category, forever, until the app
        // was restarted (which starts state.json fresh) or someone noticed
        // and manually intervened. Only decremented for a genuine
        // termination (`!wasInterrupted`) - a merely paused/being-canceled
        // bot might still hold a real open position, so that case is left
        // alone deliberately (same conservative reasoning already used for
        // history's `convertedToManual` vs `terminated` split above).
        if (!wasInterrupted && base != null) {
          risk.closePosition(
            '${base}USDT'.toUpperCase(),
            botCategories.categoryOf(id) ?? AutoCategory.oneHour,
          );
        }
        // REVERTED (2026-09-10, per the user - recycle-reopen restored):
        // the 2026-09-10 "MANDATORY" change above this comment made this
        // unconditional, on the reasoning that autonomous reopening was
        // permanently forbidden. The user has since clarified the actual
        // rule: a BRAND-NEW base the app has never opened still requires an
        // explicit Start (unchanged, still enforced by createBlocked in
        // _runCycle's per-pair loop and in _pairActionStart being the only
        // paths that can ever ADD a base here in the first place - see
        // addBase's call sites), but a base that's already the app's
        // ongoing responsibility (this list) should keep recycling through
        // close-then-reopen on its own, exactly like the original
        // close-then-reopen spec this file already documented elsewhere
        // (see the addBase call in the create path below). Only an
        // explicit "Last" retirement should take a base off this list now -
        // back to the pre-2026-09-10 behavior, restored for BOTH removeBase
        // sites (this reconciliation path for a self-closed/TP-SL-hit bot,
        // and the opposite-signal close branch in _manageGridPair).
        // All of the above (risk/retired/forgetBot) only ever applies to a
        // GENUINE termination - a bot on its first interruption still
        // falls through this far (to record its one-time history entry),
        // but must NOT be forgotten here, or the next pass would never
        // see it again to catch its eventual real close. An ALREADY-
        // acknowledged, still-interrupted bot never reaches this line at
        // all - it `continue`d right after the acknowledgment check above.
        if (!wasInterrupted) {
          final terminatedCategory =
              botCategories.categoryOf(id) ?? AutoCategory.oneHour;
          if (base != null && retired.isRetiredBase(base, terminatedCategory)) {
            autoManagedByCategory[terminatedCategory]!.removeBase(base);
          }
          createdBots.forgetBot(id);
          tpSlRatchet.forget(id);
          stopLossLockState.forget(id);
          _stopLossLockSlCleared.remove(id);
          _interruptedBotSnapshot.remove(id);
          _manualInterruptAcknowledged.remove(id);
        }
      }
      for (final id in interruptedIds) {
        final bot = _activeGridsById[id];
        if (bot != null) {
          _activeGridsById[id] = bot.copyWith(appInitiated: false);
        }
      }
      _openEntryByPair.removeWhere((pairKey, entry) {
        final id = entry.buOrderId;
        if (id == null) return false;
        final stillActive =
            runningIds.contains(id) && !interruptedIds.contains(id);
        if (!stillActive)
          logger.log(
            'CLEAR STALE ENTRY $pairKey: recorded bot $id not actively running - clearing open-entry',
          );
        return !stillActive;
      });

      logger.log(
        'ACTIVE GRIDS: ${_activeGridsById.isEmpty ? '(none)' : _activeGridsById.values.map((b) => '${b.pairKey}${b.appInitiated ? ' (app ' : ' (manual '}${b.buOrderId})').join(', ')}',
      );
      // One-time RiskGate resync (2026-09-18, per the user's "max per
      // symbol per interval" fix) - `logs/state.json`'s `open_positions`
      // was keyed by bare symbol before today; RiskGate now keys it by
      // symbol+category instead, so an old entry like "XRPUSDT": 1 would
      // otherwise just go permanently unmatched (and unmatched forever,
      // since nothing else ever writes the old bare-symbol format again),
      // silently resetting every symbol's real, currently-open count to
      // zero the moment this deploy runs - not a decrement/increment bug,
      // a one-time key-format migration. Rebuilt here, once, straight from
      // the real, just-refreshed Pionex snapshot (source of truth per PRD
      // §10 rule 13) rather than trying to guess-migrate the old keys,
      // which had no category information to migrate FROM in the first
      // place. Runs exactly once per process lifetime - after this,
      // RiskGate's own openPosition/closePosition calls stay correctly
      // incremental on their own, same as always.
      if (!_riskGateResynced) {
        _riskGateResynced = true;
        final openPositions = <(String, AutoCategory)>[
          for (final bot in _activeGridsById.values)
            if (bot.appInitiated)
              (
                '${bot.base.replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '')}${bot.quote}'
                    .toUpperCase(),
                botCategories.categoryOf(bot.buOrderId) ?? AutoCategory.oneHour,
              ),
        ];
        risk.resetTo(openPositions);
        logger.log(
          'RISK GATE RESYNC (one-time, symbol+category key migration): $openPositions',
        );
      }
    } catch (e) {
      logger.log('Grid list failed: $e');
      if (_prevPionexHealthy)
        logger.log(
          'PIONEX DOWN: connection failed - will recheck on next poll',
        );
      _prevPionexHealthy = false;
    }
  }

  /// Stop Loss Lock (rewritten 2026-11-09, per the user - rules in
  /// `sll_rules.dart`): mandatory for every running Auto bot, no toggle,
  /// runs every 5 seconds. Manual bots are never touched. Reads Pionex's
  /// active bots fresh on every pass so investment / extra margin / position
  /// are never stale after a top-up.
  Future<void> _runSllSweep() async {
    // Auto off = the engine does nothing at all (per the user, 2026-11-08).
    if (_forceStopActive()) return;
    if (!pionex.available || _sllRunning) return;
    _sllRunning = true;
    try {
      final orders = await pionex.getActiveGrids();
      for (final raw in orders) {
        final id =
            (raw['buOrderId'] ?? (raw['buOrderData'] as Map?)?['buOrderId'])
                ?.toString();
        if (id == null || !createdBots.isAppInitiated(id)) continue;
        final bot = GridBot.fromPionexOrder(raw, appInitiated: true);
        if (bot.isManuallyInterrupted) continue;
        _ensureOnAutoList(bot);
        try {
          await _sllCheck(bot);
        } catch (e) {
          logger.log(
            'SLL ${bot.pairKey} (${bot.buOrderId}) failed: $e',
            level: 'ERROR',
          );
        }
      }
    } catch (e) {
      logger.log('SLL: could not read active bots: $e', level: 'ERROR');
    } finally {
      _sllRunning = false;
    }
  }

  bool _sllRunning = false;

  /// Every running Auto bot follows the same rules (per the user,
  /// 2026-11-11): its pair is always on Auto's list, so the hourly hybrid
  /// check and Close A/B cover it. The app keeps this true by itself - a
  /// running Auto bot found off the list is put back on it.
  void _ensureOnAutoList(GridBot bot) {
    final category =
        botCategories.categoryOf(bot.buOrderId) ?? AutoCategory.oneHour;
    final base = bot.base
        .toUpperCase()
        .replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '');
    final store = autoManagedByCategory[category];
    if (store == null || store.isAutoManaged(base)) return;
    store.addBase(base);
    logger.log(
      'AUTO LIST: ${bot.pairKey} (${bot.buOrderId}) is a running Auto bot but '
      'was not on Auto\'s list - added, so the same rules apply to it.',
    );
  }

  /// Last time a still-failing booked top-up was logged, per bot (once a
  /// minute, not every 5s).
  final Map<String, DateTime> _sllOwedLoggedAt = {};

  /// The investment a top-up is expected to reach, and when it was sent -
  /// no further top-up on that bot until Pionex reports it (or 60s pass),
  /// so a stale read can never move the same money twice.
  final Map<String, ({double expectedActual, DateTime at})> _sllPendingTopUp =
      {};

  Future<void> _sllCheck(GridBot bot) async {
    final id = bot.buOrderId;
    final bareBase = bot.base
        .toUpperCase()
        .replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '');

    // 1. Start of the trade, once per bot (per the user, 2026-11-09): TP at
    //    the range top for a long / bottom for a short, then never touched;
    //    SL blank until the $50 lock. An SL that SLL already locked is kept.
    if (!stopLossLockState.started(id)) {
      final tp = switch (bot.trend) {
        GridDirection.long => bot.top,
        GridDirection.short => bot.bottom,
        null => null,
      };
      if (tp == null) {
        logger.log(
          'SLL ${bot.pairKey} ($id): direction or range not known yet - '
          'setting TP on the next pass.',
        );
        return;
      }
      final keepLock = stopLossLockState.lockedUsd(id) != null;
      await pionex.updateTriggerProfitLoss(
        buOrderId: id,
        profitStopType: 'price',
        profitStopValue: '$tp',
        lossStopType: keepLock ? null : 'profit_amount',
        lossStopValue: keepLock ? null : '',
      );
      stopLossLockState.markStarted(id);
      logger.log(
        'SLL ${bot.pairKey} ($id): TP set to $tp (${bot.trend!.wireValue} range '
        'edge)${keepLock ? '' : ', SL blank'}.',
      );
    }

    final price = await pionex.getTickerPrice('${bareBase}_USDT_PERP');

    // A top-up whose add-investment step failed: the money is still booked
    // for this bot and is retried every pass until it is added (per the
    // user, 2026-11-09). No new top-up until then.
    final owed = stopLossLockState.owed(id);
    if (owed != null && owed > 0) {
      if (price == null) return;
      try {
        await pionex.investInFuturesGrid(
          buOrderId: id,
          openPrice: price,
          quoteInvestment: owed,
        );
        stopLossLockState.setOwed(id, 0);
        _sllPendingTopUp[id] = (
          expectedActual: (bot.actualInvestment ?? 0) + owed,
          at: DateTime.now(),
        );
        logger.log(
          'SLL ${bot.pairKey} ($id): booked \$${owed.toStringAsFixed(2)} added to '
          'the investment on retry.',
        );
      } catch (e) {
        final last = _sllOwedLoggedAt[id];
        if (last == null ||
            DateTime.now().difference(last) > const Duration(minutes: 1)) {
          _sllOwedLoggedAt[id] = DateTime.now();
          logger.log(
            'SLL ${bot.pairKey} ($id): booked \$${owed.toStringAsFixed(2)} still '
            'not added to the investment ($e) - retrying every 5s.',
            level: 'ERROR',
          );
        }
      }
      return;
    }

    final live = bot.copyWith(currentPrice: price);
    final profit = live.profitAmount;
    final pct = live.profitPercent;
    final actual = bot.actualInvestment;
    if (profit == null || pct == null || actual == null || actual <= 0) return;

    // 2. P&L >= 200%: move extra margin into the investment.
    final pending = _sllPendingTopUp[id];
    if (pending != null &&
        (actual >= pending.expectedActual - 0.005 ||
            DateTime.now().difference(pending.at) > const Duration(seconds: 60))) {
      _sllPendingTopUp.remove(id);
    }
    if (pct >= 200 && !_sllPendingTopUp.containsKey(id)) {
      final x = sllTopUpAmount(
        actualInvestment: actual,
        extraMargin: bot.extraMargin ?? 0,
      );
      if (x > 0 && price != null) {
        await _sllTopUp(bot, x, price, pct);
        return; // re-read fresh numbers on the next pass
      }
    }

    // 3. P&L >= $50: SL at P&L - $20 ($10 steps), only ever up. Set on
    //    Pionex as a $ trigger (`profit_amount`, the same type the gear
    //    menu's TP/SL editor uses for P&L in $), per the user.
    final stored = stopLossLockState.lockedUsd(id);
    final fresh = sllLockUsd(profit);
    if (fresh == null || (stored != null && fresh <= stored)) return;
    // $ trigger only (per the user) - if Pionex refuses it, nothing else is
    // tried; the lock is not recorded, so the next pass tries again.
    try {
      await pionex.updateTriggerProfitLoss(
        buOrderId: id,
        lossStopType: 'profit_amount',
        lossStopValue: fresh.toStringAsFixed(2),
      );
    } catch (e) {
      logger.log(
        'SLL ${bot.pairKey} ($id): Pionex refused the \$${fresh.toStringAsFixed(0)} '
        'SL trigger ($e) - trying again next pass.',
        level: 'CRITICAL',
      );
      return;
    }
    stopLossLockState.recordLock(id, fresh);
    logger.log(
      'SLL ${bot.pairKey} ($id): P&L=\$${profit.toStringAsFixed(2)} - SL set to '
      '+\$${fresh.toStringAsFixed(0)}.',
    );
  }

  /// Moves [x] USDT from this bot's extra margin into its investment:
  /// reduceMargin (to free balance), then invest_in. If the invest step
  /// fails, the money is put back as margin.
  Future<void> _sllTopUp(GridBot bot, double x, double price, double pct) async {
    final id = bot.buOrderId;
    final actual = bot.actualInvestment!;
    final check = await pionex.checkReduceMargin(buOrderId: id, amount: x);
    final maxAmount = double.tryParse('${check['maxAmount']}') ?? 0;
    if (check['checkResult'] != true || maxAmount <= 0) {
      logger.log(
        'SLL ${bot.pairKey} ($id): P&L=${pct.toStringAsFixed(1)}% but Pionex '
        'allows no margin reduction now (max $maxAmount) - retrying next pass.',
      );
      return;
    }
    final amount = maxAmount < x ? maxAmount : x;
    await pionex.reduceMargin(buOrderId: id, amount: amount);
    await Future<void>.delayed(const Duration(seconds: 3));
    try {
      await pionex.investInFuturesGrid(
        buOrderId: id,
        openPrice: price,
        quoteInvestment: amount,
      );
    } catch (e) {
      // Per the user (2026-11-09): the money stays booked for this bot and
      // is retried every pass until it is added - never put back as margin.
      stopLossLockState.setOwed(id, amount);
      logger.log(
        'SLL ${bot.pairKey} ($id): adding \$${amount.toStringAsFixed(2)} to the '
        'investment failed ($e) - kept booked for this bot, retrying every 5s.',
        level: 'ERROR',
      );
      return;
    }
    _sllPendingTopUp[id] = (
      expectedActual: actual + amount,
      at: DateTime.now(),
    );
    logger.log(
      'SLL ${bot.pairKey} ($id): P&L=${pct.toStringAsFixed(1)}% >= 200% - moved '
      '\$${amount.toStringAsFixed(2)} from extra margin to investment '
      '(\$${actual.toStringAsFixed(2)} -> \$${(actual + amount).toStringAsFixed(2)}).',
    );
  }

  /// "Never filled" zero-position safety check (2026-09-27, per the user:
  /// "i want you to change the cycle per each interval to be 3 min ...
  /// even if the interval is 3m/5m/15m/1H/1D"). Previously lived inline in
  /// [_runAutoCheckup], gated by that category's own candle boundary - for
  /// a 1H-tagged bot that meant up to 2 hours before a genuinely
  /// never-filled grid got cancelled. Now a fixed 3-minute sweep,
  /// completely independent of category: every app-initiated grid still
  /// showing zero real Pionex position (`positionSize`) on its SECOND
  /// consecutive 3-minute check gets cancelled outright - nothing filled,
  /// so there's no position to unwind and no P/L to recycle, just a real
  /// Pionex cancel. Needs no chart/CDP access at all (pure Pionex REST +
  /// local state), so unlike [_runStopLossLockSweep] it never has to yield
  /// the chart to anything.
  ///
  /// Per the user ("yes .. and the bot will be recycled if not tagged with
  /// last"): deliberately does NOT call `retired.addRetiredBases(...)`
  /// (unlike the old inline version did) - the base simply falls back to
  /// its normal auto-managed list with no running grid, so the waiting
  /// engine picks it up and recycles it again on the very next pass,
  /// exactly like any other close. It only stays unfilled-and-idle if the
  /// user separately tagged that exact (base, category) Last, same gate
  /// every other recycle path already respects.
  Future<void> _runNeverFilledSweep() async {
    // Auto off = the engine does nothing at all (per the user, 2026-11-08).
    if (_forceStopActive()) return;
    if (!pionex.available) return;
    // Safe, idempotent, already called from half a dozen other sites in
    // this file (see `_runStopLossLockSweep`'s own copy of this same
    // comment) - this sweep runs on its own independent 3-minute timer, so
    // it can't assume some other track already refreshed recently.
    await _refreshActiveGrids();
    for (final grid in _activeGridsById.values.toList()) {
      if (!grid.appInitiated) continue;
      final pnlCheckId = grid.buOrderId;
      final hasMoved = (grid.positionSize ?? 0) != 0;
      if (hasMoved) {
        _pnlCheckCycleCount.remove(pnlCheckId);
        continue;
      }
      final seen = (_pnlCheckCycleCount[pnlCheckId] ?? 0) + 1;
      if (seen < 2) {
        _pnlCheckCycleCount[pnlCheckId] = seen;
        continue;
      }
      _pnlCheckCycleCount.remove(pnlCheckId);
      final category = botCategories.categoryOf(pnlCheckId) ?? AutoCategory.oneHour;
      final symbol = grid.tickerSymbol;
      final base = _baseOf(symbol);
      final tag = '[${category.label}]';
      logger.log(
        'PNL CHECK $symbol$tag: buOrderId=$pnlCheckId still shows zero position after $seen 3-minute checks - '
        'not working, cancelling.',
        level: 'ERROR',
      );
      try {
        await pionex.cancelFuturesGrid(buOrderId: pnlCheckId);
        createdBots.forgetBot(pnlCheckId);
        botCategories.forget(pnlCheckId);
        tpSlRatchet.forget(pnlCheckId);
        stopLossLockState.forget(pnlCheckId);
        _stopLossLockSlCleared.remove(pnlCheckId);
        _activeGridsById.remove(pnlCheckId);
        risk.closePosition(symbol, category);
        _openEntryByPair.remove('${_gridKey(base)}|${category.wireValue}');
        final neverFilledEntrySignal = entrySignalStore.recordFor(pnlCheckId);
        entrySignalStore.forget(pnlCheckId);
        _recordHistory(
          BotHistoryEntry(
            id: BotHistoryEntry.newId(),
            ts: DateTime.now(),
            kind: BotHistoryKind.terminated,
            pairKey: _gridKey(base),
            base: base,
            buOrderId: pnlCheckId,
            category: category,
            direction: grid.trend ?? GridDirection.long,
            entryPrice: grid.entryPrice ?? 0,
            exitPrice: grid.entryPrice ?? 0,
            initialInvestment: pairInvestments.investmentOf(symbol),
            realizedProfit: 0,
            startTime: grid.startTime ?? DateTime.now(),
            endTime: DateTime.now(),
            detail: _withTerminationContext(
              'Cancelled automatically - zero position after $seen 3-minute checks (never filled).',
              base,
              category,
              realizedProfit: 0,
            ),
          ).withEntrySignal(
            openSignalType: neverFilledEntrySignal?.open.type,
            openSignalZone: neverFilledEntrySignal?.open.zone,
            openSignalValue: neverFilledEntrySignal?.open.value,
            openSignalAt: neverFilledEntrySignal?.open.at,
            stopReason: 'never_filled',
          ),
        );
      } catch (e) {
        logger.log(
          'PNL CHECK $symbol$tag: cancel failed for $pnlCheckId: $e',
          level: 'ERROR',
        );
      }
    }
  }


  Future<List<String>> _readRedList(CdpClient cdp) async {
    WatchlistReading watchlist;
    try {
      watchlist = await readWatchlist(cdp, wantName: _redListName);
    } catch (e) {
      logger.log('RED LIST read failed: $e');
      return List.of(_redListSymbols);
    }
    if (!watchlist.found) {
      logger.log('RED LIST unavailable: ${watchlist.error ?? 'not found'}');
      return List.of(_redListSymbols);
    }
    // NOT gated on yet - live-tested 2026-09-01 and the heuristic
    // false-positived on the watchlist panel's "Add symbol" button (matched
    // as if it were a selected tab), which blocked EVERY Red List read on a
    // live account until reverted. Logging only, for future investigation
    // with a properly-verified selector, same discipline the flag-toggle
    // discovery used - never gate real trading behavior on an unverified
    // DOM heuristic again.
    if (watchlist.activeTabName != null &&
        watchlist.activeTabName != _redListName) {
      logger.log(
        'RED LIST: active-tab heuristic reports "${watchlist.activeTabName}" (informational only, '
        'not currently enforced - see _readRedList).',
      );
    }
    // Per the user (2026-09-06): keep every Red List entry exactly as
    // TradingView names it - no qualifySymbol rebuilding, which forced
    // "BINANCE:" onto every symbol regardless of what's actually listed.
    final named = List<String>.from(watchlist.symbols);
    final prev = List.of(_redListSymbols);
    // Bug fixed 2026-09-15, confirmed live (per the user: "the running
    // trades suddenly has last tag. i did not do that but by itself"):
    // right after a TradingView reconnect ("TV/CDP RECOVERED"), the very
    // first watchlist read came back `found: true` but with ZERO symbols -
    // the DOM panel was present but hadn't finished repopulating its rows
    // yet. That passed the `!watchlist.found` guard above (which only
    // catches a missing/errored panel), so it was trusted as "the user
    // cleared their whole Red List" and cascaded into the mass-retire loop
    // below for all 27 previously-tracked symbols - including marking
    // GALAUSDT's and DOGEUSDT's currently-running auto bots "Last", live,
    // with no user action at all. A genuinely non-empty list dropping to
    // truly empty is trusted from the SECOND consecutive empty read
    // onward (one glitchy read is exactly the failure mode seen; two in a
    // row is far more likely a real, deliberate clear).
    if (named.isEmpty && prev.isNotEmpty) {
      if (!_redListWasEmptyLastRead) {
        _redListWasEmptyLastRead = true;
        logger.log(
          'RED LIST: read came back empty right after a previously non-empty '
          'list (${prev.length} symbols) - treating as a transient/incomplete '
          'read (e.g. right after a reconnect) rather than "everything was '
          'removed"; keeping the previous list for this cycle.',
        );
        return List.of(prev);
      }
      logger.log(
        'RED LIST: read came back empty for a second consecutive cycle - '
        'now trusting it as genuine.',
      );
    } else {
      _redListWasEmptyLastRead = false;
    }
    _redListSymbols = named;
    for (final sym in prev) {
      if (named.contains(sym)) continue;
      final key = _gridKey(_baseOf(sym));
      // Bug fixed 2026-09-11, per the user ("if user removes a pair from
      // the red list and there is currently a running auto bot for it,
      // the app should make this bot Last"): this used to only add to
      // _sessionRetiredPairs - an in-memory, THIS-PROCESS-ONLY skip list
      // that blocks new opens but is invisible in the GUI (the "Last" tag/
      // toggle built this session reads RetiredStore, not this set) and
      // is silently forgotten on every engine restart, letting a
      // supposedly-retired pair recycle-reopen again. A running AUTO bot
      // now gets a real, persistent "Last" mark via RetiredStore - the
      // exact same mechanism the GUI's own Last toggle uses - so it shows
      // the tag, survives restarts, and is undoable the normal way. A
      // manual bot (never touched by the app) or no bot at all still only
      // gets the session-only skip, which is all that's needed there.
      final appGrid = _activeGridsById.values
          .cast<GridBot?>()
          .firstWhere(
            (b) => b?.pairKey == key && b?.appInitiated == true,
            orElse: () => null,
          );
      if (appGrid != null) {
        final base = _baseOf(sym);
        final removedCategory =
            botCategories.categoryOf(appGrid.buOrderId) ?? AutoCategory.oneHour;
        retired.addRetiredBases([(base: base, category: removedCategory)]);
        _recordHistory(
          BotHistoryEntry.fromBot(
            appGrid,
            kind: BotHistoryKind.last,
            detail:
                'Retired — $sym was removed from the Red List while this '
                'auto bot was running; it will finish naturally and never '
                'auto-recreate.',
            category: botCategories.categoryOf(appGrid.buOrderId),
          ),
        );
        logger.log(
          'RED LIST: $sym removed from list - its running auto bot '
          '(${appGrid.buOrderId}) is now marked Last (will finish '
          'naturally, never auto-recreate).',
        );
      } else if (_anyGridForKey(key)) {
        logger.log(
          'RED LIST: $sym removed from list but has an active manual grid - left running, no new trades on it',
        );
      } else {
        logger.log(
          'RED LIST: $sym removed from list - retiring, no further trades on it',
        );
      }
      _sessionRetiredPairs.add(sym);
    }
    logger.log('RED LIST (${named.length}): ${named.join(', ')}');
    return List.of(named);
  }

  Future<double?> _maxLeverageFor(String symbol) async {
    if (!pionex.available) return null;
    try {
      return await pionex.getMaxLeverage(_normalizeBase(_baseOf(symbol)));
    } catch (_) {
      return null;
    }
  }


  /// Last chart-signal time already voice-announced per pair+category
  /// (2026-09-19, per the user) - keyed the same way as
  /// `_openEntryByPair`/`_nextInvestmentByPair` (`base/USDT|CATEGORY`).
  /// In-memory only: a restart re-announcing whatever signal happens to be
  /// current is an acceptable one-time repeat, same tradeoff as
  /// `_lastAutoCandleTs` and every other purely-informational tracker in
  /// this class.
  final Map<String, int> _lastAnnouncedSignalTimeByPair = {};

  /// True (and marks [signalTime] as announced for [entryKey]) only if it
  /// hasn't already been voice-announced. Shared between
  /// [_announceChartSignalIfFresh] (fires from the chart alone, ahead of
  /// any real action) and the real open/close voice triggers elsewhere in
  /// this class, so the SAME underlying signal is never spoken twice just
  /// because both the chart-only detector and the real action happened to
  /// process it in the same pass.
  ///
  /// Bug fixed 2026-09-20, live (per the user: "voice occurs twice for
  /// same trigger" / "3m close ltc... twice") - confirmed in
  /// `trade-start-events.jsonl`: DOTUSDT/OPUSDT/LTCUSDT each had two
  /// identical `stop` events under 2ms apart. Root cause:
  /// `_announceChartSignalIfFresh` (called earlier in `_runAutoCheckup`'s
  /// per-base loop) and the pre-existing real opposite-signal-close code
  /// further down in `_manageGridPair` each independently detected the
  /// SAME opposite signal and each wrote their own `stop` event, since
  /// neither knew about the other. Routing every voice-write through this
  /// one shared gate means whichever fires first wins and the other sees
  /// its own signal.time already covered.
  bool _shouldAnnounceSignal(String entryKey, int signalTime) {
    final last = _lastAnnouncedSignalTimeByPair[entryKey];
    if (last != null && signalTime <= last) return false;
    _lastAnnouncedSignalTimeByPair[entryKey] = signalTime;
    return true;
  }

  /// Speaks a voice alert for a fresh chart signal on a pair+interval the
  /// app is currently watching (waiting to open, or already running) -
  /// per the user's explicit spec (2026-09-19): "app speak only if there
  /// is pair in waiting or currently running in auto... it does not
  /// matter if this trigger has been taking effect in opening/closing
  /// anything in the app... app only speaking about triggers in trading
  /// view according to chart reading for a certain pair in a certain
  /// interval." Deliberately independent of every real-trade gate
  /// (fresh-signal-wait, risk gate, margin, pause) - this only reports
  /// what the CHART shows, not what the app did about it. Reuses the
  /// exact same [TradeStartEvent] shape/file/wording the GUI already
  /// speaks for a genuine open/close (2026-09-17 feature) - per the
  /// user's own example ("app will say: 1 H start btc... it does not
  /// matter if app started btc 1H") the phrasing is identical either way,
  /// so no GUI change is needed at all; only the engine writes an extra
  /// event here, before (and independent of) whatever the real open/close
  /// path further down in `_manageGridPair` decides to do with the same
  /// signal.
  void _announceChartSignalIfFresh(
    String symbol,
    AutoCategory category,
    Worm10Event? confirmedEvent,
  ) {
    if (confirmedEvent == null) return;
    final base = _baseOf(symbol);
    final key = _gridKey(base);
    final entryKey = '$key|${category.wireValue}';
    if (!_shouldAnnounceSignal(entryKey, confirmedEvent.time)) return;
    final direction = worm10EventDirection(confirmedEvent.kind) == TradeDirection.long
        ? GridDirection.long
        : GridDirection.short;
    final existing = _appGridForKey(key, category);
    if (existing != null) {
      // Running - only a signal OPPOSITE the running position's own
      // direction is a meaningful trigger (a same-direction signal on an
      // already-running bot isn't acted on anywhere else in the app
      // either, so it isn't spoken here). Prefers the app's own recorded
      // entry direction, falling back to Pionex's own reported trend for
      // an adopted bot the app never recorded an entry for.
      final runningDirection =
          _openEntryByPair[entryKey]?.direction ?? existing.trend;
      if (runningDirection == null || direction == runningDirection) return;
      // Speaks BOTH halves of the same chart event (2026-09-19, per the
      // user, live DOTUSDT example: a fresh signal opposite a running
      // position closed a short on a buy signal, and the app's own
      // recycle logic immediately reopened DOT long on that EXACT same
      // signal moments later - "this point is start as well ... after
      // close, app should speak start"). The close is written first, the
      // paired start second, matching the user's own stated order -
      // regardless of whether the app's own gates (margin, risk gate,
      // fresh-signal-wait for a first-ever Start) actually let it reopen,
      // same "chart reading only" principle as everywhere else here.
      storage.appendJsonl(
        storage.tradeStartEventsFile,
        TradeStartEvent(
          id: BotHistoryEntry.newId(),
          ts: DateTime.now(),
          kind: TradeTriggerKind.stop,
          base: base,
          direction: runningDirection,
          category: category,
        ).toJson(),
      );
      storage.appendJsonl(
        storage.tradeStartEventsFile,
        TradeStartEvent(
          id: BotHistoryEntry.newId(),
          ts: DateTime.now(),
          kind: TradeTriggerKind.start,
          base: base,
          direction: direction,
          category: category,
        ).toJson(),
      );
      return;
    }
    // Not currently running - waiting/auto-managed only (this loop already
    // never iterates a base outside this category's auto-managed list) -
    // a fresh signal here is a meaningful "would open" trigger regardless
    // of whether fresh-signal-wait/margin/risk-gate later lets it actually
    // open.
    storage.appendJsonl(
      storage.tradeStartEventsFile,
      TradeStartEvent(
        id: BotHistoryEntry.newId(),
        ts: DateTime.now(),
        kind: TradeTriggerKind.start,
        base: base,
        direction: direction,
        category: category,
      ).toJson(),
    );
  }

  Future<Map<String, dynamic>?> _waitForGridRunning(
    String symbol,
    String buOrderId,
    String pairKey,
  ) async {
    final deadline = DateTime.now().add(CoreConstants.gridPrepareTimeout);
    while (DateTime.now().isBefore(deadline)) {
      Map<String, dynamic>? rec;
      try {
        final running = await pionex.getActiveGrids();
        rec = running.cast<Map<String, dynamic>?>().firstWhere(
          (o) =>
              o?['buOrderId']?.toString() == buOrderId ||
              ((o?['buOrderData'] as Map?)?['buOrderId'])?.toString() ==
                  buOrderId,
          orElse: () => null,
        );
        rec ??= await pionex.getBotOrderByBuOrderId(buOrderId);
      } catch (e) {
        logger.log('PREPARE $symbol: status poll error: $e');
      }
      if (rec != null) {
        final status =
            (rec['status'] ?? (rec['buOrderData'] as Map?)?['status'] ?? '')
                .toString();
        if (RegExp(
          'running|open|active',
          caseSensitive: false,
        ).hasMatch(status)) {
          logger.log(
            'PREPARE $symbol $buOrderId: confirmed RUNNING (status=$status) - launched OK',
          );
          return rec;
        }
      }
      await Future<void>.delayed(CoreConstants.gridPreparePoll);
    }
    // CHANGED 2026-09-15, per the user's explicit instruction: "you should
    // not cancel any bot in app unless you got a feedback from pionex. bot
    // should stay in same status... until feedback received from pionex" -
    // this used to cancel the bot and forget it here, purely on a LOCAL
    // timeout guess, with no confirmation from Pionex that it actually
    // needs cancelling. Now takes no action at all: `createdBots` and
    // `_openEntryByPair` are left exactly as they already were (tracked,
    // open) - the bot's real status is left for the normal reconciliation
    // loop (`_refreshActiveGrids`, which compares local tracking against
    // Pionex's own active-grids list every cycle) to catch up on whenever
    // Pionex actually reports something concrete, never guessed locally.
    logger.log(
      'PREPARE $symbol $buOrderId: still not confirmed running after ${CoreConstants.gridPrepareTimeout.inSeconds}s - '
      'taking no local action (no cancel, no status change); left tracked as-is for the normal reconciliation loop to resolve once Pionex reports a real status.',
    );
    return null;
  }

  /// Surfaces Pionex's OWN real minimum/maximum investment for a rejected
  /// `checkFuturesGrid` call, instead of just the generic "less than min
  /// investment" error text (2026-09-24, per the user: "why when i am
  /// trying to ignite waiting bots... it reply no signal" turned out to be
  /// GALAUSDT genuinely under-funded for its currently-required (widened,
  /// liquidation-safety) range at row=3 - confirmed live via a direct
  /// `checkFuturesGrid` probe that Pionex's rejection body, even on
  /// `result:false`, already carries the real numbers: `{"data":
  /// {"minInvestment":"26.470433","maxInvestment":"3744.99..."}, "code":
  /// "BOT_INVALID_ARGUMENT", "message":"less than min investment"}` -
  /// previously discarded entirely; only the generic exception text ever
  /// reached the log or the user). Returns null for any other error (a
  /// different rejection code, a network failure, or a body that doesn't
  /// parse) - callers fall back to logging `e` plain, unchanged.
  String? _pionexMinInvestmentHint(Object e) {
    if (e is! ApiException) return null;
    final raw = e.rawBody;
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final data = decoded['data'];
      if (data is! Map) return null;
      final min = double.tryParse('${data['minInvestment']}');
      if (min == null) return null;
      return 'Pionex requires at least \$${min.toStringAsFixed(2)} investment for this pair\'s current range/leverage/grid-count';
    } catch (_) {
      return null;
    }
  }

  /// Adopts a bot that's genuinely running on Pionex but currently has no
  /// in-memory [OpenEntry] for it - e.g. it was converted from manual via
  /// the Dashboard's toggle, or (2026-09-10 finding, restated here after
  /// being confirmed newly relevant 2026-09-24) the ENGINE ITSELF restarted
  /// while the bot was running, which wipes `_openEntryByPair` entirely
  /// (in-memory only, never persisted) - either way, without an entry, the
  /// opposite-signal close guard has nothing to compare against (stays
  /// null forever) and reconciliation's own recycle/history fallback (see
  /// the `bot == null` branch far below) has no real investment/direction
  /// data to recycle forward when this bot eventually closes, silently
  /// recording `base`/`pairKey` as `'unknown'` and skipping the recycle
  /// entirely instead. Synthesizes a real entry from the bot's own live
  /// Pionex data the first time it's seen this way; a no-op if one already
  /// exists.
  ///
  /// CRITICAL regression fixed 2026-09-24, live (per the user: "i am sure
  /// there is an error in waiting bots and recycled money... it was
  /// resently terminated with +3.9 usdt P&L .. whicl means this value
  /// should be added to initital investment at recycled bot" - traced to
  /// LINKUSDT closing via its Stop Loss Lock-locked SL and recording
  /// `base: "unknown"`, zero recycle, confirmed live against Pionex
  /// `getBotOrderByBuOrderId` showing the same real bot). Root cause: this
  /// adoption logic previously lived ONLY inside `_manageGridPair`, called
  /// once per pair per regular signal-check pass - but the 2026-09-23
  /// chart-time-skip optimization means an already-running, Stop-Loss-Lock-
  /// tagged base's pass never calls `_manageGridPair` AT ALL any more (the
  /// entire point of that optimization). Combined with tonight's several
  /// engine restarts (each wiping `_openEntryByPair` for every tagged
  /// running bot), every currently-tagged base's entry went permanently
  /// unadopted from the moment of whichever restart came first, until that
  /// bot finally closed with nothing to recycle. Fixed by calling this
  /// SAME adoption logic directly from both Stop-Loss-Lock skip sites too
  /// (`_runAutoCheckup`'s per-base loop and `_runCycle`'s per-pair loop),
  /// right before each one's own `continue` - the one piece of bookkeeping
  /// those skips still need to do even though the full chart-costing
  /// signal check stays skipped.
  void _adoptOpenEntryIfNeeded(
    GridBot existing,
    String entryKey,
    String base,
    AutoCategory category,
  ) {
    if (_openEntryByPair[entryKey] != null ||
        existing.trend == null ||
        existing.entryPrice == null) {
      return;
    }
    _openEntryByPair[entryKey] = OpenEntry(
      direction: existing.trend!,
      // Per the user (2026-09-06): entryTime everywhere else is a
      // TradingView bar time in SECONDS (see signal.time) - this was
      // storing milliseconds instead, so the opposite-signal close's
      // "last.time > entry.entryTime" check would never be true for an
      // adopted bot.
      entryTime:
          (existing.startTime ?? DateTime.now()).millisecondsSinceEpoch ~/
          1000,
      entryPrice: existing.entryPrice!,
      // Bug fixed 2026-09-10, live (traced from a LINKUSDT recycle showing
      // "next investment=0.8" when the bot's real total was $5.0): prefer
      // `initialInvestment` (`initUsdtInvestment` - the bot's real TOTAL
      // investment) over `actualInvestment` alone (just the active-margin
      // sliver).
      investment:
          existing.initialInvestment ??
          ((existing.actualInvestment ?? 0) + (existing.extraMargin ?? 0)),
      buOrderId: existing.buOrderId,
    );
    autoManagedByCategory[category]!.addBase(base);
    // Untagged bots default to 1H (see _appGridForKey) - stamp the tag
    // explicitly now so History/tables show it consistently from here.
    if (botCategories.categoryOf(existing.buOrderId) == null) {
      botCategories.setCategory(existing.buOrderId, category);
    }
    logger.log(
      'ADOPTED $entryKey: buOrderId=${existing.buOrderId} now tracked as app-initiated (${category.label}) - opposite-signal close/recycle is active for it from here on.',
    );
  }

  Future<void> _manageGridPair(
    GridPairConfig pair,
    // Worm10 Hybrid Decision technique (2026-10-25, per the user) -
    // already fully confirmed (3-read "1 million sure" + survived one
    // more full candle, see `_confirmedWorm10Event`) by the caller before
    // this function ever runs. Replaces `BuySellCheck? check` entirely -
    // this function no longer does any of its own confirmation/waiting.
    Worm10Event? confirmedEvent, {
    required bool checkNowTriggered,
    required bool createBlocked,
    bool tradingPaused = false,
    AutoCategory category = AutoCategory.oneHour,
    // Per the user's Worm10 spec §8 (Ignite): a bare zigzag event is
    // normally not enough to open on its own (see `worm10DecisionFor` -
    // "none" + zigzag -> no action) - Ignite is the one exception,
    // allowed to open on a bare zigzag too, not just a real OPEN1. Set
    // only by `_pairActionIgnite`/`_reigniteOpposite`. Still respects the
    // closed-candle rule (`confirmedEvent` is still the gate's OWN
    // confirmed output, never a raw unconfirmed read) and still bypasses
    // nothing else (margin/risk gates, duplicate-grid checks) - those stay
    // exactly as strict as a normal open.
    bool bypassFreshSignalGate = false,
    // Forces the open direction regardless of what the event says
    // (2026-09-18, per the user: "if current bot xrp 3m short triggered sl
    // for -50%, then next bot xrp 3m should be long... ignited immediately
    // with new trading view calculations for price range" - a raw -50%
    // baseline SL hit means the original direction was wrong, so the
    // re-entry goes the opposite way outright rather than waiting for a
    // fresh confirming signal). Set only by `_reigniteOpposite`.
    // `confirmedEvent` is still read normally for its candle
    // time/freshness bookkeeping - only the LONG/SHORT choice itself is
    // overridden.
    GridDirection? forcedDirection,
    // The retroactive audit's own verdict (see `_auditRunningBot`): already
    // replayed and re-read, and it can legitimately be older than the entry
    // or be its recorded opening event, so the two guards against acting on a
    // stale read of the latest event don't apply.
    bool fromAudit = false,
  }) async {
    _lastCreateSkipReason = null;
    final symbol = pair.symbol;
    final base = _baseOf(symbol);
    final futuresBase = _normalizeBase(base);
    final key = _gridKey(base);
    // Per the user (2026-09-07): a pair can have up to 3 simultaneous
    // app-owned grids, one per category, each fully independent - every
    // piece of THIS category's own bookkeeping (recycled investment, open
    // entry) is keyed by pair+category, never by pair alone, or one
    // category's close/reopen would clobber another's.
    final entryKey = '$key|${category.wireValue}';

    var investment = pair.investment;
    // Bug fixed 2026-09-10, live (per the user: "why still i can see
    // initial investment for all recycled bots 5$"): this used to remove
    // the recycled entry immediately on READING it here, regardless of
    // whether this specific call actually went on to create a real grid.
    // Confirmed via a live INVESTMENT SAMPLE diagnostic that every
    // currently-running recycled bot's real Pionex total
    // (quoteInvestment+extraMargin) was exactly the flat $5 default, not
    // the recycled amount its own "RECYCLE ... using reinvested amount"
    // log line had just computed moments earlier - traced to the FIRST
    // reopen attempt after a close routinely failing for an unrelated
    // transient reason (e.g. "no price range yet") AFTER this line had
    // already consumed and discarded the recycled entry, so the VERY NEXT
    // attempt (which succeeded) fell back to the flat default with no
    // trace of the loss. Peek only here now; the entry is removed later,
    // only once a real createFuturesGrid call has actually been accepted
    // by Pionex (see the matching `_nextInvestmentByPair.remove` right
    // after `_openEntryByPair[entryKey]` is set for the new bot below) -
    // any earlier return path (no signal, no range, gate blocked, margin
    // rule refused, etc.) now leaves the recycled amount intact for the
    // next attempt instead of silently spending it on nothing.
    if (_nextInvestmentByPair.containsKey(entryKey)) {
      investment = _nextInvestmentByPair[entryKey]!;
      logger.log(
        'RECYCLE $symbol: using reinvested amount $investment (old + P/L)',
      );
    }

    if (_sessionRetiredPairs.contains(symbol)) {
      logger.log(
        'SKIP $symbol: retired (removed from Red list) - no new grid trade',
      );
      return;
    }

    final existing = _appGridForKey(key, category);

    // --- Close on recycle/flip (Worm10 decision table) ---------------------
    final entry = _openEntryByPair[entryKey];
    if (existing != null && entry != null && confirmedEvent != null) {
      final decision = worm10DecisionFor(
        tradeDirectionOf(entry.direction),
        confirmedEvent.kind,
      );
      // §4 of the user's spec: ignore a recycle/flip if it's literally the
      // SAME event (type+time) that opened the current trade - otherwise
      // the latest event, re-read every cycle until something newer prints,
      // would close-then-reopen the exact same bot forever.
      final isSameOpeningEvent = entry.openedBy(confirmedEvent);
      // tradingMT5's Update: a same-direction signal on a genuinely newer bar
      // than both the opening event and the Update already recorded.
      if (decision.action == Worm10Action.update &&
          !isSameOpeningEvent &&
          confirmedEvent.time > entry.entryTime) {
        final at = DateTime.fromMillisecondsSinceEpoch(
          confirmedEvent.time * 1000,
        );
        final rec = entrySignalStore.recordFor(existing.buOrderId);
        if (rec != null && rec.update?.at != at) {
          entrySignalStore.recordUpdate(
            existing.buOrderId,
            at: at,
            type: confirmedEvent.kind.name,
          );
          logger.log(
            'WORM10 UPDATE $symbol: ${confirmedEvent.kind.name}@${confirmedEvent.time} '
            '(same direction as the running bot).',
          );
        }
      }
      final actsOnClose =
          decision.action == Worm10Action.recycle ||
          decision.action == Worm10Action.flip;
      // CRITICAL - same defense-in-depth the old opposite-signal check
      // had (`last.time > entry.entryTime`): the confirmed event's own
      // time must genuinely be newer than this trade's entry, never just
      // "not identical" - guards against ever acting on a stale/regressed
      // read, exactly the class of bug the user warned about for the
      // retroactive audit ("make sure the data it reads... is fresh,
      // before acting").
      final flip =
          actsOnClose &&
              (fromAudit ||
                  (!isSameOpeningEvent &&
                      confirmedEvent.time > entry.entryTime))
          ? confirmedEvent
          : null;
      // Stop Loss Lock override REMOVED 2026-09-25, per the user's exact
      // spec reworking the primary open/close signal rule: a tagged pair's
      // running bot can now close on a confirmed recycle/flip too, exactly
      // like an untagged one - it's no longer restricted to only ending
      // via Pionex's own real TP/SL. Stop Loss Lock's OWN separate
      // behavior (no SL protection below +100% P&L, its own faster
      // reversal-signal check that locks a tighter SL, the +200%
      // investment ratchet) is untouched and keeps running independently -
      // this just means the bot ALSO has a live exit path via the normal
      // decision rule now, on top of that.
      if (flip != null && tradingPaused) {
        // Per the user (2026-09-05): Check Now must still run its
        // informational scan while Auto is paused, but Auto-off's own rule
        // ("won't open or close anything new until turned back on") still
        // applies to the actual action - only the scan/report bypasses
        // pause, never a real Pionex close. Auto-checkup's own separate
        // Last-only watch (which DOES close while paused) never sets this
        // flag, so that exception is untouched.
        logger.log(
          'WORM10 ${decision.action.name.toUpperCase()} $symbol: confirmed but Auto is paused - not closing (informational only).',
        );
      } else if (flip != null) {
        final entryId = entry.buOrderId;
        final activeId = existing.buOrderId;
        if (entryId == null ||
            entryId != activeId ||
            !createdBots.isAppInitiated(entryId)) {
          logger.log(
            'WORM10 ${decision.action.name.toUpperCase()} $symbol: REFUSING to close - bot id mismatch OR bot not app-initiated. '
            'recorded entry buOrderId=$entryId vs active grid buOrderId=$activeId.',
          );
          brain.recordTrade({
            'type': 'grid-close',
            'pair': symbol,
            'status': 'id-mismatch-refused',
            'entryBuOrderId': entryId,
            'activeBuOrderId': activeId,
          });
          return;
        }
        // §4: a recycle only goes ahead if the reopen is allowed - closing a
        // right-way trade that can't be replaced just realizes its P&L. A flip
        // isn't gated this way: closing a wrong-way trade is still right even
        // if the new side can't open.
        if (decision.action == Worm10Action.recycle) {
          final gate = risk.gate(
            'buy',
            symbol,
            category,
            replacingOne: true,
          );
          final blockedBy = createBlocked
              ? 'new opens are blocked for this pair'
              : retired.isRetiredBase(base, category)
              ? 'the pair is retired (Last)'
              : gate.allowed
              ? null
              : gate.reason;
          if (blockedBy != null) {
            logger.log(
              'WORM10 RECYCLE $symbol: skipped - keeping the running trade, its reopen would be blocked: $blockedBy.',
            );
            return;
          }
        }
        // No close without a readable price range: the reopen needs one, and a
        // failed read here is often the sign of a chart in a bad state.
        if (await _readZigzagLines(
              symbol,
              resolution: category.rangeResolution,
            ) ==
            null) {
          logger.log(
            'WORM10 ${decision.action.name.toUpperCase()} $symbol: could not read the ${category.rangeResolution} price range - not closing this cycle.',
          );
          return;
        }
        logger.log(
          'WORM10 ${decision.action.name.toUpperCase()} $symbol: entered ${entry.direction.wireValue} at t=${entry.entryTime} - closing grid buOrderId=$entryId',
        );
        var closed = false;
        // Worm10Event carries no price (pure indicator-plot derivation,
        // see `Worm10Bar`'s doc) - a live ticker read stands in for the
        // old chart-signal price wherever an exit price is recorded below.
        final exitPrice = await pionex.getTickerPrice('${base}_USDT_PERP');
        // Voice-alert trigger (2026-09-17, per the user) - the mirror of
        // the start trigger above: this base has a real running grid
        // (existing != null && entry != null, checked above), the pause
        // and id-mismatch refusal checks just passed, so the app is
        // genuinely about to close it. Fired before the actual
        // cancelFuturesGrid call, same "don't wait on Pionex" rationale.
        // Gated through `_shouldAnnounceSignal` (2026-09-20 fix) so this
        // never double-speaks alongside `_announceChartSignalIfFresh`,
        // which may have already announced this exact signal moments
        // earlier in the same pass, purely from the chart.
        if (_shouldAnnounceSignal(entryKey, flip.time)) {
          storage.appendJsonl(
            storage.tradeStartEventsFile,
            TradeStartEvent(
              id: BotHistoryEntry.newId(),
              ts: DateTime.now(),
              kind: TradeTriggerKind.stop,
              base: base,
              direction: entry.direction,
              buOrderId: entryId,
              category: category,
            ).toJson(),
          );
        }
        if (!pionex.available) {
          logger.log(
            '[NO PIONEX] Would close grid $key, but Pionex isn\'t configured (buOrderId=$entryId)',
          );
          brain.recordTrade({
            'type': 'grid-close',
            'pair': symbol,
            'status': 'confirm',
            'buOrderId': entryId,
          });
          _openEntryByPair.remove(entryKey);
        } else {
          try {
            await pionex.cancelFuturesGrid(buOrderId: entryId);
            createdBots.forgetBot(entryId);
            botCategories.forget(entryId);
            tpSlRatchet.forget(entryId);
            stopLossLockState.forget(entryId);
            _stopLossLockSlCleared.remove(entryId);
            // REVERTED (2026-09-10, per the user - recycle-reopen
            // restored): see the matching reconciliation-path comment in
            // _refreshActiveGrids for the full explanation. Only an
            // explicit "Last" retirement removes a base from its category's
            // auto-managed list now - an ordinary opposite-signal close
            // stays on the list on purpose, so the next auto-checkup pass
            // can reopen it in the new direction using the recycled
            // investment set just below (`_nextInvestmentByPair`).
            if (retired.isRetiredBase(base, category)) {
              autoManagedByCategory[category]!.removeBase(base);
            }
            _activeGridsById.remove(entryId);
            risk.closePosition(symbol, category);
            final oldInvestment = entry.investment;
            double? recycled;
            double? pnl;
            try {
              // Settled-poll (see _getSettledGridPnl's doc) - confirmed
              // live (2026-09-19) this immediate read used to feed the
              // recycle math a pre-settlement figure that Pionex later
              // corrected (a real ADA bot: -0.0147 read here vs. +0.2287
              // once actually settled), silently baking the wrong amount
              // into the next bot's real investment with no way to fix it
              // after the fact.
              pnl = await _getSettledGridPnl(entryId);
              if (pnl != null) {
                // Bug fixed 2026-09-10, live (76 consecutive rejections
                // logged for GALAUSDT/HBARUSDT before this): Pionex rejects
                // `quoteInvestment` with more than 2 decimal places
                // ("quote_investment not match spending precision"), but
                // `old + P/L` is full floating-point precision and almost
                // never lands on a clean 2-decimal number. Rounding here
                // means every reopen attempt from here on sends a value
                // Pionex will actually accept - this bug was invisible
                // until the earlier fix on the same recycled-investment
                // path this session (discarding the value before use) was
                // itself fixed, which let the real recycled amount reach
                // Pionex for the first time.
                recycled = _roundTo2dp(
                  (oldInvestment + pnl).clamp(0, double.infinity),
                );
                _nextInvestmentByPair[entryKey] = recycled;
                _persistPendingInvestment(base, category, recycled);
                logger.log(
                  'RECYCLE $symbol: grid $entryId closed with P/L=$pnl USDT - next investment=$recycled',
                );
              } else {
                final fallback = _roundTo2dp(oldInvestment);
                _nextInvestmentByPair[entryKey] = fallback;
                _persistPendingInvestment(base, category, fallback);
              }
            } catch (e) {
              logger.log(
                'RECYCLE $symbol: P/L lookup failed ($e) - keeping old investment $oldInvestment',
              );
              final fallback = _roundTo2dp(oldInvestment);
              _nextInvestmentByPair[entryKey] = fallback;
              _persistPendingInvestment(base, category, fallback);
            }
            // REVERTED 2026-09-13, per the user: "since the technique is
            // buy/sell flipping.. there is no need for any delay" - the
            // BUY/SELL signal is a flip/state-machine, so the opposite
            // signal that just caused THIS close already IS the fresh
            // signal for the next open in that direction; waiting for yet
            // another one on top of it was pure, unneeded delay. Auto-
            // recycled bots open immediately again, on the spot, exactly
            // like before the fresh-signal-wait detour - only an explicit
            // Start still gates on a genuinely new signal (and only
            // conditionally now - see the open-decision block).
            _openEntryByPair.remove(entryKey);
            brain.recordTrade({
              'type': 'grid-close',
              'pair': symbol,
              'status': 'closed',
              'buOrderId': entryId,
              'recycledInvestment': recycled,
            });
            brain.appendExperience(
              'Closed ${entry.direction.wireValue} futures grid on $symbol on '
              'Worm10 ${decision.action.name} (${flip.kind.name}@${flip.time}) at $exitPrice',
            );
            // Entry-signal record: this is the ONE close path with a real
            // confirmed event on hand (2026-09-26, per the user - see
            // `EntrySignalStore`'s doc). Recorded before building the
            // history entry so `recordFor` below already has both ends.
            // `zone`/`value` stay permanently null under Worm10 (same as
            // they already were under worm_9_26's later revisions) - a
            // Worm10Event carries no RSI-zone/price fields at all.
            entrySignalStore.recordClose(
              entryId,
              // TradingView's own bar time (2026-09-26, per the user:
              // "time stamp for signals should be according to trading
              // view timing not according to my laptop") - NOT
              // DateTime.now(), which is whenever the engine happened to
              // notice/process it, seconds or minutes after the signal
              // actually appeared on the chart.
              at: DateTime.fromMillisecondsSinceEpoch(flip.time * 1000),
              type: flip.kind.name,
              zone: null,
              value: null,
            );
            final entrySignal = entrySignalStore.recordFor(entryId);
            entrySignalStore.forget(entryId);
            _recordHistory(
              BotHistoryEntry(
                id: BotHistoryEntry.newId(),
                ts: DateTime.now(),
                kind: BotHistoryKind.terminated,
                pairKey: key,
                base: base,
                buOrderId: entryId,
                category: category,
                direction: entry.direction,
                entryPrice: entry.entryPrice,
                exitPrice: exitPrice,
                initialInvestment: entry.investment,
                realizedProfit: pnl,
                startTime: DateTime.fromMillisecondsSinceEpoch(
                  entry.entryTime * 1000,
                ),
                endTime: DateTime.now(),
                detail: _withTerminationContext(
                  'Closed automatically on Worm10 ${decision.action.name} (${flip.kind.name}).',
                  base,
                  category,
                  realizedProfit: pnl,
                ),
                openSignalType: entrySignal?.open.type,
                openSignalZone: entrySignal?.open.zone,
                openSignalValue: entrySignal?.open.value,
                openSignalAt: entrySignal?.open.at,
                closeSignalType: entrySignal?.close?.type,
                closeSignalZone: entrySignal?.close?.zone,
                closeSignalValue: entrySignal?.close?.value,
                closeSignalAt: entrySignal?.close?.at,
                stopReason: 'close_signal',
              ),
            );
            closed = true;
          } catch (e) {
            logger.log('GRID CLOSE FAILED $symbol: $e');
          }
        }
        // Reopen on the spot (§4: a recycle or flip is a close AND an open).
        // This can't wait for a later cycle: a flip on a bare zigzag wouldn't
        // open from flat by itself.
        if (closed && !retired.isRetiredBase(base, category)) {
          await _manageGridPair(
            pair,
            flip,
            checkNowTriggered: checkNowTriggered,
            createBlocked: createBlocked,
            tradingPaused: tradingPaused,
            category: category,
            bypassFreshSignalGate: true,
            forcedDirection: decision.resultDirection == TradeDirection.long
                ? GridDirection.long
                : GridDirection.short,
          );
        }
        return;
      }
    }

    if (existing != null) {
      logger.log(
        'GRID ALREADY RUNNING $key: app grid buOrderId=${existing.buOrderId} - holding',
      );
      _adoptOpenEntryIfNeeded(existing, entryKey, base, category);
      final runningEntry = RunningBotCheck(
        symbol: symbol,
        base: base,
        buOrderId: existing.buOrderId,
        botDirection: existing.trend ?? GridDirection.long,
        latestEventType: confirmedEvent?.kind,
      );
      _runningBotsReportEntries.add(runningEntry);
      _mergeRunningBotsEntry(runningEntry);
      // Per the user (2026-09-11): "next trade show all red list items...
      // next trade has nothing to do with auto trade list and nothing to
      // do with manual bots" - Next Trade is now a pure market snapshot of
      // every red-list pair, completely independent of whether a bot
      // happens to be running for it. Previously removed this (base,
      // category)'s row entirely the moment a grid was found running -
      // now falls through to the SAME preview-building logic below every
      // other pair gets, so the row keeps showing real, live data. The
      // GUI's existing `blocked`/yellow-knob treatment (driven by
      // `status.grids.appRunning`, unchanged) already marks it
      // unselectable - and the real safety net is the independent
      // `existing != null` re-check right before the actual create call
      // further down (mirrors the createBlocked re-check already there) -
      // a duplicate grid can never actually be opened for this exact
      // (base, category) no matter what this preview shows or what gets
      // selected.
    }
    final manualExisting = _manualGridForKey(key);
    if (manualExisting != null) {
      logger.log(
        'GRID ALREADY RUNNING $key: MANUAL grid buOrderId=${manualExisting.buOrderId} present - app will open its own grid, not touch the manual one',
      );
    }

    // createBlocked is deliberately NOT checked here - a pair outside the
    // active selection should still show up in the Next Trade report with
    // its live preview, just never actually get opened. The real block is
    // the unconditional re-check right before the actual create call
    // further down.

    // --- New entry, driven by the confirmed Worm10 event -------------------
    // Replaces the entire old worm_9_26-era "fresh entry signal wait +
    // auto-ignite after one cycle" subsystem (per the user's explicit
    // "Replace it entirely" answer) - `confirmedEvent` has already passed
    // the caller's full confirm+wait gate
    // (`_confirmedWorm10Event`) before this function ever runs, so there is
    // no separate waiting/baseline bookkeeping left to do here at all.
    if (confirmedEvent == null) {
      logger.log('SKIP $symbol[${category.label}]: no confirmed Worm10 event yet');
      // Waiting for a signal is not a failed open - no strike (per the user,
      // 2026-11-08: Waiting waits for the hybrid decision).
      _lastCreateSkipReason = 'waiting for the hybrid decision';
      return;
    }

    // tradingMT5's open-from-flat rule, unchanged: only a case-1 event opens a
    // flat pair; an ignited pair (Ignite / SL re-ignite) also opens on a bare
    // zigzag, in that event's direction (worm10DecisionWithIgnite).
    final openDecision = worm10DecisionWithIgnite(
      null,
      confirmedEvent.kind,
      ignited: bypassFreshSignalGate,
    );
    if (openDecision.action != Worm10Action.openFresh) {
      logger.log(
        'SKIP $symbol[${category.label}]: confirmed event '
        '${confirmedEvent.kind.name}@${confirmedEvent.time} does not open '
        '(no running trade yet - a bare zigzag never opens on its own).',
      );
      _lastCreateSkipReason = 'waiting for the hybrid decision';
      return;
    }
    if (bypassFreshSignalGate) {
      logger.log(
        'IGNITE $symbol[${category.label}]: opening on the current signal '
        '${confirmedEvent.kind.name}@${confirmedEvent.time}.',
      );
    }
    final direction =
        forcedDirection ?? gridDirectionOf(openDecision.resultDirection!);

    final already = _openEntryByPair[entryKey];
    if (already != null &&
        already.entryTime == confirmedEvent.time &&
        already.openEventType == confirmedEvent.kind &&
        already.direction == direction)
      return;

    // REMOVED 2026-09-15, per the user: "the user can write what will be
    // initial investment in next trade per each pair. remove minimum free
    // balance." Used to refuse opening a genuinely new pair below a flat
    // $10 free-balance floor - no longer needed now that investment per
    // pair is always explicitly user-set, not a guessed default.

    final lines = await _readZigzagLines(
      symbol,
      resolution: category.rangeResolution,
    );
    if (lines == null) {
      logger.log(
        'SKIP $symbol: could not read ${category.rangeResolution} chart data (MSB/OB range) - skipping',
      );
      return;
    }
    final zigzag = detectZigzagRange(
      lines,
      swingCount: config.technique.rangeSwingCount,
    );
    if (zigzag != null) {
      logger.log(
        'RANGE $symbol: MSB/OB zigzag -> top=${zigzag.top} bottom=${zigzag.bottom} (${zigzag.pivotCount} pivots)',
      );
    }
    if (zigzag == null || !zigzag.isValid) {
      logger.log(
        'SKIP $symbol: no price range (top/bottom) from Daily MSB/OB zigzag (last ${config.technique.rangeSwingCount} pivots) - skipping',
      );
      return;
    }
    // "1 million sure" rule for the RANGE too (2026-09-27, per the user's
    // own standing rule) - unlike the signal (guarded by its own 3-read
    // confirmation inside `_checkBuySellOnPair`), this range feeds directly
    // into the grid's real top/bottom (and therefore its real stop-loss)
    // and previously had NO re-read confirmation at all beyond a bare
    // finite/top>bottom sanity check - a wildly wrong-but-technically-valid
    // single read (e.g. a corrupted "0.99-1.70" range for a pair actually
    // trading near $84,500 - a real, one-time corrupted read this rule was
    // written specifically to catch, per the user) would have sailed
    // straight through untouched. Same shape as the signal check: two more
    // reads, 10 seconds apart, top AND bottom must match read #1 exactly,
    // or the whole cycle is skipped rather than opening/closing on a
    // shaky/unconfirmed range. Scoped to this real decision path only, not
    // the read-only Check/Next-Trade preview (`_computeCategoryCheckPreview`) -
    // nothing there risks real money, so it stays a single read.
    for (var confirmAttempt = 1; confirmAttempt <= 2; confirmAttempt++) {
      await Future<void>.delayed(const Duration(seconds: 10));
      final confirmLines = await _readZigzagLines(
        symbol,
        resolution: category.rangeResolution,
      );
      final confirmZigzag = confirmLines == null
          ? null
          : detectZigzagRange(
              confirmLines,
              swingCount: config.technique.rangeSwingCount,
            );
      final agrees =
          confirmZigzag != null &&
          confirmZigzag.isValid &&
          confirmZigzag.top == zigzag.top &&
          confirmZigzag.bottom == zigzag.bottom;
      if (!agrees) {
        logger.log(
          'RANGE FLICKER $symbol: read #1 top=${zigzag.top} bottom=${zigzag.bottom}, '
          'read #${confirmAttempt + 1} '
          '${confirmZigzag == null ? 'nothing/invalid' : 'top=${confirmZigzag.top} bottom=${confirmZigzag.bottom}'} '
          '- disagreement, treating as unconfirmed this cycle.',
          level: 'WARNING',
        );
        return;
      }
    }
    // A fresh non-nullable binding: `range` gets reassigned later (widen /
    // shrink-retry), which would otherwise make the analyzer drop the
    // null-check promotion on `zigzag` across the closures below.
    var range = zigzag;

    final maxLev = await _maxLeverageFor(symbol);
    if (maxLev == null) {
      logger.log('SKIP $symbol: could not read max leverage from Pionex');
      return;
    }
    final leverage = maxLev; // Always max, regardless of direction/market.

    // Grid count and auto-reserve are BOTH just "ask Pionex what it will
    // actually do before creating" (same pattern) - per the user's original
    // spec (not the shipped heuristic): start at the floor and keep
    // increasing the row count, using checkParams to confirm the investment
    // still covers it, up to the highest row that validates. Folded into the
    // SAME checkParams calls used for the auto-reserve split, since a
    // successful checkParams response for a given row already carries that
    // row's actual/reserve breakdown - no need for a second round-trip.
    // Per the user (2026-09-04): auto-reserve is mandatory for every trade,
    // not a config-toggleable option - previously this could evaluate to
    // false depending on config.json/per-pair settings, which contradicted
    // that. Always true now, full stop.
    const autoReserve = true;
    final isDryRun = !pionex.available;

    double trigger;
    LiquidationLevels lvl;
    // Fallback target for the create/retry loop below (2026-09-14, per the
    // user's explicit spec) - only meaningful when a liquidation shift was
    // actually applied; otherwise unused.
    var naturalTop = range.top;
    var naturalBottom = range.bottom;
    // Diagnostic only (2026-09-14, per an external review of the
    // BOT_INTERNAL_ERROR investigation) - tracked across every
    // checkFuturesGrid/getBalance call in this function's remaining flow so
    // the eventual create attempt can log how stale each is, to compare a
    // future success against the failures immediately around it (per the
    // review: "record the time gap between checkParams success and create"
    // and "free USDT before create").
    var lastCheckParamsAt = DateTime.now();
    double? lastKnownFreeUsdt;

    if (isDryRun || existing != null) {
      // No live probing for a preview-only pass (see the 2026-09-11 note
      // further down, same reasoning) - the old chart-only 60/40 model is
      // fine here, it's never what actually opens anything. A Worm10Event
      // carries no price (pure indicator-plot derivation) - the public,
      // unauthenticated ticker endpoint works regardless of `isDryRun`
      // (never requires API keys), falling back to the range's own
      // midpoint only if even that is unreachable.
      trigger =
          await pionex.getTickerPrice('${base}_USDT_PERP') ??
          (range.top + range.bottom) / 2;
      lvl = computeLiquidationLevels(
        top: range.top,
        bottom: range.bottom,
        entry: trigger,
        direction: direction,
      );
      if (lvl.widenApplied) {
        range = range.copyWith(top: lvl.gridTop, bottom: lvl.gridBottom);
      }
    } else {
      // Pionex account-tier limit (2026-09-16, per the user, confirmed
      // live via Pionex's own "Creation failed" dialog when manually
      // trying to open BCHUSDT with the app's exact parameters): once an
      // account holds more than 20 total bots (manual + app, shared
      // across futures/COIN-M/margin grids), Pionex requires every NEW
      // bot's investment to exceed $50 - a real, hard Pionex-side wall,
      // not anything in this app's own math. This almost certainly
      // explains several of today's generic BOT_INTERNAL_ERROR/refusal
      // incidents that were previously attributed to transient Pionex
      // flakiness or per-pair margin math alone. Refused cleanly here,
      // before spending a real checkParams/create round-trip on an
      // attempt that was never going to pass - covers both automatic
      // waiting-engine opens and a manual Ignite/Start (whose result
      // message already surfaces `_lastCreateSkipReason` straight to the
      // GUI via the existing snackbar path, no new UI wiring needed for
      // this first pass).
      final wouldBeBotNumber = _activeGridsById.length + 1;
      const pionexTierThreshold = 20;
      const pionexTierMinInvestment = 50.0;
      if (wouldBeBotNumber > pionexTierThreshold &&
          investment <= pionexTierMinInvestment) {
        _lastCreateSkipReason =
            'would be bot #$wouldBeBotNumber on this Pionex account - Pionex '
            'requires investment over \$$pionexTierMinInvestment once an account '
            'holds more than $pionexTierThreshold bots (current investment '
            '\$$investment)';
        logger.log(
          'PIONEX TIER LIMIT $symbol: REFUSING to open - would be bot #$wouldBeBotNumber '
          '(Pionex requires investment over \$$pionexTierMinInvestment once an account '
          'holds more than $pionexTierThreshold bots) - current investment \$$investment.',
          level: 'ERROR',
        );
        return;
      }

      // New 60/40 model (2026-09-14), per the user's explicit spec -
      // replaces the chart-only widen above for every REAL open decision.
      // Walked through live with the user: range 20-80 (span=60), entry=30,
      // Pionex-reported liquidation=20 -> distance(30,20)=10 < 0.6*60=36 ->
      // unsafe -> shift. See liquidation.dart's computeLiquidationShift doc
      // for the full math and the worked-example verification.
      // Bug fixed 2026-09-14, confirmed live (SOLUSDT, 2 real strikes):
      // this used `futuresBase` ("SOL.PERP") instead of the bare `base`
      // ("SOL"), producing a malformed ticker symbol ("SOL.PERP_USDT_PERP")
      // - the API call itself didn't throw (logged "ok"), it just returned
      // no usable price for an unknown symbol, so entryPrice always came
      // back null and every real open refused itself. Same convention
      // _tickerSymbol (engine_control_repository.dart) already uses.
      final entryPrice = await pionex.getTickerPrice('${base}_USDT_PERP');
      if (entryPrice == null) {
        logger.log(
          'SKIP $symbol: could not read current market price from Pionex - refusing to open without a real entry price.',
        );
        return;
      }
      trigger = entryPrice;

      // Bug fixed 2026-09-18, live, real money (per the user, real BTC bot
      // 9b6e139e...): this used to probe checkFuturesGrid with the RAW,
      // unrounded zigzag top/bottom purely to fetch a real liquidation
      // price for the 60/40 safety check below - Pionex rejected it
      // outright with "top not match quote precision" whenever the pair's
      // required precision was coarser than the raw pivot's decimals (a
      // BTC pivot like 81258.01 needs whole-dollar rounding). The
      // exception was caught and swallowed here, `computeLiquidationShift`
      // was then called with `liquidationPrice: null`, which per its own
      // doc comment "fails OPEN... proceeds with the natural range" - i.e.
      // the ENTIRE safety check silently never ran, `stable=true`/
      // `widenApplied=false` got logged even though nothing was actually
      // verified. Real consequence: that BTC bot opened with top=81258
      // only 1.47% away from its real reported liquidation price (82448)
      // at 100x leverage - exactly the case this model exists to prevent,
      // defeated by a precision mismatch in its own probe.
      //
      // Fixed by resolving quote precision FIRST via [_resolveQuotePrecision]
      // (the same helper the row/investment probing below already uses,
      // which tries 8 down to 0 decimals until Pionex accepts one) and
      // reusing THAT SAME successful probe's own
      // `estimateLiquidationPriceUp`/`...Down` as the real liquidation
      // price - one precision-safe Pionex round trip instead of a separate
      // precision-naive one that could fail independently. The later,
      // now-redundant second `_resolveQuotePrecision` call further below
      // (right before row probing) is removed - this range is already
      // resolved and rounded by the time it reaches that point, in the
      // common (non-widened) case with zero extra Pionex calls.
      final resolved = await _resolveQuotePrecision(
        futuresBase: futuresBase,
        top: range.top,
        bottom: range.bottom,
        direction: direction,
        leverage: leverage,
        investment: investment.toString(),
      );
      if (resolved == null) {
        logger.log(
          'PRECISION $symbol: no top/bottom rounding from 8 down to 0 decimals was accepted by Pionex - refusing to open.',
        );
        return;
      }
      if (resolved.top != range.top || resolved.bottom != range.bottom) {
        logger.log(
          'PRECISION $symbol: Pionex requires coarser price precision - rounded top ${range.top} -> ${resolved.top}, bottom ${range.bottom} -> ${resolved.bottom}',
        );
        range = range.copyWith(top: resolved.top, bottom: resolved.bottom);
      }

      lvl = computeLiquidationShift(
        top: range.top,
        bottom: range.bottom,
        entry: entryPrice,
        liquidationPrice: resolved.liquidationPrice,
        direction: direction,
      );
      if (lvl.widenApplied) {
        logger.log(
          'TP/SL $symbol: ${direction.wireValue} UNSAFE - entry $entryPrice is within 60% of Pionex\'s real liquidation price '
          '${resolved.liquidationPrice ?? "?"} (span ${range.top - range.bottom}) - shifting range to [${lvl.gridBottom}..${lvl.gridTop}] (parallel shift, span unchanged)',
        );
        range = range.copyWith(top: lvl.gridTop, bottom: lvl.gridBottom);
        // The widened edges are fresh floating-point arithmetic, not
        // necessarily still at the precision Pionex just accepted above -
        // re-resolve only in this (rarer) branch, never in the common
        // stable case.
        final rewidened = await _resolveQuotePrecision(
          futuresBase: futuresBase,
          top: range.top,
          bottom: range.bottom,
          direction: direction,
          leverage: leverage,
          investment: investment.toString(),
        );
        if (rewidened == null) {
          logger.log(
            'PRECISION $symbol: widened range had no accepted top/bottom rounding from 8 down to 0 decimals - refusing to open.',
          );
          return;
        }
        range = range.copyWith(top: rewidened.top, bottom: rewidened.bottom);
      }
    }
    // Bug fixed 2026-09-16, per the user ("what readings you got from
    // trading view on what candle"): the event's own candle time was read
    // into memory but never logged or persisted anywhere, so there was no
    // way to answer "which candle triggered this" after the fact. Logged
    // here (fires on every preview AND every real open decision) as both
    // the raw epoch (matches latestBarTime/candle-gate values elsewhere in
    // this file) and a readable UTC timestamp.
    final eventCandleUtc = DateTime.fromMillisecondsSinceEpoch(
      confirmedEvent.time * 1000,
      isUtc: true,
    ).toIso8601String();
    logger.log(
      'TP/SL $symbol: ${direction.wireValue} entry=$trigger grid range [${range.bottom}..${range.top}] '
      'stable=${lvl.stable} -> TP=${lvl.takeProfitPrice} SL=${lvl.stopLossPrice} '
      '(event: ${confirmedEvent.kind.name}@${confirmedEvent.time} / $eventCandleUtc)',
    );

    int row;
    var quoteInvestment = investment.toString();
    String? extraMargin;
    double? liquidationPreview;

    // Per the user (2026-09-11): once an already-running (base, category)
    // stopped early-returning above and started falling through to build a
    // real Next Trade preview too, this expensive real Pionex probe
    // (multiple checkFuturesGrid round trips + a balance read) started
    // running for it EVERY single pass - Check Now AND the continuous 1m
    // auto-checkup alike - even though the guard further down guarantees
    // no real grid will ever be created for it regardless of what this
    // probe finds. Live symptom: the exact same "AUTO-RESERVE ...
    // REFUSING" line repeating for every one of a dozen already-running
    // pairs, every cycle, forever - wasted Pionex API load plus needless
    // noise, not a new financial risk (the actual duplicate-create guard
    // was never the problem), but real enough to fix. Skips the probe the
    // same way dry-run already does (a rough row estimate, no
    // actualInvestment/extraMargin/liquidationPrice - the report shows
    // "—" for those, exactly like it already does whenever they're null)
    // - this pair's range/direction/TP/SL preview above is still fully
    // real and free (computed from data already on hand), just not the
    // Pionex-side investment split, which is meaningless here anyway.
    if (isDryRun || existing != null) {
      // No live checkParams probing in dry-run/confirm mode for the actual
      // create decision (matches the original's validate_with_checkparams
      // gate, off by default) - this is a rough estimate for the log/decision
      // record only. The Last Report preview below runs its own probe
      // regardless, since checkParams is a Pionex-side dry-run validation
      // call that never creates anything - safe even though the engine
      // itself won't act on this pair while in confirm mode.
      row = (investment / 10).round().clamp(
        config.technique.minGrids,
        config.technique.effectiveMaxGrids,
      );
    } else {
      // Precision was already resolved above, before the liquidation-shift
      // decision (2026-09-18 fix) - `range` here is guaranteed to already
      // be at an accepted Pionex precision (the stable case reuses the
      // first `_resolveQuotePrecision` call's rounding directly; the
      // widened case was re-resolved after the shift), so no second
      // resolution pass is needed here.
      Map<String, dynamic>? probeResponse;
      // Captures Pionex's own real minimum-investment number the moment a
      // probe/retry attempt below is rejected specifically for that reason
      // (2026-09-24, per the user - see `_pionexMinInvestmentHint`'s doc).
      // Deliberately just the LAST one seen - row/investment don't change
      // between the probe and its retry, so there's only ever one real
      // number to report regardless of which attempt happened to capture it.
      String? minInvestmentHint;
      try {
        row = await probeMaxGridCount(
          minGrids: config.technique.minGrids,
          maxGrids: config.technique.effectiveMaxGrids,
          checkRowValid: (candidate) async {
            try {
              final resp = await pionex.checkFuturesGrid(
                base: futuresBase,
                quote: 'USDT',
                buOrderData: {
                  'top': range.top.toString(),
                  'bottom': range.bottom.toString(),
                  'row': candidate,
                  'grid_type': 'arithmetic',
                  'trend': direction.wireValue,
                  'leverage': leverage,
                  'quoteInvestment': investment.toString(),
                  if (autoReserve) 'extraMargin': true,
                },
              );
              probeResponse = resp;
              return true;
            } on RateLimitException {
              rethrow; // abort the whole probe sequence, not just this row
            } catch (e) {
              // Bug fixed 2026-09-09: was silent - see the identical fix in
              // _computeCategoryCheckPreview for the full reasoning. This
              // is the REAL-OPEN decision path, so a candidate rejected
              // here for a non-obvious reason is exactly what silently
              // produced "no actual investment/extra margin" with zero
              // trace of why.
              minInvestmentHint = _pionexMinInvestmentHint(e) ?? minInvestmentHint;
              logger.log(
                'AUTO-RESERVE $symbol[${category.label}]: row=$candidate rejected by Pionex checkFuturesGrid: $e',
              );
              return false;
            }
          },
        );
      } on RateLimitException catch (e) {
        logger.log(
          'RATE LIMITED $symbol: Pionex asked us to back off${e.retryAfter != null ? ' (retry after ${e.retryAfter!.inSeconds}s)' : ''} '
          '- abandoning grid-count probing for this pair this cycle rather than sending more requests into the limit.',
          level: 'ERROR',
        );
        return;
      }
      liquidationPreview = direction == GridDirection.long
          ? double.tryParse('${probeResponse?['estimateLiquidationPriceDown']}')
          : double.tryParse('${probeResponse?['estimateLiquidationPriceUp']}');
      logger.log(
        'GRID COUNT $symbol: probed via checkParams -> row=$row (investment=$investment)',
      );

      if (autoReserve) {
        var splitResponse = probeResponse;
        if (splitResponse == null) {
          // Even the floor row never validated during probing - try once
          // more directly, just to still attempt a split for the record.
          try {
            splitResponse = await pionex.checkFuturesGrid(
              base: futuresBase,
              quote: 'USDT',
              buOrderData: {
                'top': range.top.toString(),
                'bottom': range.bottom.toString(),
                'row': row,
                'grid_type': 'arithmetic',
                'trend': direction.wireValue,
                'leverage': leverage,
                'quoteInvestment': investment.toString(),
                'extraMargin': true,
              },
            );
            lastCheckParamsAt = DateTime.now();
          } on RateLimitException catch (e) {
            logger.log(
              'RATE LIMITED $symbol: backing off auto-reserve split${e.retryAfter != null ? ' (retry after ${e.retryAfter!.inSeconds}s)' : ''} '
              '- refusing to open without a confirmed split this cycle.',
              level: 'ERROR',
            );
          } catch (e) {
            minInvestmentHint = _pionexMinInvestmentHint(e) ?? minInvestmentHint;
            logger.log(
              'AUTO-RESERVE $symbol checkParams failed ($e) - refusing to open without a confirmed investment/reserve split from Pionex.',
            );
          }
        }
        // Per the user (2026-09-04, live account): NEVER silently fall back
        // to the full flat investment when Pionex didn't actually confirm a
        // split - that's real money going in unsized. If splitResponse is
        // still null here, or its numbers don't parse to something usable,
        // refuse to open this pair this cycle rather than guess.
        var confirmedSplit = false;
        if (splitResponse != null) {
          final actual = double.tryParse(
            '${splitResponse['estimateInvestment']}',
          );
          final reserve = double.tryParse(
            '${splitResponse['estimateExtraMargin']}',
          );
          if (actual != null && actual > 0 && reserve != null && reserve >= 0) {
            var total = actual + reserve;
            double free = double.infinity;
            try {
              free = (await pionex.getBalance('USDT')).free;
              lastKnownFreeUsdt = free;
            } catch (e) {
              logger.log(
                'AUTO-RESERVE $symbol: balance read error $e - proceeding unclamped',
              );
            }
            var effReserve = reserve;
            if (free.isFinite && total > free) {
              effReserve = ((free - actual) * 10000).floor() / 10000;
              effReserve = effReserve < 0 ? 0 : effReserve;
              total = actual + effReserve;
              logger.log(
                'AUTO-RESERVE $symbol: budget total ${actual + reserve} > free $free - clamping reserve to $effReserve',
              );
            }
            // MANDATORY (2026-09-10, per the user, after a live GALAUSDT
            // open came back with extraMargin effectively $0 - Pionex HAD
            // confirmed a split (satisfying the "never guess" rule above),
            // but the split itself was unsafe: nearly the entire budget
            // committed as actual investment with almost no margin buffer.
            // The user's rule: extra margin must be strictly GREATER than
            // actual investment for this pair/range/leverage/grid-count
            // combination to be allowed to open at all - if Pionex's own
            // real split doesn't clear that bar, refuse, exactly like an
            // unconfirmed split refuses below (confirmedSplit stays false).
            if (effReserve <= actual) {
              logger.log(
                'AUTO-RESERVE $symbol: REFUSING to open - extra margin '
                '($effReserve) must be greater than actual investment '
                '($actual) per the mandatory margin-safety rule; Pionex\'s '
                'own confirmed split for this pair/range/leverage/grid-count '
                'came back too thin.',
              );
            } else {
              quoteInvestment = actual.toString();
              extraMargin = effReserve.toString();
              confirmedSplit = true;
              logger.log(
                'AUTO-RESERVE $symbol: budget=$investment -> actual=$actual reserve=$effReserve (total $total)',
              );
            }
          }
        }
        if (!confirmedSplit) {
          // Bug fixed 2026-09-24, per the user: Ignite reported nothing more
          // specific than "Pionex did not accept the open - see engine.log"
          // for this exact refusal (confirmed live on GALAUSDT - genuinely
          // under-funded for its currently-required liquidation-safety-
          // widened range, needing ~$26.47 against a configured $20).
          // `_lastCreateSkipReason` is the SAME field Ignite already reads
          // for every other refusal reason (already running, margin-safety,
          // fresh-signal gate, etc.) - it just never got set here, so this
          // one specific refusal always fell through to Ignite's generic
          // fallback message instead. Now carries Pionex's own real
          // minimum-investment number when that was the actual cause.
          _lastCreateSkipReason =
              minInvestmentHint ??
              'Pionex would not confirm an investment/reserve split for this pair\'s current range/leverage/grid-count';
          logger.log(
            'AUTO-RESERVE $symbol: no confirmed investment/reserve split from Pionex - NOT opening with a blind full-investment guess.',
          );
          return;
        }
      }
    }

    final decision = {
      'type': 'grid',
      'pair': symbol,
      'base': base,
      'direction': direction.wireValue,
      'maxLeverage': maxLev,
      'leverage': leverage,
      'row': row,
      'top': range.top,
      'bottom': range.bottom,
      'investment': investment,
      'trigger': trigger,
      'takeProfit': lvl.takeProfitPrice,
      'stopLoss': lvl.stopLossPrice,
      'slStable': lvl.stable,
      'slWidenApplied': lvl.widenApplied,
    };
    brain.recordDecision(decision);
    await _recordReportPreview(
      symbol: symbol,
      base: base,
      futuresBase: futuresBase,
      direction: direction,
      range: range,
      lvl: lvl,
      maxLev: maxLev,
      leverage: leverage,
      trigger: trigger,
      investment: investment,
      autoReserve: autoReserve,
      isDryRun: isDryRun,
      liveRow: row,
      liveActualInvestment: quoteInvestment,
      liveExtraMargin: extraMargin,
      liveLiquidationPreview: liquidationPreview,
      category: category,
    );

    // Unconditional - added 2026-09-11 when the early return above (that
    // used to make this whole rest of the function unreachable for an
    // already-running pair) was removed so Next Trade could keep showing
    // a live preview for it. `existing` was already computed once, at the
    // top of this function - re-checked here, same pattern as
    // createBlocked immediately below: no matter how this pair was
    // reached, or what got selected, a grid already running for this
    // EXACT (base, category) can never be duplicated by a real create
    // call.
    if (existing != null) {
      _lastCreateSkipReason = 'a grid is already running for this pair/interval';
      logger.log(
        'ALREADY RUNNING: $symbol[${category.label}] - refusing to open a duplicate grid (preview above still shown for the report).',
      );
      return;
    }
    if (createBlocked) {
      _lastCreateSkipReason = 'not in the current selection';
      logger.log(
        'SELECTION BLOCKED: $symbol - not in the selection; existing grid kept, no new grid on this pair (preview above still shown for the report)',
      );
      return;
    }

    final gate = risk.gate('buy', symbol, category);
    if (!gate.allowed) {
      _lastCreateSkipReason = gate.reason;
      logger.log('GATE BLOCKED grid for $symbol: ${gate.reason}');
      return;
    }

    // Voice-alert trigger (2026-09-17, per the user - "voice is for
    // TradingView triggers", fired here rather than after a real
    // createFuturesGrid succeeds: every one of the app's OWN gates above
    // (already-running dedup, selection/createBlocked, risk gate) has
    // already passed, so this base is genuinely about to open - only
    // Pionex's own network round-trip (and its shrink-retry ladder) is
    // still ahead, and the user explicitly doesn't want the voice waiting
    // on that. See `TradeStartEvent`'s doc comment for the full rationale.
    // Gated through `_shouldAnnounceSignal` (2026-09-20 fix) so this never
    // double-speaks alongside `_announceChartSignalIfFresh`, which may
    // have already announced this exact signal moments earlier in the
    // same pass, purely from the chart.
    if (_shouldAnnounceSignal(entryKey, confirmedEvent.time)) {
      storage.appendJsonl(
        storage.tradeStartEventsFile,
        TradeStartEvent(
          id: BotHistoryEntry.newId(),
          ts: DateTime.now(),
          kind: TradeTriggerKind.start,
          base: base,
          direction: direction,
          category: category,
        ).toJson(),
      );
    }

    if (isDryRun) {
      logger.log(
        '[NO PIONEX] Would create grid, but Pionex isn\'t configured: $decision',
      );
      brain.recordTrade({...decision, 'status': 'dry-run'});
      _openEntryByPair[entryKey] = OpenEntry(
        direction: direction,
        entryTime: confirmedEvent.time,
        entryPrice: trigger,
        investment: investment,
        openEventType: confirmedEvent.kind,
      );
      return;
    }

    // CRITICAL, added 2026-09-15, confirmed live (per the user: "before
    // starting the trade... check if price within the range or not"):
    // BTCUSDT buOrderId ee5e05d4 was created with grid range
    // [212.8..225.2] while its real entry price was 75790.9 - the range
    // computed from the MSB/OB zigzag read was garbage (almost certainly
    // stale data from a different symbol still settling on the shared
    // chart), and nothing before this point ever checked the range made
    // any sense relative to the real price. `computeLiquidationShift`
    // only guarantees containment for the SHIFTED case (`widenApplied`) -
    // a `stable: true` result (no shift needed) just means the distance
    // check happened to pass on whatever numbers it was given, garbage or
    // not. This is the last, unconditional checkpoint before any real
    // money moves: refuses outright if the current price isn't actually
    // inside the range about to be sent to Pionex - exactly the
    // "current price is higher/lower than the range, bot paused"
    // condition the user described, caught here instead of discovered
    // after the fact on a live, stuck bot.
    if (trigger < range.bottom || trigger > range.top) {
      _lastCreateSkipReason =
          'current price ($trigger) is outside the computed range [${range.bottom}..${range.top}] - refusing to open with a range that would leave the bot paused on Pionex';
      logger.log(
        'RANGE SANITY $symbol: REFUSING - current price $trigger is outside '
        '[${range.bottom}..${range.top}] - this would open paused '
        '("price outside range") on Pionex, not actually trading.',
        level: 'ERROR',
      );
      return;
    }

    // No trigger `condition` is ever sent (PRD §10 rule 11) - a conditional
    // bot stays in `prepare` forever if price never reaches the trigger.
    // (row / quoteInvestment / extraMargin were already determined above via
    // the checkParams probe, together with the grid-count search.)
    final buOrderData = <String, dynamic>{
      'top': range.top.toString(),
      'bottom': range.bottom.toString(),
      'row': row,
      'grid_type': 'arithmetic',
      'trend': direction.wireValue,
      // INVESTIGATED 2026-09-14, still unresolved after multiple live
      // attempts - reverted to this original form each time rather than
      // leave the live account on an unproven variant. Every real create
      // attempt gets BOT_INTERNAL_ERROR or BOT_INVALID_ARGUMENT (depends
      // on the exact leverage/extraMargin representation tried) from
      // Pionex, while checkFuturesGrid (the dry-run probe, using
      // near-identical data) always accepts it. Tried: leverage as
      // double/int/string (none succeeded); matching create's shape
      // exactly to the probe's (full quoteInvestment + `extraMargin:
      // true` instead of the pre-split numbers) - still failed. See the
      // 2026-09-14 PRD/annex entries for the full investigation and the
      // handover report written for external review. Needs Pionex's real
      // API documentation or support, not further live trial-and-error.
      'leverage': leverage,
      'quoteInvestment': quoteInvestment,
      if (extraMargin != null) 'extraMargin': extraMargin,
    };

    final originalTop = range.top;
    final originalBottom = range.bottom;
    var shrinkCount = 0;
    // Per the user's explicit spec (2026-09-14): try the shifted range
    // first; "if pionex rejected... get back to 20-80 (neutral)" - a
    // one-time fallback to the natural, pre-shift range, tried BEFORE the
    // percentage-based shrink ladder below (which stays as the fallback for
    // every other rejection reason, unchanged).
    var triedNaturalFallback = false;

    for (var attempt = 1; attempt <= maxShrinkRetries + 1; attempt++) {
      // Diagnostic only (2026-09-14, per an external review of the
      // BOT_INTERNAL_ERROR investigation): "record HTTP status code,
      // response headers, request duration... free USDT before create...
      // current market price immediately before create" - captured for
      // every attempt, success or failure, so a future success can be
      // compared against the failures right around it, not just its body.
      final createSw = Stopwatch()..start();
      int? createStatusCode;
      Map<String, String>? createHeaders;
      final sinceCheckParamsMs = DateTime.now()
          .difference(lastCheckParamsAt)
          .inMilliseconds;
      try {
        final result = await pionex.createFuturesGrid(
          base: futuresBase,
          quote: 'USDT',
          buOrderData: buOrderData,
          onRawResponse: (status, hdrs) {
            createStatusCode = status;
            createHeaders = hdrs;
          },
        );
        createSw.stop();
        logger.log(
          'GRID CREATE $symbol DIAGNOSTIC (attempt $attempt, SUCCESS): '
          'httpStatus=$createStatusCode durationMs=${createSw.elapsedMilliseconds} '
          'sinceCheckParamsMs=$sinceCheckParamsMs freeUsdtBefore=$lastKnownFreeUsdt '
          'marketPrice=$trigger '
          'headers=${_diagnosticHeaders(createHeaders)}',
        );
        risk.openPosition(symbol, category);
        brain.recordTrade({
          'type': 'grid',
          'pair': symbol,
          'status': 'open',
          'side': direction.wireValue,
          ...result,
        });
        brain.appendExperience(
          'Opened ${direction.wireValue} futures grid on $symbol: top=${range.top} bottom=${range.bottom} '
          'row=$row lev=${leverage}x invest=$investment entryEvent=${confirmedEvent.kind.name}@${confirmedEvent.time}',
        );
        final newBuOrderId =
            (result['buOrderId'] ??
                    (result['buOrderData'] as Map?)?['buOrderId'])
                ?.toString();
        if (newBuOrderId == null) {
          logger.log(
            'GRID CREATE $symbol: response carried no buOrderId - cannot track this bot',
            level: 'ERROR',
          );
          break;
        }
        _openEntryByPair[entryKey] = OpenEntry(
          direction: direction,
          entryTime: confirmedEvent.time,
          entryPrice: trigger,
          investment: investment,
          buOrderId: newBuOrderId,
          openEventType: confirmedEvent.kind,
        );
        // Entry-signal record (2026-09-26, per the user: "the record should
        // be one out of those 60 entries") - `zone`/`value` stay
        // permanently null under Worm10 (a Worm10Event carries no
        // RSI-zone/price fields at all - same as they already were under
        // worm_9_26's later revisions).
        entrySignalStore.recordOpen(
          newBuOrderId,
          base: base,
          direction: direction.wireValue,
          // TradingView's own bar time, not wall-clock - see the matching
          // comment on `entrySignalStore.recordClose` above.
          at: DateTime.fromMillisecondsSinceEpoch(confirmedEvent.time * 1000),
          type: confirmedEvent.kind.name,
          zone: null,
          value: null,
        );
        // Only removed now that Pionex has actually accepted a real
        // createFuturesGrid call using this amount - see the matching
        // comment where `investment` is first read, above.
        _nextInvestmentByPair.remove(entryKey);
        _persistPendingInvestment(base, category, null);
        createdBots.rememberBot(newBuOrderId);
        botCategories.setCategory(newBuOrderId, category);
        // Bug fixed 2026-09-11, live (per the user: "this bot ... recently
        // opened in 3m and it is tagged last??? why" / "i did not tag it
        // last"): a brand-new grid just got created for `base`, but nothing
        // here ever cleared a STALE "Last" mark left over from that base's
        // earlier life - RetiredStore is keyed purely by base name, not by
        // buOrderId, so an old retirement kept silently applying to every
        // future, completely unrelated bot on the same base forever,
        // showing the "Last" tag on a grid the user never touched. Same
        // fix, same rationale `convertManualToAuto` already had ("clears
        // any stale Last mark... converting it back in is an explicit
        // re-enable, it should never stay silently blocked from ever
        // reopening") - a genuinely new grid is exactly as explicit a
        // re-enable as that conversion was.
        retired.removeRetiredBases([(base: base, category: category)]);
        if (lvl.widenApplied) widenApplied.markWidened(newBuOrderId);
        // Marks this base as the app's ongoing responsibility - unlike
        // createdBots (which forgets this specific id the moment THIS bot
        // closes), this stays set through a signal-flip close so the very
        // next auto-checkup reopens the pair fresh, per the user's
        // close-then-reopen spec.
        autoManagedByCategory[category]!.addBase(base);
        // Per the user (2026-09-11): "next trade show all red list items...
        // has nothing to do with auto trade list" - a pair that just got a
        // real bot is STILL shown in Next Trade now (matches every other
        // already-running pair, per today's fix), so this used to remove
        // the candidate row it merged moments ago - that's now wrong on
        // purpose, doubly so (this used to fire TWICE in a row here, a
        // leftover duplicate from before that removal existed at all).
        // Both calls removed: the row just stays showing the preview this
        // pass already computed until the next check refreshes it as
        // "already running" data, with no gap in between.
        final runningEntry = RunningBotCheck(
          symbol: symbol,
          base: base,
          buOrderId: newBuOrderId,
          botDirection: direction,
          latestEventType: confirmedEvent.kind,
        );
        _runningBotsReportEntries.add(runningEntry);
        _mergeRunningBotsEntry(runningEntry);
        // CHANGED 2026-09-15, per the user: a timeout here is no longer
        // treated as a failure (no `risk.closePosition`, no "failed" note)
        // - that used to undo local tracking on a mere guess, before Pionex
        // ever confirmed anything. The position stays counted and tracked
        // exactly as it was the moment `createFuturesGrid` succeeded; the
        // normal reconciliation loop resolves the real outcome once Pionex
        // actually reports one.
        await _waitForGridRunning(symbol, newBuOrderId, entryKey);
        break;
      } catch (e) {
        createSw.stop();
        logger.log('GRID CREATE FAILED $symbol (attempt $attempt): $e');
        // Diagnostic only (2026-09-14), investigating the universal
        // BOT_INTERNAL_ERROR on every create attempt - the raw response
        // body isn't normally logged, just the trimmed message. Temporary:
        // remove once the real cause is found.
        if (e is ApiException && e.rawBody != null) {
          logger.log('GRID CREATE FAILED $symbol RAW: ${e.rawBody}');
        }
        // Diagnostic only (2026-09-14, per an external review) - same
        // fields as the success-path log above, captured on failure too so
        // the two can be diffed directly against each other.
        logger.log(
          'GRID CREATE $symbol DIAGNOSTIC (attempt $attempt, FAILED): '
          'httpStatus=$createStatusCode durationMs=${createSw.elapsedMilliseconds} '
          'sinceCheckParamsMs=$sinceCheckParamsMs freeUsdtBefore=$lastKnownFreeUsdt '
          'marketPrice=$trigger '
          'headers=${_diagnosticHeaders(createHeaders)}',
        );
        logger.log(
          'GRID CREATE $symbol DEBUG buOrderData: ${jsonEncode(buOrderData)}',
        );
        if (!triedNaturalFallback &&
            lvl.widenApplied &&
            (range.top != naturalTop || range.bottom != naturalBottom) &&
            // CRITICAL, added 2026-09-15, per the user - the shift's own
            // math only guarantees the SHIFTED range contains price;
            // falling back to the pre-shift natural range re-introduces
            // whatever the raw zigzag read produced, which is exactly
            // what was garbage in the live BTCUSDT incident. Same sanity
            // check as the other two checkpoints, applied here too before
            // spending a re-probe on a range that would open paused.
            trigger >= naturalBottom &&
            trigger <= naturalTop) {
          triedNaturalFallback = true;
          logger.log(
            'GRID CREATE $symbol: shifted range rejected - falling back to the natural range [$naturalBottom..$naturalTop] per the user\'s spec, before any percentage shrink.',
          );
          try {
            final reprobe = await pionex.checkFuturesGrid(
              base: futuresBase,
              quote: 'USDT',
              buOrderData: {
                'top': naturalTop.toString(),
                'bottom': naturalBottom.toString(),
                'row': row,
                'grid_type': 'arithmetic',
                'trend': direction.wireValue,
                'leverage': leverage,
                'quoteInvestment': investment.toString(),
                'extraMargin': true,
              },
            );
            lastCheckParamsAt = DateTime.now();
            final actual = double.tryParse('${reprobe['estimateInvestment']}');
            final reserve = double.tryParse(
              '${reprobe['estimateExtraMargin']}',
            );
            if (actual == null || actual <= 0 || reserve == null || reserve < 0) {
              logger.log(
                'GRID CREATE $symbol: natural-range re-probe returned no usable investment/extraMargin split - falling through to the shrink ladder instead.',
              );
            } else {
              var total = actual + reserve;
              double free = double.infinity;
              try {
                free = (await pionex.getBalance('USDT')).free;
                lastKnownFreeUsdt = free;
              } catch (e2) {
                logger.log(
                  'GRID CREATE $symbol: balance read error $e2 during natural-range re-probe - proceeding unclamped',
                );
              }
              var effReserve = reserve;
              if (free.isFinite && total > free) {
                effReserve = ((free - actual) * 10000).floor() / 10000;
                effReserve = effReserve < 0 ? 0 : effReserve;
                total = actual + effReserve;
              }
              if (effReserve <= actual) {
                logger.log(
                  'GRID CREATE $symbol: natural-range re-probe margin-safety check failed '
                  '(extraMargin $effReserve must exceed actual investment $actual) - falling through to the shrink ladder instead.',
                );
              } else {
                range = range.copyWith(top: naturalTop, bottom: naturalBottom);
                quoteInvestment = actual.toString();
                extraMargin = effReserve.toString();
                buOrderData['top'] = naturalTop.toString();
                buOrderData['bottom'] = naturalBottom.toString();
                buOrderData['quoteInvestment'] = quoteInvestment;
                buOrderData['extraMargin'] = extraMargin;
                logger.log(
                  'GRID CREATE $symbol: natural range re-probed via checkParams -> actual=$actual reserve=$effReserve (total $total) - retrying create.',
                );
                continue;
              }
            }
          } on RateLimitException catch (e2) {
            logger.log(
              'GRID CREATE $symbol: rate limited during natural-range re-probe${e2.retryAfter != null ? ' (retry after ${e2.retryAfter!.inSeconds}s)' : ''} - falling through to the shrink ladder instead.',
            );
          } catch (e2) {
            logger.log(
              'GRID CREATE $symbol: natural-range re-probe failed ($e2) - falling through to the shrink ladder instead.',
            );
          }
        }
        final shrunk = shrinkRangeForRetry(
          originalTop: originalTop,
          originalBottom: originalBottom,
          direction: direction,
          attempt: shrinkCount + 1,
        );
        if (shrunk == null) {
          brain.recordTrade({
            'type': 'grid',
            'pair': symbol,
            'status': 'failed',
            'error': e.toString(),
          });
          break;
        }
        shrinkCount++;
        // CRITICAL, added 2026-09-15, per the user - same sanity check as
        // the one before the first attempt: `shrinkRangeForRetry` cuts
        // purely by percentage of the ORIGINAL edges, with zero awareness
        // of where the current price actually is, so a shrunk range can
        // easily end up excluding it entirely. Checked before spending a
        // re-probe/create call on a range that would just open paused.
        if (trigger < shrunk.bottom || trigger > shrunk.top) {
          logger.log(
            'RANGE SANITY $symbol: REFUSING shrink retry #$shrinkCount - '
            'current price $trigger would be outside [${shrunk.bottom}..${shrunk.top}] '
            '- giving up this cycle rather than opening paused.',
            level: 'ERROR',
          );
          brain.recordTrade({
            'type': 'grid',
            'pair': symbol,
            'status': 'failed',
            'error': 'shrunk range would exclude current price',
          });
          break;
        }
        range = range.copyWith(top: shrunk.top, bottom: shrunk.bottom);
        buOrderData['top'] = shrunk.top.toString();
        buOrderData['bottom'] = shrunk.bottom.toString();
        logger.log(
          'RANGE SHRINK $symbol: ${direction.wireValue} retry #$shrinkCount -> top=${shrunk.top} bottom=${shrunk.bottom}',
        );
        // Bug fixed 2026-09-14, per the user: row/quoteInvestment/extraMargin
        // were computed ONCE, upfront, via checkParams for the ORIGINAL
        // range - every shrink retry above only updated top/bottom and kept
        // reusing those now-stale numbers against a narrower range, which
        // is almost certainly what turned into Pionex's own
        // BOT_INTERNAL_ERROR on create (confirmed live: SOLUSDT, 10/10
        // attempts). The user's own spec: TradingView trigger -> range +
        // investment -> checkParams to Pionex -> Pionex confirms actual
        // investment/extraMargin/row for THAT data -> only then create.
        // That sequence ran once; it must re-run for every shrunk range,
        // not just the first. Re-probes with the SAME row (the range
        // narrowed, not the grid count) and refuses this shrink (same
        // safety bar as the original probe: extra margin must exceed
        // actual investment) rather than retrying create with stale
        // numbers again.
        try {
          final reprobe = await pionex.checkFuturesGrid(
            base: futuresBase,
            quote: 'USDT',
            buOrderData: {
              'top': shrunk.top.toString(),
              'bottom': shrunk.bottom.toString(),
              'row': row,
              'grid_type': 'arithmetic',
              'trend': direction.wireValue,
              'leverage': leverage,
              'quoteInvestment': investment.toString(),
              'extraMargin': true,
            },
          );
          lastCheckParamsAt = DateTime.now();
          final actual = double.tryParse('${reprobe['estimateInvestment']}');
          final reserve = double.tryParse('${reprobe['estimateExtraMargin']}');
          if (actual == null || actual <= 0 || reserve == null || reserve < 0) {
            logger.log(
              'RANGE SHRINK $symbol: checkParams re-probe for the shrunk range returned no usable investment/extraMargin split - refusing rather than retrying create with stale numbers.',
            );
            break;
          }
          var total = actual + reserve;
          double free = double.infinity;
          try {
            free = (await pionex.getBalance('USDT')).free;
            lastKnownFreeUsdt = free;
          } catch (e2) {
            logger.log(
              'RANGE SHRINK $symbol: balance read error $e2 during re-probe - proceeding unclamped',
            );
          }
          var effReserve = reserve;
          if (free.isFinite && total > free) {
            effReserve = ((free - actual) * 10000).floor() / 10000;
            effReserve = effReserve < 0 ? 0 : effReserve;
            total = actual + effReserve;
          }
          if (effReserve <= actual) {
            logger.log(
              'RANGE SHRINK $symbol: REFUSING to retry - re-probed extra margin '
              '($effReserve) must be greater than actual investment ($actual) '
              'per the mandatory margin-safety rule, same as the original probe.',
            );
            break;
          }
          quoteInvestment = actual.toString();
          extraMargin = effReserve.toString();
          buOrderData['quoteInvestment'] = quoteInvestment;
          buOrderData['extraMargin'] = extraMargin;
          logger.log(
            'RANGE SHRINK $symbol: re-probed via checkParams -> actual=$actual reserve=$effReserve (total $total)',
          );
        } on RateLimitException catch (e2) {
          logger.log(
            'RANGE SHRINK $symbol: rate limited during checkParams re-probe${e2.retryAfter != null ? ' (retry after ${e2.retryAfter!.inSeconds}s)' : ''} - refusing this shrink attempt.',
          );
          break;
        } catch (e2) {
          logger.log(
            'RANGE SHRINK $symbol: checkParams re-probe failed ($e2) - refusing rather than retrying create with stale numbers.',
          );
          break;
        }
      }
    }
  }

  /// Merges one pair's fresh preview into the persisted Next Trade report
  /// immediately, instead of only writing once at the end of the full
  /// sweep - every other pair's most-recently-known entry is left exactly
  /// as-is. Still safe for a concurrent GUI read: [CoreStorage.writeJson]
  /// is a temp-file-then-rename swap, so this is just a smaller, more
  /// frequent version of the same atomic write the end-of-cycle pass
  /// already did, not a new risk.
  void _mergeLastReportEntry(PreviewGridPair entry) {
    final current = LastReport.fromJson(
      storage.readJsonObject(storage.lastReportFile) ??
          const <String, dynamic>{},
    );
    storage.writeJson(
      storage.lastReportFile,
      LastReport(
        generatedAtMs: DateTime.now().millisecondsSinceEpoch,
        entries: [
          // Keyed by (base, category) - a base can carry up to 3 entries in
          // the same report, one per category, since Check Now now computes
          // all 3 (2026-09-08). Only the ONE entry matching both this base
          // AND this category gets replaced; the other categories' entries
          // for the same base are untouched.
          for (final e in current.entries)
            if (!(e.base == entry.base && e.category == entry.category)) e,
          entry,
        ],
        unlisted: current.unlisted,
        // Per the user (2026-09-11): a base's "-" placeholder row is only
        // meant to last until it's actually been visited - the very first
        // real preview for ANY of its categories means it's no longer
        // "not yet pulled", even if the other 2 categories still are.
        pending: current.pending
            .where((p) => p.base != entry.base)
            .toList(),
      ).toJson(),
    );
  }

  /// "Once check now occurs" (2026-09-11, per the user): reconciles the
  /// persisted Next Trade report against the just-read red list BEFORE the
  /// sequential per-pair sweep below even starts, so the table reflects
  /// reality immediately rather than only catching up pair-by-pair as the
  /// (possibly slow, possibly interrupted) sweep reaches each one. Two
  /// halves:
  ///  - Every entry/pending row whose base is no longer on the red list at
  ///    all gets dropped right away.
  ///  - Every red-list base with no existing entry (under any category)
  ///    gets a new [PendingRedListPair] placeholder - the "-" row - unless
  ///    it's unlisted on Pionex (goes to `unlisted` instead, same as the
  ///    main loop's own check) or retired with no running grid (never a
  ///    candidate at all, matches the main loop's own skip further down).
  /// Cheap and network-free (no chart, no Pionex calls) - just a diff
  /// against the red list already in hand.
  /// When this last ran - gates [_reconcilePnlSettlement] to at most once
  /// every [_pnlSettlementInterval], since a full run means one real Pionex
  /// API cost (see that method's doc).
  DateTime? _lastPnlSettlementAt;
  static const _pnlSettlementInterval = Duration(minutes: 15);

  /// Patches recent History entries' `realizedProfit` to match Pionex's own
  /// now-settled totals (2026-09-11, per the user, live account: "i went to
  /// the history in pionex and i found that p&l is different from what you
  /// type here in app" / "terminated bots in app data should match with
  /// terminated bots in pionex history").
  ///
  /// Root cause (confirmed live, not guessed): every close path reads
  /// `pionex.getGridPnl` right after the close/cancel call completes and
  /// records that as final - but Pionex does NOT finish computing
  /// `totalRealizedProfit` synchronously with the cancel response. The
  /// order sits under status `running` a little longer while Pionex settles
  /// it, then moves to `finished` with the true number. Confirmed with a
  /// live example: BCHUSDT's own close still read exactly 0.0 the instant
  /// its cancel call returned, but had a real settled -0.0162 under a
  /// minute later. A one-time backfill (2026-09-11) already corrected every
  /// existing entry from a full audit against live Pionex data (317
  /// entries patched, 10 phantom "Last" P/Ls nulled, 1 true duplicate
  /// removed) - this keeps it accurate going forward for every close from
  /// here on, without that drift silently re-accumulating.
  ///
  /// Deliberately NOT done synchronously in the close path itself: Pionex
  /// exposes no way to look up a single order by id server-side, and no
  /// working `base`/symbol filter either (confirmed live - passing `base`
  /// returned the SAME ~800 unfiltered results as no filter at all) - the
  /// only way to check even one order's settled total is to page through
  /// the ENTIRE `finished` list (paginated at 10/page; ~800 orders is
  /// already ~80 sequential requests, ~24s). Retrying that per-close would
  /// stall the main loop for many pairs in a row on an active day. Instead
  /// this pays that cost ONCE per sweep and reconciles every recent entry
  /// against it in one pass, throttled to at most once every
  /// [_pnlSettlementInterval] so it's a cheap no-op the rest of the time.
  /// Only entries younger than [_pnlSettlementWindow] are rescanned each
  /// time, since older ones have long since settled and were already
  /// covered by either an earlier sweep or the one-time backfill.
  Future<void> _reconcilePnlSettlement() async {
    final now = DateTime.now();
    if (_lastPnlSettlementAt != null &&
        now.difference(_lastPnlSettlementAt!) < _pnlSettlementInterval) {
      return;
    }
    _lastPnlSettlementAt = now;
    if (!pionex.available) return;
    List<Map<String, dynamic>> finished;
    try {
      // Bug fixed 2026-09-18, live (per the user: "double check everything
      // in sum... compare bots history p&l with what is there in pionex" -
      // found the sweep had gone completely silent for 2h42m, then 8+
      // hours straight, with no success AND no failure logged either).
      // Root cause: `PionexClient` has no request timeout anywhere in its
      // stack - if a single HTTP call inside `listBotOrders`'s pagination
      // genuinely hangs (no response, no exception, just an eternally
      // pending Future), `await` sits forever, the existing try/catch
      // never triggers (nothing was ever thrown), and `_lastPnlSettlementAt`
      // stays set to the moment the hang began - blocking every future
      // tick's throttle check from ever getting a clean shot, silently,
      // with zero trace in engine.log. A `.timeout()` here turns a hang
      // into a real, catchable exception, so this stays self-healing every
      // 15 minutes instead of needing a full engine restart to recover.
      // 120s, not 30s: `listBotOrders('finished')` paginates 10/page
      // sequentially - already ~1400+ orders on this account (~140
      // requests), and only grows over time. The goal here is catching a
      // genuine indefinite hang (the observed symptom - hours of total
      // silence), not racing a legitimately-slow-but-working full fetch.
      finished = await pionex
          .listBotOrders(status: 'finished', buOrderTypes: 'futures_grid')
          .timeout(const Duration(seconds: 120));
    } catch (e) {
      logger.log('PNL SETTLEMENT sweep: fetching the finished list failed ($e) - skipping this pass.');
      return;
    }
    double? numOf(Object? v) {
      if (v == null || v == '') return null;
      if (v is num) return v.toDouble();
      final cleaned = v.toString().replaceAll(RegExp(r'[^\d.\-]'), '');
      return double.tryParse(cleaned);
    }

    final live = <String, double?>{};
    for (final o in finished) {
      final data = (o['buOrderData'] as Map?)?.cast<String, dynamic>() ?? const {};
      final id = (o['buOrderId'] ?? data['buOrderId'])?.toString();
      if (id == null) continue;
      // Bug fixed 2026-09-13, live (per the user: BCHUSDT showing $0.00 in
      // the app vs $0.00413 on Pionex) - this used to take
      // totalRealizedProfit/gridProfit/profitWithdrawn alone, exactly the
      // same "missing totalFee" bug fixed everywhere else in getGridPnl
      // (see its own doc: every closed bot's recorded P&L was silently
      // missing its own trading fees). This sweep is what's supposed to
      // catch up a P/L read too early (Pionex settles asynchronously,
      // documented above) - patching with a fee-EXCLUDING number would
      // have replaced one wrong value with another, never actually
      // matching Pionex's own displayed total. `totalFee` already carries
      // its own sign, so it's added directly, matching getGridPnl exactly.
      final base = numOf(data['totalRealizedProfit'] ?? o['totalRealizedProfit']) ??
          numOf(data['gridProfit'] ?? o['gridProfit']) ??
          numOf(data['profitWithdrawn'] ?? o['profitWithdrawn']);
      live[id] = base == null
          ? null
          : base + (numOf(data['totalFee'] ?? o['totalFee']) ?? 0);
    }

    final cutoff = now.subtract(_pnlSettlementWindow);
    final before = storage.readJsonl(storage.botHistoryFile);
    var patched = 0;
    final out = <Map<String, dynamic>>[
      for (final raw in before)
        _maybePatchPnl(raw, live, cutoff, onPatched: () => patched++),
    ];
    if (patched == 0) return;

    // Same race guard as the one-time backfill: re-read immediately before
    // writing and carry over, unmodified, any entries the live close paths
    // appended while this sweep's ~24s fetch was in flight.
    final fresh = storage.readJsonl(storage.botHistoryFile);
    final newTail = fresh.length > before.length
        ? fresh.sublist(before.length)
        : const <Map<String, dynamic>>[];
    storage.writeJsonl(storage.botHistoryFile, [...out, ...newTail]);
    logger.log(
      'PNL SETTLEMENT sweep: patched $patched recent history ${patched == 1 ? 'entry' : 'entries'} with Pionex-settled totals.',
    );
  }

  // Widened 2026-09-17, live (per the user's "double check the recycled
  // money and the sum" audit): with the sweep never actually firing (see
  // _pnlSettlementTimer's doc), some real entries were still settling to a
  // very different (sometimes sign-flipped) total well past the old 3-hour
  // cutoff by the time they were finally checked - no hard evidence 3h was
  // ever actually enough, since the sweep never got the chance to test it.
  // 24h costs nothing extra (the finished-list fetch already happens once
  // per sweep regardless of window size; this only widens which ALREADY-
  // FETCHED entries get rescanned) and gives real settlement far more room.
  static const _pnlSettlementWindow = Duration(hours: 24);

  Map<String, dynamic> _maybePatchPnl(
    Map<String, dynamic> raw,
    Map<String, double?> live,
    DateTime cutoff, {
    required void Function() onPatched,
  }) {
    if (raw['kind'] == 'last') return raw;
    final id = raw['buOrderId'] as String?;
    if (id == null || !live.containsKey(id)) return raw;
    final ts = DateTime.tryParse(raw['ts'] as String? ?? '');
    if (ts == null || ts.isBefore(cutoff)) return raw;
    final liveVal = live[id];
    if (liveVal == null) return raw;
    final recorded = (raw['realizedProfit'] as num?)?.toDouble();
    if (recorded != null && (recorded - liveVal).abs() < 0.0000001) return raw;
    onPatched();
    return {...raw, 'realizedProfit': liveVal};
  }

  void _reconcileNextTradeWithRedList(
    List<String> pairUniverse,
    Set<String> persistentRetired,
  ) {
    final redListBases = pairUniverse.map(_baseOf).map((b) => b.toUpperCase()).toSet();
    final current = LastReport.fromJson(
      storage.readJsonObject(storage.lastReportFile) ??
          const <String, dynamic>{},
    );
    final keptEntries = current.entries
        .where((e) => redListBases.contains(e.base.toUpperCase()))
        .toList();
    final keptPending = current.pending
        .where((p) => redListBases.contains(p.base.toUpperCase()))
        .toList();
    final knownBases = {
      ...keptEntries.map((e) => e.base.toUpperCase()),
      ...keptPending.map((p) => p.base.toUpperCase()),
    };
    final newUnlisted = <UnlistedRedListPair>[];
    final newPending = <PendingRedListPair>[...keptPending];
    for (final symbol in pairUniverse) {
      final base = _baseOf(symbol);
      final baseUpper = base.toUpperCase();
      final key = _gridKey(base);
      if (!_anyGridForKey(key) && _isUnlistedOnPionexFutures(symbol)) {
        newUnlisted.add(UnlistedRedListPair(symbol: symbol, base: base));
        continue;
      }
      if (knownBases.contains(baseUpper)) continue;
      // REVERSED 2026-09-12, per the user ("retired pairs should be shown
      // in next trade list... but dont vanish them"): this used to skip a
      // retired-with-no-grid base entirely here too (matching the main
      // loop's own skip further up), so it never even got a "-"
      // placeholder - fully invisible. The main loop's own skip (which
      // never calls _manageGridPair for a retired base with no grid) is
      // untouched, so a retired base still never gets a real preview
      // computed and never auto-reopens - it just now gets the SAME "-"
      // placeholder every other not-yet-computed red-list pair gets,
      // instead of no row at all. A retired base that DOES still have a
      // running grid already showed correctly before this fix (via the
      // knownBases check above) and is unaffected - its knob already
      // renders yellow/blocked via the existing, fully generic
      // `_blockedByBase` (driven by `status.grids.appRunning`, keyed by
      // category tag alone - never checks retired status), so no GUI
      // change was needed for that half of the request.
      newPending.add(PendingRedListPair(symbol: symbol, base: base));
      knownBases.add(baseUpper);
    }
    storage.writeJson(
      storage.lastReportFile,
      LastReport(
        generatedAtMs: current.generatedAtMs,
        entries: keptEntries,
        unlisted: newUnlisted,
        pending: newPending,
      ).toJson(),
    );
    logger.log(
      'mainLoop: reconciled Next Trade with the red list - '
      '${newPending.length - keptPending.length} new pending, '
      '${current.entries.length - keptEntries.length} entries dropped, '
      '${current.pending.length - keptPending.length} pending dropped (no longer on red list).',
    );
  }

  /// Merges one pair's fresh running-bot signal check into the persisted
  /// Auto Bots report immediately - same reasoning as
  /// [_mergeLastReportEntry].
  void _mergeRunningBotsEntry(RunningBotCheck entry) {
    final current = RunningBotsReport.fromJson(
      storage.readJsonObject(storage.runningBotsReportFile) ??
          const <String, dynamic>{},
    );
    storage.writeJson(
      storage.runningBotsReportFile,
      RunningBotsReport(
        generatedAtMs: DateTime.now().millisecondsSinceEpoch,
        entries: [
          for (final e in current.entries)
            if (e.base != entry.base) e,
          entry,
        ],
      ).toJson(),
    );
  }

  /// Captures a read-only preview of this candidate for the dashboard's
  /// "Last report" checklist, independent of whether the engine actually
  /// opens it (decided further below by the risk gate / dry-run check). In
  /// live mode this just reuses the numbers already probed above — zero
  /// extra API calls. In confirm mode it runs its own supplemental
  /// checkParams probe so the preview is still accurate even though the
  /// engine itself won't act on this pair — checkParams is a Pionex-side
  /// dry-run validation call that never creates anything, so this is safe
  /// to run regardless of mode.
  /// Empirically finds a top/bottom rounding Pionex's checkParams accepts
  /// for [futuresBase] - see the call site's comment in `_manageGridPair`
  /// for the full story. Tries 8 decimals down to 0, stopping at the first
  /// one that doesn't fail with a "quote precision" error (a `row` of
  /// [config.technique.minGrids] is used purely to make a valid probe call;
  /// it has no bearing on the price precision Pionex is checking here).
  /// Returns null only if nothing from 8 down to 0 decimals is accepted -
  /// genuinely unrecoverable for this pair right now, not something to
  /// guess past.
  /// Bug fixed/extended 2026-09-14, per the user's real-liquidation-price
  /// 60/40 spec: this already made a real `checkFuturesGrid` probe at
  /// `row: config.technique.minGrids` (3) purely to find an accepted
  /// decimal precision, then discarded the response. That response also
  /// carries Pionex's own `estimateLiquidationPriceUp`/`...Down` fields -
  /// exactly the "3 number of grids as initial calculation" probe the user
  /// described - so this now returns that too, instead of a second,
  /// redundant Pionex call.
  Future<({double top, double bottom, double? liquidationPrice})?>
  _resolveQuotePrecision({
    required String futuresBase,
    required double top,
    required double bottom,
    required GridDirection direction,
    required double leverage,
    required String investment,
  }) async {
    for (var decimals = 8; decimals >= 0; decimals--) {
      final roundedTop = double.parse(top.toStringAsFixed(decimals));
      final roundedBottom = double.parse(bottom.toStringAsFixed(decimals));
      if (roundedTop <= roundedBottom) continue;
      try {
        final resp = await pionex.checkFuturesGrid(
          base: futuresBase,
          quote: 'USDT',
          buOrderData: {
            'top': roundedTop.toString(),
            'bottom': roundedBottom.toString(),
            'row': config.technique.minGrids,
            'grid_type': 'arithmetic',
            'trend': direction.wireValue,
            'leverage': leverage,
            'quoteInvestment': investment,
          },
        );
        final liquidationPrice = double.tryParse(
          '${direction == GridDirection.long ? resp['estimateLiquidationPriceDown'] : resp['estimateLiquidationPriceUp']}',
        );
        return (
          top: roundedTop,
          bottom: roundedBottom,
          liquidationPrice: liquidationPrice,
        );
      } on RateLimitException {
        return null;
      } catch (e) {
        if ('$e'.toLowerCase().contains('quote precision')) continue;
        rethrow;
      }
    }
    return null;
  }

  Future<void> _recordReportPreview({
    required String symbol,
    required String base,
    required String futuresBase,
    required GridDirection direction,
    required RangeResult range,
    required LiquidationLevels lvl,
    required double maxLev,
    required double leverage,
    required double trigger,
    required double investment,
    required bool autoReserve,
    required bool isDryRun,
    required int liveRow,
    required String liveActualInvestment,
    required String? liveExtraMargin,
    required double? liveLiquidationPreview,
    required AutoCategory category,
  }) async {
    var row = liveRow;
    var actualInvestment = double.tryParse(liveActualInvestment);
    var extraMargin = liveExtraMargin == null
        ? null
        : double.tryParse(liveExtraMargin);
    var liquidationPrice = liveLiquidationPreview;

    if (isDryRun) {
      try {
        Map<String, dynamic>? probeResponse;
        row = await probeMaxGridCount(
          minGrids: config.technique.minGrids,
          maxGrids: config.technique.effectiveMaxGrids,
          checkRowValid: (candidate) async {
            try {
              final resp = await pionex.checkFuturesGrid(
                base: futuresBase,
                quote: 'USDT',
                buOrderData: {
                  'top': range.top.toString(),
                  'bottom': range.bottom.toString(),
                  'row': candidate,
                  'grid_type': 'arithmetic',
                  'trend': direction.wireValue,
                  'leverage': leverage,
                  'quoteInvestment': investment.toString(),
                  if (autoReserve) 'extraMargin': true,
                },
              );
              probeResponse = resp;
              return true;
            } on RateLimitException {
              rethrow; // abort the whole probe sequence, not just this row
            } catch (e) {
              // Bug fixed 2026-09-09: was silent - see the identical fix in
              // _computeCategoryCheckPreview for the full reasoning.
              logger.log(
                'REPORT PREVIEW $symbol[${category.label}]: row=$candidate rejected by Pionex checkFuturesGrid: $e',
              );
              return false;
            }
          },
        );
        if (probeResponse != null) {
          actualInvestment =
              double.tryParse('${probeResponse!['estimateInvestment']}') ??
              actualInvestment;
          extraMargin = double.tryParse(
            '${probeResponse!['estimateExtraMargin']}',
          );
          liquidationPrice = direction == GridDirection.long
              ? double.tryParse(
                  '${probeResponse!['estimateLiquidationPriceDown']}',
                )
              : double.tryParse(
                  '${probeResponse!['estimateLiquidationPriceUp']}',
                );
        }
      } catch (e) {
        logger.log(
          'REPORT PREVIEW $symbol: checkParams probe failed ($e) - preview will show a rough estimate',
        );
      }
    }

    final preview = PreviewGridPair(
      symbol: symbol,
      base: base,
      quote: 'USDT',
      direction: direction,
      top: range.top,
      bottom: range.bottom,
      stable: lvl.stable,
      widenApplied: lvl.widenApplied,
      takeProfitPrice: lvl.takeProfitPrice,
      stopLossPrice: lvl.stopLossPrice,
      maxLeverage: maxLev,
      leverage: leverage,
      gridCount: row,
      entryPrice: trigger,
      actualInvestment: actualInvestment,
      extraMargin: extraMargin,
      liquidationPrice: liquidationPrice,
      category: category,
    );
    // Instant update: persist this ONE pair's fresh preview right now,
    // rather than waiting for the rest of the Red-list sweep to finish -
    // the dashboard picks it up on its next 5s poll instead of only once
    // the whole checkup completes.
    _mergeLastReportEntry(preview);
  }

  /// [resolution] is the MSB/OB price-range timeframe - 'D' (Daily) for the
  /// original/1H category; per-category callers pass their own
  /// [AutoCategory.rangeResolution] instead (2026-09-07).
  Future<List<ZigzagSegment>?> _readZigzagLines(
    String symbol, {
    String resolution = 'D',
  }) async {
    if (!(await _ensureCustomScripts())) return null;
    final switched = await setChartView(_cdp!, symbol, resolution);
    if (!switched.ok) {
      logger.log(
        'CHART SWITCH FAILED to $symbol $resolution: ${switched.error ?? 'timeout'}',
      );
      return null;
    }
    // Bug fixed 2026-09-16, per the user ("tried with eth and with btc
    // clicked thunder icon... still not ok"): setChartView only waits for
    // the chart to confirm the new symbol/resolution - it says nothing
    // about whether the Daily MSB/OB custom-script's zigzag overlay has
    // finished redrawing on it yet. This used to read the drawing lines
    // immediately after switching, with no retry - unlike the signal read
    // just above (_checkBuySellOnPair), which already waits up to 30s for
    // its indicator. Confirmed live: "SKIP $symbol: no price range..."
    // fired 103 times in one day across BTC/ETH/DOGE/DOT, purely from
    // reading the overlay a beat too early, not from a genuinely absent
    // range. Retrying for a few seconds before giving up matches the same
    // wait-for-indicator discipline used elsewhere in this file.
    const budgetSec = 8;
    final started = DateTime.now();
    while (true) {
      final lines = await readLines(_cdp!, customScripts[0].scriptIdPart);
      final usable = lines.where((l) => !l.horizontal && l.y1 != l.y2);
      if (usable.isNotEmpty) return lines;
      if (DateTime.now().difference(started).inSeconds >= budgetSec) {
        logger.log(
          'ZIGZAG WAIT $symbol $resolution: MSB/OB overlay had no usable lines after ${budgetSec}s - giving up.',
        );
        return lines;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1000));
    }
  }
}

/// Finds the chart legend's "Flag symbol"/"Unflag symbol" toggle button
/// (see `_toggleRedListFlag`) - confirmed via live DOM inspection
/// (2026-09-01) to be a real, self-labeling `title` attribute, not a guess.
/// Assumed (not yet independently proven) that the flag applies to
/// whichever colored watchlist tab is currently active in the panel - this
/// app always leaves "Red list" selected there, but `_toggleRedListFlag`
/// re-reads the actual watchlist afterward regardless, so a wrong
/// assumption here shows up as a reported failure, never a false success.
const _findFlagButtonExpr = '''(function() {
  var btns = document.querySelectorAll('button[title="Flag symbol"], button[title="Unflag symbol"]');
  for (var i = 0; i < btns.length; i++) {
    var el = btns[i];
    if (el.offsetParent === null) continue;
    var r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) continue;
    return { button: { title: el.getAttribute('title'), x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) } };
  }
  return { button: null };
})()''';
