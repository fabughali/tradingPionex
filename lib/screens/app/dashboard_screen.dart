import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/core_layout.dart';
import '../../core/core_spacing.dart';
import '../../core/core_theme.dart';
import '../../data/control/engine_control_repository.dart';
import '../../data/tradingview/tv_sync.dart';
import '../../data/models/auto_category.dart';
import '../../data/models/grid_bot.dart';
import '../../data/providers/app_providers.dart';
import '../../l10n/app_localizations.dart';
import '../../utilities/util_date.dart';
import '../../utilities/util_string.dart';
import '../../widgets/power_off_confirm.dart';
import '../../widgets/category_knob.dart';
import '../../widgets/grids_table.dart';
import '../../widgets/pnl_summary_view.dart';
import '../../widgets/waiting_bases_view.dart';
import '../../widgets/reuse_card.dart';
import '../../widgets/reuse_chip.dart';
import '../../widgets/reuse_empty_state.dart';
import '../../widgets/reuse_error.dart';
import '../../widgets/reuse_loading_indicator.dart';
import '../../widgets/reuse_status_light.dart';
import '../../widgets/tier_limit_dialog.dart';
import '../../widgets/pulsing_dot.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  @override
  void initState() {
    super.initState();
    // The 1H toggle is gone (per the user, 2026-11-11): Auto always runs 1H,
    // so a 1H pause left over from before is cleared.
    ref.read(controlRepositoryProvider).resumeCategory(AutoCategory.oneHour);
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoPowerOn());
  }

  /// Set once the user switches Power themselves - the automatic Power ON
  /// below then stops and never overrides them.
  bool _userSetPower = false;

  /// The Auto cards' sort, chosen by the icon next to the count.
  CardSort _autoSort = CardSort.aToZ;

  /// App open == Power on (per the user, 2026-11-13 - e.g. after a Windows
  /// restart, when the app starts with Windows). Waits for the launch-time
  /// cleanup, then tries the normal Power ON every 30 s until its checks
  /// pass (TradingView, Pionex, engine). Auto keeps its own saved state.
  Future<void> _autoPowerOn() async {
    await EngineControlRepository.startupCleanup;
    var attempt = 0;
    while (mounted && !_userSetPower) {
      final repo = ref.read(controlRepositoryProvider);
      if (repo.isPowerOn) return;
      attempt++;
      final ok = await _performPowerUp(repo, quiet: attempt > 1);
      if (ok) {
        ref.invalidate(statusReportProvider);
        if (mounted) setState(() {});
        return;
      }
      if (attempt == 1) {
        _notify(
          'Powering on by itself - retrying every 30 s until TradingView and '
          'Pionex are ready.',
          success: false,
        );
      }
      await Future<void>.delayed(const Duration(seconds: 30));
    }
  }

  /// Which action is currently in flight, if any — only that action's button
  /// shows a spinner; every button is disabled while any action is running
  /// (so two actions can never race each other), but only the one actually
  /// running looks busy.
  String? _activeAction;
  bool get _busy => _activeAction != null;

  /// The `buOrderId` of the row whose "Last" toggle was just switched off
  /// (2026-09-11, per the user) - drives that row's spinner while
  /// `EngineControlRepository.unretire` runs.
  String? _cancelLastRowId;

  Future<void> _cancelLast(GridBot bot) async {
    final repo = ref.read(controlRepositoryProvider);
    setState(() => _cancelLastRowId = bot.buOrderId);
    try {
      final bareBase = bot.base
          .toUpperCase()
          .replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '');
      final category =
          repo.botCategories.categoryOf(bot.buOrderId) ?? AutoCategory.oneHour;
      await repo.unretire([bareBase], category);
      ref.invalidate(statusReportProvider);
      ref.invalidate(botHistoryProvider);
      _notify('${bot.pairKey}: "Last" cancelled — back to auto-recreating.', success: true);
    } catch (e) {
      _notify('$e', success: false);
    } finally {
      if (mounted) setState(() => _cancelLastRowId = null);
    }
  }


  /// Gates Check Now/Refresh/Stop-selected/Last-selected - all manual,
  /// on-demand actions that must work independent of Auto's own on/off
  /// state (per the user: Check Now/Start are explicitly Auto-independent
  /// - that's the entire point of the on-demand Checkup track). Only
  /// actually blocks on Power not being ready yet (engine process not
  /// alive) or a local UI action already in flight - NOT on `status.paused`
  /// (Auto off), which used to block these too and defeated their purpose.
  bool _actionsBlocked(StatusReport status, bool engineProcessAlive) =>
      _busy || !engineProcessAlive;


  Timer? _blinkTimer;
  final ValueNotifier<bool> _blink = ValueNotifier(true);
  bool _blinkFast = false;
  String? _lastHealthLabel;

  @override
  void dispose() {
    _blinkTimer?.cancel();
    _blink.dispose();
    super.dispose();
  }

  /// Starts/stops the blink tick on demand — cheap to call on every build
  /// since it's a no-op once the timer already matches what's needed.
  /// [fast] switches to a quicker (180ms) blink for the per-pair indicator
  /// wait-ladder — the one place a single problem pair can stall the whole
  /// cycle, so it earns a more urgent-looking signal than an ordinary busy
  /// phase (500ms).
  void _ensureBlink(bool needed, {bool fast = false}) {
    if (needed && (_blinkTimer == null || _blinkFast != fast)) {
      _blinkTimer?.cancel();
      _blinkFast = fast;
      // Only the blinking status words/switches repaint - not the whole
      // dashboard (found 2026-11-14: a full setState every 180-500 ms, each
      // re-reading files, froze scrolling and resizing during Auto checks).
      _blinkTimer = Timer.periodic(Duration(milliseconds: fast ? 180 : 500), (
        _,
      ) {
        if (mounted) _blink.value = !_blink.value;
      });
    } else if (!needed && _blinkTimer != null) {
      _blinkTimer!.cancel();
      _blinkTimer = null;
      _blink.value = true;
    }
  }

  /// Fires a SnackBar the moment the engine/integration health actually
  /// changes (not on every poll) — deferred a frame since this runs from
  /// inside build().
  void _notifyHealthChange(StatusEvaluation health) {
    // Transient busy/urgent phases (connecting, syncing, waiting on an
    // indicator) come and go every single engine cycle — every one of them
    // was getting compared against the steady-state label underneath, so
    // the moment the cycle finished and reverted to e.g. "TradingView not
    // connected", that counted as a fresh "change" from the last busy
    // message and fired a SnackBar again, every ~5-10s forever. Only the
    // steady (non-blinking) state is worth notifying on — skip updating
    // the tracked label at all while blinking, so it only ever reflects the
    // last real state, and a genuinely stable condition never re-fires.
    if (health.blinking) return;
    final previous = _lastHealthLabel;
    _lastHealthLabel = health.label;
    if (previous == null || previous == health.label) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notify(health.label, success: health.color == StatusLightColor.green);
    });
  }

  Future<void> _run(
    String actionId,
    Future<void> Function() action, {
    String? successMessage,
  }) async {
    setState(() => _activeAction = actionId);
    try {
      await action();
      ref.invalidate(statusReportProvider);
      if (successMessage != null) _notify(successMessage, success: true);
    } catch (e) {
      ref.read(controlRepositoryProvider).logUiOutcome('$e', success: false);
      _notify('$e', success: false);
    } finally {
      if (mounted) setState(() => _activeAction = null);
    }
  }

  /// Confirms before resetting the P&L summary cutoff (2026-09-15, per the
  /// user: "reset icon in sum should not act directly without a
  /// confirming dialog") - same `showDialog<bool>`/`AlertDialog` pattern
  /// `HistoryScreen._confirmClearAll` already uses. Only moves the
  /// summary's cutoff forward - the underlying History record is never
  /// touched, unlike History's own "delete all" - worded accordingly.
  Future<void> _confirmResetPnl(EngineControlRepository repo) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset P&L summary'),
        content: const Text(
          'Start this summary fresh from now? Past closed bots stay in '
          'History untouched - this only moves the sum\'s starting point '
          'forward.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok == true) {
      repo.resetPnlSummary();
      if (mounted) setState(() {});
    }
  }

  /// True while Check Now is re-reading Pionex's market list.

  void _notify(String message, {required bool success}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: success ? null : Theme.of(context).colorScheme.error,
      ),
    );
  }

  /// Triggers CHECKNOW and returns immediately — no waiting, no bottom
  /// sheet. A full sweep checks every Red List pair one at a time (each can
  /// hit the indicator wait-ladder for up to 30s), so blocking the button on
  /// it would hold the whole Quick actions row busy for minutes. The
  /// dashboard's `statusReportProvider` already polls every 5s on its own;
  /// the persistent "Report" section picks up the fresh
  /// `LastReport.generatedAtMs`/entries the moment the sweep actually
  /// finishes, with no extra plumbing needed here.

  /// Power ON: verifies both external connections actually work (auto-
  /// launching TradingView Desktop if it isn't up - see
  /// IntegrationsRepository.testTradingView) before touching anything else -
  /// those are hard blockers, since nothing below can work without them.
  /// Only once both check out does it make sure the engine PROCESS is
  /// running (launching it if needed), then explicitly refreshes
  /// balance/bot-memory against Pionex (`repo.status()` - see
  /// EngineControlRepository.status/refreshSync) and arms a full Red-list
  /// checkup. Deliberately does NOT touch the PAUSE flag - per the user,
  /// Power ON must never turn auto-trading on by itself; only the Auto
  /// switch below does that (which does its own instant check too, so the
  /// armed checkup here just means the very next time Auto gets switched
  /// on, its state is already current). Balance is never a blocker here - a
  /// low/zero free balance still gets the checkup, just with a "no balance"
  /// note in the result, since the checkup covers every Red-list pair
  /// (including whichever ones already have a running auto bot) and is
  /// useful regardless of whether anything new could be opened right now.
  /// Deliberately does NOT pick or start any new pair itself - whatever
  /// happens next to each already-running bot, and whatever candidates show
  /// up for new ones, is purely the checkup's own report; nothing here
  /// auto-starts anything.
  /// Returns whether it actually succeeded.
  Future<bool> _performPowerUp(
    EngineControlRepository repo, {
    bool quiet = false,
  }) async {
    void fail(String message) {
      repo.logUiOutcome(message, success: false);
      if (!quiet) _notify(message, success: false);
    }

    final integrations = ref.read(integrationsRepositoryProvider);
    final cdp = integrations.readCdpConfig();

    final tv = await integrations.testTradingView(
      host: cdp.host,
      port: cdp.port,
    );
    if (!tv.ok) {
      fail('Power-up stopped — ${tv.message}');
      return false;
    }

    final pionex = ref.read(pionexClientProvider);
    double freeBalance;
    try {
      freeBalance = (await pionex.getBalance('USDT')).free;
    } catch (e) {
      fail('Power-up stopped — could not reach Pionex: $e');
      return false;
    }

    if (!await repo.launchEngineIfNeeded()) {
      fail('Power-up stopped — the engine could not start.');
      return false;
    }
    repo.markPowerOn();
    // Power ON never runs a checkup (full or auto) - it only verifies the
    // engine is actually connected and current: balance + auto/manual bot
    // lists refreshed (repo.status()), TradingView reachable with
    // indicators loading (refreshRedList(), which connects and reads the
    // watchlist). Checking anything's SIGNAL is Auto's or Check Now's job.
    await repo.status(); // refreshes balance + re-syncs auto/manual bot lists
    repo.refreshRedList(); // connects to TradingView, verifies indicators load

    final noBalance = freeBalance < 10;
    _notify(
      'Powered up — TradingView and Pionex connected'
      '${noBalance ? ' (no balance to open new pairs — ${UtilString.usd(freeBalance)} free)' : ' (${UtilString.usd(freeBalance)} free)'}. '
      'Switch Auto on to start trading.',
      success: true,
    );
    return true;
  }

  /// Power's tap target, as in tradingMT5. ON: connects and launches the
  /// engine. OFF (after a 5s hold): stops the engine - everything off. Auto
  /// is a separate switch and keeps its state. Running bots stay open on
  /// Pionex, unmonitored until Power is on again.
  void _setPower(
    EngineControlRepository repo,
    StatusReport status,
    bool turnOn,
  ) async {
    _userSetPower = true;
    try {
      if (turnOn) {
        await _performPowerUp(repo);
      } else {
        // Same as tradingMT5: Power off needs a 5-second hold to confirm.
        if (!await confirmPowerOff(context, closingApp: false)) return;
        final stopped = await repo.powerOff();
        _notify(
          stopped
              ? 'Powered down — engine stopped.'
              : 'Powered down, but the engine process would not stop.',
          success: stopped,
        );
      }
      ref.invalidate(statusReportProvider);
    } catch (e) {
      ref.read(controlRepositoryProvider).logUiOutcome('$e', success: false);
      _notify('$e', success: false);
    } finally {
      // Forces a rebuild so the switch re-reads repo.isEngineProcessAlive
      // right away, without a dedicated busy flag or loading indicator.
      if (mounted) setState(() {});
    }
  }

  /// Auto's tap target, as in tradingMT5: a switch of its own, independent
  /// of Power (it can be set with Power off and keeps its state). ON: the
  /// engine does its reverse check of every auto pair (see the engine's
  /// `_reverseCheckIfNeeded`). OFF: the engine reads nothing, opens nothing
  /// and closes nothing until Auto is on.
  void _setAuto(
    EngineControlRepository repo,
    StatusReport status,
    bool turnOn,
  ) {
    _run('auto', () async {
      if (turnOn) {
        repo.resume();
        _notify(
          repo.isEngineProcessAlive
              ? 'Auto on — reverse-checking every auto pair now.'
              : 'Auto on — it starts when Power is on.',
          success: true,
        );
      } else {
        repo.pause();
        _notify(
          'Auto off — nothing is read, opened or closed until Auto is on again. '
          'Stop-loss protection of running bots keeps going.',
          success: true,
        );
      }
    });
  }


  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Keeps the Next Trade star-sort recorder running while the app is open
    // (it records only while Power is on).
    ref.listen(priceMomentumProvider, (_, _) {});
    final statusAsync = ref.watch(statusReportProvider);
    final repo = ref.watch(controlRepositoryProvider);
    final pnl = repo.pnlSummary();

    return Scaffold(
      appBar: AppBar(title: Text(l10n.appTitle)),
      body: statusAsync.when(
        loading: () => const ReuseLoadingIndicator(),
        error: (err, st) => ReuseError(
          message: '$err',
          onRetry: () => ref.invalidate(statusReportProvider),
        ),
        data: (status) {
          final trading = context.tradingColors;
          final engineProcessAlive = repo.isEngineProcessAlive;
          final powerDisplayAlive = engineProcessAlive;
          // Distinct from the shared `busy` flag - that also flickers true
          // during the routine 5s TradingView/indicator health check and
          // Power-on's own one-shot connect, neither of which is a real
          // Checkup sweep. checkupPairTotal is only ever non-zero while (or
          // paused mid-way through) an actual Check Now/Start pass over the
          // Red list, so it's the one true signal for this button/status.
          final checkupRunning = status.engineStatus.checkupPairTotal > 0;
          final powerHealth = ReuseStatusLight.evaluatePower(
            status,
            isEngineProcessAlive: powerDisplayAlive,
            pionexConfigured: status.pionexConfigured,
          );
          final autoHealth = ReuseStatusLight.evaluateAuto(
            status,
            isEngineProcessAlive: engineProcessAlive,
            actionInProgress: _busy,
          );
          _ensureBlink(
            powerHealth.blinking || autoHealth.blinking,
            fast: powerHealth.urgent || autoHealth.urgent,
          );
          _notifyHealthChange(autoHealth);
          final powerBaseColor = ReuseStatusLight.colorFor(
            context,
            powerHealth.color,
          );
          final autoBaseColor = ReuseStatusLight.colorFor(
            context,
            autoHealth.color,
          );
          Color dimmed(Color c, bool blinking, bool on) =>
              blinking && !on ? c.withValues(alpha: 0.35) : c;
          // Read once per refresh, not once per card.
          final checkedNow = repo.checkedThisHourKeys();
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(statusReportProvider),
            child: LayoutBuilder(
              builder: (context, constraints) => ListView(
                padding: CoreLayout.edgeMargin(constraints),
                children: [
                  // Engine status, as in tradingMT5 (per the user,
                  // 2026-11-14): status lights on the left, balances on the
                  // right; the toggles get their own section below.
                  ReuseCard(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _StatusDot(on: engineProcessAlive, label: 'Engine'),
                              const SizedBox(height: 8),
                              _StatusDot(
                                on: engineProcessAlive &&
                                    status.engineStatus.internetHealthy,
                                label: 'Internet',
                              ),
                              const SizedBox(height: 8),
                              _StatusDot(
                                on: engineProcessAlive &&
                                    status.engineStatus.pionexHealthy,
                                label: 'Pionex connected',
                              ),
                              const SizedBox(height: 8),
                              _StatusDot(
                                on: engineProcessAlive &&
                                    status.engineStatus.cdpHealthy,
                                label: 'TradingView connected',
                              ),
                              const SizedBox(height: 8),
                              // tradingMT5 + the TradingView lock, from the
                              // sync heartbeat (tv_sync.dart).
                              Builder(
                                builder: (context) {
                                  final sync = TvSync(app: TvSync.pionex);
                                  final peer = sync.peer(TvSync.mt5);
                                  final lock = sync.lockHolder();
                                  return Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      _StatusDot(
                                        on: peer != null,
                                        label: peer == null
                                            ? 'tradingMT5: offline'
                                            : 'tradingMT5: online, Power '
                                                  '${peer.power ? 'on' : 'off'}, tab ${peer.tab}',
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'TradingView lock: ${lock == null ? 'free' : '${lock.app} (${lock.action})'}',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ],
                                  );
                                },
                              ),
                              const SizedBox(height: 8),
                              Text(
                                status.lastPowerDownAt == null
                                    ? '${l10n.dashboardLastPowerDown}: ${l10n.dashboardNeverPoweredDown}'
                                    : '${l10n.dashboardLastPowerDown}: ${UtilDate.dateTime(status.lastPowerDownAt!)}',
                              ),
                              if (powerDisplayAlive &&
                                  !checkupRunning &&
                                  status.engineStatus.lastCycleMessage.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(status.engineStatus.lastCycleMessage),
                              ],
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            _StatLine(
                              label: 'Pionex balance',
                              value: UtilString.usd(status.walletBalance),
                            ),
                            _StatLine(
                              label: 'Free for new trades',
                              value: UtilString.usd(status.availableBalance),
                              color: status.canOpenNewGrid
                                  ? trading.profit
                                  : trading.warning,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Toggles, as in tradingMT5: Power, Auto, and the 1H box
                  // with its check mark and the countdown to the next candle.
                  ReuseCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 24,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            ValueListenableBuilder<bool>(
                              valueListenable: _blink,
                              builder: (context, on, _) {
                                final powerColor = dimmed(
                                  powerBaseColor,
                                  powerHealth.blinking,
                                  on,
                                );
                                return Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Switch(
                                      value: powerDisplayAlive,
                                      activeThumbColor: powerColor,
                                      activeTrackColor: powerColor.withValues(alpha: 0.5),
                                      inactiveThumbColor: powerColor,
                                      inactiveTrackColor: powerColor.withValues(alpha: 0.3),
                                      onChanged: (v) => _setPower(repo, status, v),
                                    ),
                                    const SizedBox(width: 4),
                                    const Text('Power'),
                                    const SizedBox(width: 8),
                                    Text(
                                      powerHealth.label,
                                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                        color: powerColor,
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                            ValueListenableBuilder<bool>(
                              valueListenable: _blink,
                              builder: (context, on, _) {
                                final autoColor = dimmed(
                                  autoBaseColor,
                                  autoHealth.blinking,
                                  on,
                                );
                                return Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Switch(
                                      value: !status.paused,
                                      activeThumbColor: autoColor,
                                      activeTrackColor: autoColor.withValues(alpha: 0.5),
                                      inactiveThumbColor: autoColor,
                                      inactiveTrackColor: autoColor.withValues(alpha: 0.3),
                                      onChanged: _busy ? null : (v) => _setAuto(repo, status, v),
                                    ),
                                    const SizedBox(width: 4),
                                    const Text('Auto'),
                                    const SizedBox(width: 8),
                                    Text(
                                      autoHealth.label,
                                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                        color: autoColor,
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                            _HourBox(
                              active: !status.paused && engineProcessAlive,
                              checked: repo.hourlyCheckRanThisHour(),
                            ),
                          ],
                        ),
                        if (!status.paused &&
                            engineProcessAlive &&
                            status.engineStatus.autoCheckupMessage.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            status.engineStatus.autoCheckupMessage,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                  ReuseCard(
                    // Bug fixed 2026-09-19, per the user ("all auto switches
                    // should be lifted up below title.. currently there is a
                    // gap"): title/trailing used to be ReuseCard's own
                    // title-row slots, which sizes that whole row to the
                    // TALLER of the two - once PnlSummaryView grew a 3rd row
                    // (same-day redesign), the title row grew with it,
                    // pushing AutoCategorySwitches down by however much
                    // taller the summary got, even though the title TEXT
                    // itself never changed height. Built manually here
                    // instead so the switches sit directly under the title
                    // text in their own column, independent of the
                    // summary's height on the right.
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: CoreSpacing.sm),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        PulsingDot(
                                          alive:
                                              status.grids.appRunning.isNotEmpty,
                                        ),
                                        const SizedBox(width: CoreSpacing.sm),
                                        Text(
                                          'Auto bots: ${status.grids.appRunning.length}',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleMedium,
                                        ),
                                        // Sort icon right after the count
                                        // (per the user, 2026-11-14).
                                        cardSortIconButton(
                                          _autoSort,
                                          () => setState(
                                            () => _autoSort = nextCardSort(_autoSort),
                                          ),
                                        ),
                                        const Spacer(),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              PnlSummaryView(
                                profit: pnl.profit,
                                loss: pnl.loss,
                                net: pnl.net,
                                profitCount: pnl.profitCount,
                                lossCount: pnl.lossCount,
                                neutralCount: pnl.neutralCount,
                                successRatePercent: pnl.successRatePercent,
                                since: pnl.since,
                                onReset: () => _confirmResetPnl(repo),
                                onSummaryTap: () =>
                                    context.push('/pnl-summary'),
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: CoreSpacing.md),
                        GridsTable(
                      grids: status.grids.appRunning,
                      asCards: true,
                      cardSort: _autoSort,
                      // Bug fixed 2026-09-16, per the user: "stop, last,
                      // convert manual, convert auto: all those action
                      // buttons should be disabled once power off" - this
                      // used to gate only on `_busy` (another action
                      // already in flight), never on whether the engine
                      // process itself is even alive, so all 4 bulk
                      // buttons here stayed clickable with Power off.
                      // Matches the same `_actionsBlocked` pattern already
                      // used for Start/Check now on this screen.
                      busy: _actionsBlocked(status, engineProcessAlive),
                      emptyMessage: 'No running auto bots right now.',
                      categoryOf: (id) => repo.botCategories.categoryOf(id),
                      entrySignalFor: (id) => repo.entrySignalFor(id),
                      closeCandidateFor: repo.closeCandidateFor,
                      // Per the user (2026-09-12): shows this row's own
                      // category marker ONLY when it matches that
                      // category's CURRENT one - i.e. only once this bot's
                      // base has genuinely been checked in the sweep
                      // that's running right now. An older/no marker (row
                      // shows nothing) means "not checked yet this
                      // interval" - exactly the "assure if all list get
                      // checked" signal asked for.
                      // Check mark once the hourly Auto check has read this
                      // pair in the current UTC hour (same as tradingMT5).
                      cycleMarkerFor: (bot) {
                        final bareBase = bot.base
                            .toUpperCase()
                            .replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '');
                        final category =
                            repo.botCategories.categoryOf(bot.buOrderId) ??
                            AutoCategory.oneHour;
                        return checkedNow.contains(
                              '$bareBase|${category.wireValue}',
                            )
                            ? '✓'
                            : null;
                      },
                      favoriteIds: repo.favoriteBotIds(),
                      lastMarkedBases: repo.retiredBases(),
                      onCancelLast: _cancelLast,
                      cancelLastActiveRowId: _cancelLastRowId,
                      onBulkStop: (bots) => _run(
                        'stop-selected',
                        () async {
                          await repo.stopByBases(
                            bots.map((b) => b.base).toList(),
                          );
                        },
                        successMessage: 'Stopped ${bots.length} bot(s).',
                      ),
                      onBulkLast: (bots) => _run(
                        'last-selected',
                        () async {
                          await repo.lastSelectByIds(
                            bots.map((b) => b.buOrderId).toList(),
                          );
                        },
                        successMessage:
                            'Retired ${bots.length} bot(s) — will finish naturally and never auto-recreate.',
                      ),
                      onBulkConvertToManual: (bots) => _run(
                        'convert-to-manual-selected',
                        () async {
                          for (final bot in bots) {
                            await repo.convertAutoToManual(bot.buOrderId);
                          }
                          ref.invalidate(statusReportProvider);
                        },
                        successMessage:
                            'Converted ${bots.length} bot(s) to manual.',
                      ),
                    ),
                        WaitingBasesView(
                          waiting: repo.waitingBases(
                            status.grids.appRunning,
                            triedBases:
                                status.engineStatus.waitingEngineTriedBases,
                          ),
                          waitingEngineCurrentBase:
                              status.engineStatus.waitingEngineCurrentBase,
                          waitingEngineIdleReason:
                              status.engineStatus.waitingEngineIdleReason,
                          onStop: (base, category) => _run(
                            'stop-waiting-$base-${category.wireValue}',
                            () => repo.stopWaitingBase(base, category),
                            successMessage:
                                'Stopped ${base}USDT/${category.label} - removed from waiting.',
                          ),
                          onIgnite: (base, category) => _run(
                            'ignite-$base-${category.wireValue}',
                            () async {
                              var result = await repo.igniteBase(
                                base,
                                category,
                              );
                              // Pionex account-tier limit (2026-09-16, per
                              // the user, confirmed live via Pionex's own
                              // "Creation failed" dialog): once an account
                              // holds more than 20 total bots, Pionex
                              // requires investment above $50. If that's
                              // exactly why this refused, offer to bump
                              // this pair to $51 (per the user: "make it
                              // 51 usdt instead of 50" - genuinely clears
                              // Pionex's own "more than 50" wording) and
                              // retry, with a 5s auto-decline per the
                              // user's exact spec - a real, timely yes is
                              // required, nothing is forced silently.
                              final message = '${result['message'] ?? ''}';
                              if (result['ok'] != true &&
                                  message.contains(
                                    'requires investment over',
                                  ) &&
                                  mounted &&
                                  context.mounted) {
                                final wouldBeBotNumber =
                                    status.grids.appRunning.length +
                                    status.grids.manualRunning.length +
                                    1;
                                final symbol = '${base}USDT';
                                final agreed =
                                    await showTierLimitInvestmentDialog(
                                      context,
                                      symbol: symbol,
                                      wouldBeBotNumber: wouldBeBotNumber,
                                      bumpedInvestment: 51,
                                    );
                                if (agreed) {
                                  repo.setPairInvestment(symbol, 51);
                                  result = await repo.igniteBase(
                                    base,
                                    category,
                                  );
                                }
                              }
                              // Per the user: "if reading (data from
                              // trading view, pionex) fails, it stays in
                              // waiting with snackbar message" - notified
                              // directly here (not via _run's throw/catch)
                              // so the snackbar shows the engine's own
                              // real reason, not a generic "Exception: "
                              // wrapper.
                              _notify(
                                '${result['message'] ?? 'Ignite failed for an unknown reason.'}',
                                success: result['ok'] == true,
                              );
                            },
                          ),
                          isIgniting: (base, category) =>
                              _activeAction == 'ignite-$base-${category.wireValue}',
                          anyIgniteInFlight:
                              _activeAction?.startsWith('ignite-') ?? false,
                        ),
                      ],
                    ),
                  ),
                  ReuseCard(
                    title: 'Manual bots: ${status.grids.manualRunning.length}',
                    child: GridsTable(
                      grids: status.grids.manualRunning,
                      // Same cards as the Auto bots (per the user, 2026-11-14).
                      asCards: true,
                      // See the matching fix/comment on the app-bots
                      // GridsTable above - same bug, same fix.
                      busy: _actionsBlocked(status, engineProcessAlive),
                      emptyMessage: 'No running manual bots right now.',
                      entrySignalFor: (id) => repo.entrySignalFor(id),
                      closeCandidateFor: repo.closeCandidateFor,
                      onBulkConvertToAuto: (bots) async {
                        final category = await showCategoryPickerDialog(
                          context,
                          title: 'Convert ${bots.length} bot(s) to auto',
                        );
                        if (category == null || !context.mounted) return;
                        await _run(
                          'convert-selected',
                          () async {
                            for (final bot in bots) {
                              await repo.convertManualToAuto(
                                bot.buOrderId,
                                category,
                              );
                            }
                            ref.invalidate(statusReportProvider);
                          },
                          successMessage:
                              'Converted ${bots.length} bot(s) to auto (${category.label}) — the engine will check them up from here on.',
                        );
                      },
                    ),
                  ),
                  ReuseCard(
                    title:
                        '${l10n.dashboardAvailablePairs}: ${status.availablePairs.length}',
                    child: status.availablePairs.isEmpty
                        ? ReuseEmptyState(
                            message: l10n.dashboardNoAvailablePairs,
                            icon: Icons.playlist_add_check,
                          )
                        : Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final base in status.availablePairs)
                                ReuseChip(label: base),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A green / grey dot with a label - tradingMT5's status light.
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.on, required this.label});

  final bool on;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: on ? Colors.green : Colors.grey,
          shape: BoxShape.circle,
        ),
      ),
      const SizedBox(width: 8),
      Flexible(child: Text(label)),
    ],
  );
}

/// "Label: value", right-aligned - tradingMT5's account figures.
class _StatLine extends StatelessWidget {
  const _StatLine({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text.rich(
        TextSpan(
          style: TextStyle(color: scheme.onSurfaceVariant),
          children: [
            TextSpan(text: '$label: '),
            TextSpan(
              text: value,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: color ?? scheme.onSurface,
              ),
            ),
          ],
        ),
        textAlign: TextAlign.right,
      ),
    );
  }
}

/// tradingMT5's 1H box: a check mark once this hour's Auto check has run,
/// and a live countdown to the next hourly candle (UTC).
class _HourBox extends StatefulWidget {
  const _HourBox({required this.active, required this.checked});

  final bool active;
  final bool checked;

  @override
  State<_HourBox> createState() => _HourBoxState();
}

class _HourBoxState extends State<_HourBox> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().toUtc();
    final next = DateTime.utc(now.year, now.month, now.day, now.hour + 1);
    final left = next.difference(now);
    final m = left.inMinutes.toString().padLeft(2, '0');
    final s = (left.inSeconds % 60).toString().padLeft(2, '0');
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: widget.active
            ? scheme.secondaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        '1H ${widget.checked ? '✓ ' : ''}$m:$s',
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: widget.active ? null : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}