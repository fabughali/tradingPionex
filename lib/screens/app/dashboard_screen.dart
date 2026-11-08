import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/core_layout.dart';
import '../../core/core_spacing.dart';
import '../../core/core_theme.dart';
import '../../data/control/engine_control_repository.dart';
import '../../data/models/auto_category.dart';
import '../../data/models/grid_bot.dart';
import '../../data/providers/app_providers.dart';
import '../../l10n/app_localizations.dart';
import '../../utilities/util_date.dart';
import '../../utilities/util_string.dart';
import '../../widgets/power_off_confirm.dart';
import '../../widgets/auto_category_switches.dart';
import '../../widgets/category_knob.dart';
import '../../widgets/countdown_text.dart';
import '../../widgets/grids_table.dart';
import '../../widgets/pnl_summary_view.dart';
import '../../widgets/waiting_bases_view.dart';
import '../../widgets/reuse_card.dart';
import '../../widgets/reuse_chip.dart';
import '../../widgets/reuse_empty_state.dart';
import '../../widgets/reuse_error.dart';
import '../../widgets/reuse_loading_indicator.dart';
import '../../widgets/reuse_status_light.dart';
import '../../widgets/report_section.dart';
import '../../widgets/tier_limit_dialog.dart';
import '../../widgets/pulsing_dot.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
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

  /// The `buOrderId` of the row whose "Stop Loss Lock" toggle was just
  /// switched off (2026-09-22, per the user: "add a disable toggle same as
  /// last toggle") - drives that row's spinner while [_cancelStopLossLock]
  /// runs, same pattern as [_cancelLastRowId].
  String? _cancelStopLossLockRowId;

  Future<void> _cancelStopLossLock(GridBot bot) async {
    final repo = ref.read(controlRepositoryProvider);
    setState(() => _cancelStopLossLockRowId = bot.buOrderId);
    try {
      await repo.stopLossLockSelect([bot.buOrderId], enable: false);
      ref.invalidate(statusReportProvider);
      _notify('${bot.pairKey}: Stop Loss Lock disabled.', success: true);
    } catch (e) {
      _notify('$e', success: false);
    } finally {
      if (mounted) setState(() => _cancelStopLossLockRowId = null);
    }
  }

  /// base -> categories with a currently-running auto bot for that exact
  /// base (2026-09-11, per the user's rule: a pair can only have ONE
  /// running auto bot per interval - XRPUSDT/1m already running blocks
  /// starting XRPUSDT/1m again, but never blocks XRPUSDT/1H or 1D). Drives
  /// the Next Trade table's knob yellow/"blocked" segments. Strips
  /// Pionex's raw ".PERP" base suffix (same systemic fix as everywhere else
  /// this session) since `botCategories.categoryOf` keys by buOrderId, not
  /// base, but the base itself comes straight off the raw GridBot.
  Map<String, Set<AutoCategory>> _blockedByBase(
    StatusReport status,
    EngineControlRepository repo,
  ) {
    final result = <String, Set<AutoCategory>>{};
    for (final g in status.grids.appRunning) {
      final category = repo.botCategories.categoryOf(g.buOrderId);
      if (category == null) continue;
      final bareBase = g.base
          .toUpperCase()
          .replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '');
      (result[bareBase] ??= {}).add(category);
    }
    // Per the user (2026-09-11): "if the bot is initiated by user and
    // still in waiting, the knob in next trade should become yellow as
    // if it is already started - so user can't re-select it." A base
    // waiting to open (recycled, or still being retried after Start
    // skipped it - see waitingBases' own doc) isn't a running bot yet,
    // but the app is already actively responsible for it, so it gets the
    // same yellow "blocked" treatment as one that is.
    for (final w in repo.waitingBases(status.grids.appRunning)) {
      (result[w.base] ??= {}).add(w.category);
    }
    return result;
  }

  /// Symbols with a category/investment-edit check currently in flight
  /// (2026-09-10, per the user) - drives the loading spinner in that row's
  /// Actual investment/Extra margin cells on the Next Trade table.
  final Set<String> _pendingChecks = {};

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
  bool _blinkOn = true;
  bool _blinkFast = false;
  String? _lastHealthLabel;

  @override
  void dispose() {
    _blinkTimer?.cancel();
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
      _blinkTimer = Timer.periodic(Duration(milliseconds: fast ? 180 : 500), (
        _,
      ) {
        if (mounted) setState(() => _blinkOn = !_blinkOn);
      });
    } else if (!needed && _blinkTimer != null) {
      _blinkTimer!.cancel();
      _blinkTimer = null;
      _blinkOn = true;
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
  bool _refreshingMarket = false;

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
  Future<bool> _performPowerUp(EngineControlRepository repo) async {
    final integrations = ref.read(integrationsRepositoryProvider);
    final cdp = integrations.readCdpConfig();

    final tv = await integrations.testTradingView(
      host: cdp.host,
      port: cdp.port,
    );
    if (!tv.ok) {
      _notify('Power-up stopped — ${tv.message}', success: false);
      return false;
    }

    final pionex = ref.read(pionexClientProvider);
    double freeBalance;
    try {
      freeBalance = (await pionex.getBalance('USDT')).free;
    } catch (e) {
      _notify('Power-up stopped — could not reach Pionex: $e', success: false);
      return false;
    }

    if (!await repo.launchEngineIfNeeded()) {
      _notify('Power-up stopped — the engine could not start.', success: false);
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

  /// A single Auto engine's (1m/1H/1D) own on/off switch (2026-09-07) -
  /// independent of the master Auto switch above, and of the other 2
  /// categories. ON: resumes that category and forces an immediate check on
  /// its own auto-managed bases. OFF: per the user (2026-09-09), mirrors
  /// the master Auto-off flow but scoped to just THIS category's own
  /// running bots - offers picking which of them become "Last" before
  /// actually pausing that one category.
  void _setAutoCategory(
    EngineControlRepository repo,
    StatusReport status,
    AutoCategory category,
    bool turnOn,
  ) {
    _run('auto-${category.wireValue}', () async {
      if (turnOn) {
        repo.resumeCategory(category);
        repo.triggerAutoCheckupFor(category);
        _notify(
          'Auto[${category.label}] resumed — checking now.',
          success: true,
        );
      } else {
        repo.pauseCategory(category);
        _notify('Auto[${category.label}] paused.', success: true);
      }
    });
  }


  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
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
          var powerColor = ReuseStatusLight.colorFor(
            context,
            powerHealth.color,
          );
          if (powerHealth.blinking && !_blinkOn) {
            powerColor = powerColor.withValues(alpha: 0.35);
          }
          var autoColor = ReuseStatusLight.colorFor(context, autoHealth.color);
          if (autoHealth.blinking && !_blinkOn) {
            autoColor = autoColor.withValues(alpha: 0.35);
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(statusReportProvider),
            child: LayoutBuilder(
              builder: (context, constraints) => ListView(
                padding: CoreLayout.edgeMargin(constraints),
                children: [
                  ReuseCard(
                    title: 'Engine',
                    // Per the user (2026-09-09): the standalone Balance
                    // card is gone - shown here instead, inline on the
                    // same row as the "Engine" title, and again (same text
                    // size, also inlined with its title) on the Next Trade
                    // card below.
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Free balance: ',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          UtilString.usd(status.availableBalance),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: status.canOpenNewGrid
                                    ? trading.profit
                                    : trading.warning,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          status.lastPowerDownAt == null
                              ? '${l10n.dashboardLastPowerDown}: ${l10n.dashboardNeverPoweredDown}'
                              : '${l10n.dashboardLastPowerDown}: ${UtilDate.dateTime(status.lastPowerDownAt!)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: CoreSpacing.xs),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              // Bottom-aligned against the Power switch
                              // itself (the last item in its Column, below
                              // its label) rather than the default center,
                              // which centered the button against the whole
                              // taller label+switch stack and left it
                              // sitting visibly higher than the switch.
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    const Text('Power'),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        // Power's OWN status word, inline
                                        // with (not above) the switch so
                                        // they sit centered together - the
                                        // process's own health, deliberately
                                        // separate from Auto's below (see
                                        // ReuseStatusLight.evaluatePower).
                                        Text(
                                          powerHealth.label,
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelLarge
                                              ?.copyWith(
                                                color: powerColor,
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                        const SizedBox(width: CoreSpacing.sm),
                                        // Bound directly to the real process
                                        // state (both directions accurate -
                                        // Power OFF actually stops the
                                        // process, see
                                        // _setPower/stopEngineProcess) rather
                                        // than any derived or locally-tracked
                                        // flag, which is what previously let
                                        // this drift out of sync with
                                        // reality. No loading indicator and
                                        // no busy-gate on onChanged - per the
                                        // user, Power must always be
                                        // immediately actionable. Thumb/track
                                        // colored by the same health color as
                                        // the status word, not just the text.
                                        Switch(
                                          value: powerDisplayAlive,
                                          activeThumbColor: powerColor,
                                          activeTrackColor: powerColor
                                              .withValues(alpha: 0.5),
                                          inactiveThumbColor: powerColor,
                                          inactiveTrackColor: powerColor
                                              .withValues(alpha: 0.3),
                                          onChanged: (v) =>
                                              _setPower(repo, status, v),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            // Connectivity/health phase only - e.g.
                            // "Checking TradingView connection...",
                            // "Verifying chart indicators...", "Ready".
                            // Deliberately excludes the full Red-list
                            // sweep's own per-pair message (that's Check
                            // Now's business now, shown next to its own
                            // button in the Next Trade card) - per the user
                            // (2026-09-09): "power toggle has nothing for
                            // pairs." Bug fixed 2026-09-10: this used to
                            // live INSIDE the same Column the Refresh button
                            // aligned its bottom edge against - the instant
                            // this line appeared/disappeared, that column
                            // got taller/shorter, and Refresh visibly
                            // shifted down/up to match the new bottom edge
                            // even though the Switch itself never moved.
                            // Moved outside the aligned Row entirely so
                            // Refresh only ever aligns against the fixed-
                            // height "Power" label + switch row, never
                            // against this optional line.
                            if (powerDisplayAlive &&
                                !checkupRunning &&
                                status.engineStatus.lastCycleMessage.isNotEmpty)
                              Text(
                                status.engineStatus.lastCycleMessage,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            const SizedBox(height: CoreSpacing.xs),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    const Text('Auto'),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        // Auto's OWN status word (see
                                        // ReuseStatusLight.evaluateAuto) -
                                        // purely pause/activity, no Pionex/
                                        // TradingView branches (that's
                                        // Power's job above).
                                        Text(
                                          autoHealth.label,
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelLarge
                                              ?.copyWith(
                                                color: autoColor,
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                        const SizedBox(width: CoreSpacing.sm),
                                        // Thumb/track colored by the same
                                        // health color as the status word,
                                        // not just the text.
                                        Switch(
                                          // Per the user: if Power is off
                                          // (the engine process isn't
                                          // actually alive), Auto must
                                          // visually show off too - not just
                                          // "not working" while still
                                          // showing on because the PAUSE
                                          // file's last state happened to be
                                          // "resumed" (e.g. the process died
                                          // unexpectedly, or was stopped
                                          // some other way, without ever
                                          // touching PAUSE).
                                          value:
                                              !status.paused,
                                          activeThumbColor: autoColor,
                                          activeTrackColor: autoColor
                                              .withValues(alpha: 0.5),
                                          inactiveThumbColor: autoColor,
                                          inactiveTrackColor: autoColor
                                              .withValues(alpha: 0.3),
                                          // Purely the PAUSE flag -
                                          // independent of whether the
                                          // engine process is alive (Power
                                          // above). ON: resumes normal
                                          // candle-gated auto-trading AND
                                          // forces one immediate checkup so
                                          // the current state is fresh right
                                          // away, rather than waiting for
                                          // the next candle. OFF: pauses -
                                          // the engine will not act on the
                                          // next candle until this is
                                          // switched back on.
                                          onChanged: _busy
                                              ? null
                                              : (v) =>
                                                    _setAuto(repo, status, v),
                                        ),
                                      ],
                                    ),
                                    // Auto's OWN activity line -
                                    // deliberately a separate field from
                                    // Power's (lastCycleMessage above),
                                    // since Checkup and Auto-checkup are two
                                    // independent processes and must never
                                    // show one under the other's toggle.
                                    // Hidden entirely while Auto is off, per
                                    // the user - even if a Last-marked bot
                                    // is still quietly being watched in the
                                    // background. Also hidden if Power is
                                    // off (engine not actually alive), same
                                    // reasoning as the switch's own value
                                    // above.
                                    if (!status.paused &&
                                        engineProcessAlive &&
                                        status
                                            .engineStatus
                                            .autoCheckupMessage
                                            .isNotEmpty)
                                      Text(
                                        status.engineStatus.autoCheckupMessage,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                        if (!status.paused &&
                            engineProcessAlive &&
                            status.grids.appRunning.isNotEmpty) ...[
                          const SizedBox(height: CoreSpacing.xs),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Next checkup after: ',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                CountdownText(
                                  target: status.nextCheckupEta,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  ReportSection(
                    report: status.lastReport,
                    engineStatus: status.engineStatus,
                    freeBalance: status.availableBalance,
                    canOpenNewGrid: status.canOpenNewGrid,
                    busy: _actionsBlocked(status, engineProcessAlive),
                    startLoading: _activeAction == 'start-selected',
                    // Per the user (2026-09-09): Check now moved here, top
                    // left of the Next Trade card - it's the button
                    // responsible for the full Red-list check, so it
                    // belongs with the pairs data it produces, not under
                    // Power/Quick Actions.
                    // Check Now reads Pionex only (per the user, 2026-11-08):
                    // it refreshes the market list - no TradingView, no
                    // engine. Signals are read by Start, per selected pair.
                    // Spinner + disabled until Pionex's list is back.
                    checkNowLoading: _refreshingMarket,
                    onCheckNow: _refreshingMarket
                        ? null
                        : () async {
                            setState(() => _refreshingMarket = true);
                            try {
                              final pairs = await ref.refresh(
                                pionexMarketProvider.future,
                              );
                              _notify(
                                'Pionex list refreshed — ${pairs.length} pairs.',
                                success: true,
                              );
                            } catch (e) {
                              _notify('Could not refresh from Pionex: $e',
                                  success: false);
                            } finally {
                              if (mounted) {
                                setState(() => _refreshingMarket = false);
                              }
                            }
                          },
                    market:
                        ref.watch(pionexMarketProvider).value ?? const [],

                    // Per the user (2026-09-05, correcting an earlier
                    // misreading): Start is an on-spot check of ONLY the
                    // selected pair(s) - never a full Red-list sweep.
                    // Pressing it while Auto is off also means "open these
                    // now", so it turns Auto on first (same as the Auto
                    // switch's own turnOn path) before triggering the
                    // targeted check; whatever Checkup/Auto-checkup pass it
                    // interrupts resumes automatically once it's done.
                    onStart: (symbols) => _run('start-selected', () async {
                      final wasOff = status.paused;
                      if (wasOff) repo.resume();
                      // Bug fixed 2026-09-10: requestStartAction blocks
                      // until the engine actually finishes (or times out),
                      // so the button's loading/disabled state - driven by
                      // _run's own busy flag - now genuinely covers the
                      // whole process, not just the instant it takes to
                      // write the request file.
                      final result = await repo.requestStartAction(
                        symbols,
                        // Per the user (2026-09-11): "add per-pair
                        // feedback as each one resolves, instead of one
                        // big summary at the end" - fires the moment the
                        // engine's own live progress shows a symbol
                        // decided, not just once at the very end (which,
                        // now that Auto categories can pause a Start for
                        // minutes, could otherwise leave the user staring
                        // at a spinner with zero feedback the whole time).
                        // Per the user (2026-09-13): Start no longer opens
                        // synchronously - "opened" here now means "queued
                        // for the waiting engine to pick up", not a real
                        // open yet.
                        onSymbolResolved: (symbol, {required opened, reason}) {
                          if (!mounted) return;
                          _notify(
                            opened
                                ? '$symbol queued for the waiting engine.'
                                : '$symbol skipped: ${reason ?? 'unknown reason'}.',
                            success: opened,
                          );
                        },
                      );
                      final opened = (result['opened'] as List?) ?? const [];
                      final skipped =
                          (result['skipped'] as Map?) ?? const {};
                      final autoNote = wasOff
                          ? ' Auto was off, so it has been turned on.'
                          : '';
                      if (opened.isEmpty && skipped.isEmpty) {
                        _notify(
                          '${result['message'] ?? 'Start did not complete.'}$autoNote',
                          success: result['ok'] == true,
                        );
                        return;
                      }
                      final parts = <String>[
                        if (opened.isNotEmpty)
                          'Queued for the waiting engine: ${opened.join(', ')}.',
                        if (skipped.isNotEmpty)
                          'Skipped: ${skipped.entries.map((e) => '${e.key} (${e.value})').join(', ')}.',
                      ];
                      _notify(
                        '${parts.join(' ')}$autoNote',
                        success: opened.isNotEmpty,
                      );
                    }),
                    categoryOf: (symbol) =>
                        repo.pairCategories.categoryOf(symbol),
                    onCategoryChanged: (symbol, category) {
                      // Per the user (2026-09-10, correcting 2026-09-09):
                      // switching the knob must NOT pull fresh Pionex data
                      // - report.entries already carries every category's
                      // own data (kept fresh by the ongoing background
                      // report, independent of this), so the row's display
                      // switches instantly from what's already known. Only
                      // persist the pick for the engine to use next Start.
                      repo.setPairCategory(symbol, category);
                    },
                    investmentOf: (symbol) =>
                        repo.pairInvestments.investmentOf(symbol),
                    // Saves only (per the user, 2026-11-07: no automatic
                    // checks in Next Trade) - the amount is used when the pair
                    // is next started.
                    onInvestmentChanged: (symbol, amount, category, hasData) =>
                        repo.setPairInvestment(symbol, amount),
                    isCheckPending: (symbol) => _pendingChecks.contains(symbol),
                    storedCheckupMarkerFor: (base) =>
                        repo.checkupCycleMarkerFor(base),
                    blockedByBase: _blockedByBase(status, repo),
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
                                        Expanded(
                                          child: Text(
                                            'Auto bots: ${status.grids.appRunning.length}',
                                            overflow: TextOverflow.ellipsis,
                                            maxLines: 1,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.titleMedium,
                                          ),
                                        ),
                                      ],
                                    ),
                                    // Per the user (2026-09-12): "shift the
                                    // 3 toggles 3m/1H/1D into auto card. so
                                    // i can watch the status of each toggle
                                    // along with list of auto bots" - moved
                                    // here from the Engine card above, right
                                    // above the running-bots table, so the
                                    // per-category status/countdown and the
                                    // bots they actually manage are visible
                                    // together in one card.
                                    AutoCategorySwitches(
                                      engineStatus: status.engineStatus,
                                      nextCheckupEtaFor:
                                          status.nextCheckupEtaFor,
                                      busy: _busy,
                                      masterActive:
                                          !status.paused,
                                      onToggle: (category, turnOn) =>
                                          _setAutoCategory(
                                            repo,
                                            status,
                                            category,
                                            turnOn,
                                          ),
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
                      // Per the user (2026-09-12): shows this row's own
                      // category marker ONLY when it matches that
                      // category's CURRENT one - i.e. only once this bot's
                      // base has genuinely been checked in the sweep
                      // that's running right now. An older/no marker (row
                      // shows nothing) means "not checked yet this
                      // interval" - exactly the "assure if all list get
                      // checked" signal asked for.
                      cycleMarkerFor: (bot) {
                        final category = repo.botCategories.categoryOf(
                          bot.buOrderId,
                        );
                        if (category == null) return null;
                        final bareBase = bot.base
                            .toUpperCase()
                            .replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '');
                        final stored = repo.cycleMarkerFor(bareBase, category);
                        final current = status.engineStatus
                            .statusFor(category)
                            .cycleMarkerIndex;
                        if (stored == null || stored != current) return null;
                        return category.cycleMarkerFor(current);
                      },
                      lastMarkedBases: repo.retiredBases(),
                      onCancelLast: _cancelLast,
                      cancelLastActiveRowId: _cancelLastRowId,
                      stopLossLockedIds: repo.stopLossLockedIds(
                        status.grids.appRunning,
                      ),
                      onCancelStopLossLock: _cancelStopLossLock,
                      cancelStopLossLockActiveRowId: _cancelStopLossLockRowId,
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
                      onBulkStopLossLock: (bots, markPending) {
                        markPending();
                        return _run(
                          'stop-loss-lock-selected',
                          () async {
                            await repo.stopLossLockSelect(
                              bots.map((b) => b.buOrderId).toList(),
                              enable: true,
                            );
                          },
                          successMessage:
                              'Stop Loss Lock enabled for ${bots.length} bot(s).',
                        );
                      },
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
                      // See the matching fix/comment on the app-bots
                      // GridsTable above - same bug, same fix.
                      busy: _actionsBlocked(status, engineProcessAlive),
                      emptyMessage: 'No running manual bots right now.',
                      entrySignalFor: (id) => repo.entrySignalFor(id),
                      stopLossLockedIds: repo.stopLossLockedIds(
                        status.grids.manualRunning,
                      ),
                      onCancelStopLossLock: _cancelStopLossLock,
                      cancelStopLossLockActiveRowId: _cancelStopLossLockRowId,
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
                      // Manual bots have no inherent category (2026-09-22,
                      // per the user) - Stop Loss Lock needs one to know
                      // which chart timeframe to watch, so this asks first,
                      // reusing the exact same picker the Convert to Auto
                      // flow above already uses. The one picked choice
                      // applies to every bot in this selection. `markPending`
                      // is deliberately called only AFTER the picker
                      // resolves (not on click) - see its own doc comment on
                      // `GridsTable.onBulkStopLossLock`: marking pending
                      // before a cancellable picker would leave the
                      // checkbox stuck disabled forever if the user backs
                      // out of it.
                      onBulkStopLossLock: (bots, markPending) async {
                        final category = await showCategoryPickerDialog(
                          context,
                          title:
                              'Stop Loss Lock: chart timeframe for ${bots.length} bot(s)',
                        );
                        if (category == null || !context.mounted) return;
                        markPending();
                        await _run(
                          'stop-loss-lock-selected',
                          () async {
                            await repo.stopLossLockSelect(
                              bots.map((b) => b.buOrderId).toList(),
                              enable: true,
                              manualCategory: category,
                            );
                          },
                          successMessage:
                              'Stop Loss Lock enabled for ${bots.length} bot(s) (${category.label}).',
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
