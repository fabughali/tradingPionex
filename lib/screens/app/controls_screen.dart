import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/core_layout.dart';
import '../../core/core_spacing.dart';
import '../../data/control/engine_control_repository.dart';
import '../../data/models/auto_category.dart';
import '../../data/models/grid_bot.dart';
import '../../data/models/preview_grid_pair.dart';
import '../../data/providers/app_providers.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/auto_category_switches.dart';
import '../../widgets/category_knob.dart';
import '../../widgets/grids_table.dart';
import '../../widgets/pnl_summary_view.dart';
import '../../widgets/reuse_button.dart';
import '../../widgets/waiting_bases_view.dart';
import '../../widgets/reuse_card.dart';
import '../../widgets/reuse_chip.dart';
import '../../widgets/reuse_error.dart';
import '../../widgets/reuse_data_table.dart';
import '../../widgets/reuse_loading_indicator.dart';
import '../../widgets/report_section.dart'
    show previewDataColumns, previewComputedCells;
import '../../widgets/pulsing_dot.dart';
import '../../widgets/tier_limit_dialog.dart';

class ControlsScreen extends ConsumerStatefulWidget {
  const ControlsScreen({super.key});

  @override
  ConsumerState<ControlsScreen> createState() => _ControlsScreenState();
}

class _ControlsScreenState extends ConsumerState<ControlsScreen> {
  /// Which action is currently in flight, if any — only that action's button
  /// shows a spinner; every button is disabled while any action is running.
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

  /// See the matching field/method on `DashboardScreen` - same pattern.
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

  /// A single Auto engine's (1m/1H/1D) own on/off switch (2026-09-07) -
  /// independent of the master Auto switch above, and of the other 2
  /// categories. ON: resumes that category and forces an immediate check on
  /// its own auto-managed bases. OFF: per the user (2026-09-09), mirrors
  /// the master Auto-off flow but scoped to just THIS category's own
  /// running bots - offers picking which of them become "Last" before
  /// actually pausing that one category.
  ///
  /// Copied verbatim from `dashboard_screen.dart` (2026-09-12, per the
  /// user: "auto card in controls screen should match 100% as in
  /// dashboard") - kept as an exact duplicate rather than extracted into a
  /// shared widget/mixin, matching the scope of what was actually asked.
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
    // Per the user (2026-09-11): a base still waiting to open (recycled,
    // or still being retried after Start skipped it) gets the same
    // yellow "blocked" treatment as an already-running bot, same fix as
    // dashboard_screen.dart.
    for (final w in repo.waitingBases(status.grids.appRunning)) {
      (result[w.base] ??= {}).add(w.category);
    }
    return result;
  }

  /// Symbols with a category/investment-edit check currently in flight
  /// (2026-09-10, per the user) - drives the loading spinner in that row's
  /// Actual investment/Extra margin cells, on both the Next Trade table
  /// and the single-pair Check card below.
  final Set<String> _pendingChecks = {};

  /// Gates every manual, on-demand action on this screen (Check/Add/Remove/
  /// Start/Last/Stop, Stop-selected/Last-selected) - these must work
  /// independent of Auto's own on/off state (per the user: Check Now/Start
  /// are explicitly Auto-independent). Only actually blocks on Power not
  /// being ready yet (engine process not alive) or a local UI action
  /// already in flight - NOT on `status.paused` (Auto off), which used to
  /// block these too and defeated their purpose.
  bool _actionsBlocked(StatusReport status, bool engineProcessAlive) =>
      _busy || !engineProcessAlive;

  final _pairController = TextEditingController();

  /// Result of the last "Check" pair action, kept around so its preview
  /// panel (and the conditional "Add to Red List" button) stays on screen
  /// until the next Check, rather than vanishing the moment the SnackBar
  /// that reported it does.
  Map<String, dynamic>? _lastCheckResult;

  /// Immediate local echo of the Check card's knob, reset on every fresh
  /// Check - null falls back to whatever's on file for that symbol.
  AutoCategory? _checkCategoryOverride;

  /// The Check card's investment field (2026-09-09) - text is (re)seeded to
  /// whatever's on file for the symbol every fresh Check, same reset point
  /// as [_checkCategoryOverride].
  final _investmentController = TextEditingController();

  String _formatInvestment(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  Future<void> _commitCheckInvestment(
    EngineControlRepository repo,
    String symbol,
  ) async {
    final parsed = double.tryParse(_investmentController.text.trim());
    if (parsed == null || parsed <= 0) {
      _investmentController.text = _formatInvestment(
        repo.pairInvestments.investmentOf(symbol),
      );
      return;
    }
    // Per the user (2026-09-10): re-submitting the SAME number must not
    // pull fresh Pionex data again - same rule as the Next Trade table.
    if (parsed == repo.pairInvestments.investmentOf(symbol)) return;
    repo.setPairInvestment(symbol, parsed);
    // Per the user (2026-09-09): pull fresh actual investment/extra margin
    // from Pionex right away, into the SAME visible preview panel - not
    // just the background report the Next Trade table reads.
    setState(() => _pendingChecks.add(symbol));
    final result = await repo.requestPairAction('check', symbol);
    if (mounted) {
      setState(() {
        // Bug fixed 2026-09-10: this used to overwrite _lastCheckResult
        // unconditionally, even on failure (CDP hiccup, timeout, rate
        // limit) - a failed result has no preview/previewByCategory, so it
        // either blanked the panel or, depending on what _PairCheckResultView
        // does with missing fields, looked like the new investment value
        // was simply ignored. Keep the last GOOD result on screen and only
        // replace it on success; the SnackBar below is what tells the user
        // the refresh didn't happen, instead of silent stale/blank numbers.
        if (result['ok'] == true) _lastCheckResult = result;
        _pendingChecks.remove(symbol);
      });
      if (result['ok'] != true) {
        _notify(
          'Could not refresh $symbol from Pionex: '
          '${result['message'] ?? 'unknown error'} - '
          'the figures shown are still the last successful check.',
          success: false,
        );
      }
    }
  }

  @override
  void dispose() {
    _pairController.dispose();
    _investmentController.dispose();
    super.dispose();
  }

  /// "BTC", "BTCUSDT", "BINANCE:BTCUSDT" all normalize to "BTC" — matches
  /// `GridBot.base`/`RetiredStore`'s bare-base convention (as opposed to
  /// `qualifySymbol`, which normalizes to the full "BINANCE:BTCUSDT" form
  /// `status.engineStatus.redListSymbols` uses).
  String _bareBase(String raw) {
    var s = raw.trim().toUpperCase();
    if (s.isEmpty) return s;
    if (s.contains(':')) s = s.split(':').last;
    if (s.contains('/')) s = s.split('/').first;
    if (s.endsWith('USDT')) s = s.substring(0, s.length - 4);
    return s;
  }

  /// Per the user (2026-09-06): typing a bare base like "DOGE" silently
  /// failed - qualifySymbol only adds "BINANCE:" to a string that already
  /// ends in "USDT", so a bare base passed straight through stayed
  /// unqualified and TradingView couldn't find a symbol just called
  /// "DOGE". Resolves against the CURRENT Red List first (exact
  /// exchange/suffix as TradingView actually lists it). If the pair isn't
  /// on the Red List, passes a BARE ticker through with no exchange
  /// prefix at all - forcing "BINANCE:" here was never correct, since the
  /// user isn't restricted to Binance-listed pairs. Confirmed live via CDP
  /// (2026-09-06): TradingView's own chart.setSymbol() resolves a bare
  /// ticker like "ETHUSDT" to the right listing itself, exactly like
  /// typing it into TradingView's own search box - the app doesn't need
  /// to guess an exchange at all.
  String _resolveTypedSymbol(String raw, List<String> redListSymbols) {
    final typedBase = _bareBase(raw);
    for (final sym in redListSymbols) {
      if (_bareBase(sym) == typedBase) return sym;
    }
    final trimmed = raw.trim().toUpperCase();
    if (trimmed.contains(':')) return trimmed;
    return trimmed.endsWith('USDT') ? trimmed : '${trimmed}USDT';
  }

  /// Validates the Pair actions text field before any of its six buttons
  /// act on it — returns the resolved symbol, or null after showing an
  /// error SnackBar (same feedback channel every other validation message
  /// in this screen already uses) if it's empty.
  String? _requirePairSymbol(List<String> redListSymbols) {
    final raw = _pairController.text.trim();
    if (raw.isEmpty) {
      _notify('Enter a pair symbol first.', success: false);
      return null;
    }
    final resolved = _resolveTypedSymbol(raw, redListSymbols);
    if (!redListSymbols.contains(resolved)) {
      _notify(
        '"$raw" isn\'t on the current Red List — looking up $resolved '
        '(TradingView resolves which exchange automatically). If this '
        'isn\'t the pair you meant, type the exact symbol including its '
        'exchange prefix instead, e.g. EXCHANGE:$resolved.',
        success: true,
      );
    }
    return resolved;
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
  /// user) - same pattern as Dashboard's own `_confirmResetPnl` and
  /// `HistoryScreen._confirmClearAll`. Only moves the summary's cutoff
  /// forward - the underlying History record is never touched.
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final repo = ref.watch(controlRepositoryProvider);
    final pnl = repo.pnlSummary();
    final statusAsync = ref.watch(statusReportProvider);
    final engineProcessAlive = repo.isEngineProcessAlive;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.controlsTitle)),
      body: statusAsync.when(
        loading: () => const ReuseLoadingIndicator(),
        error: (err, st) => ReuseError(message: '$err'),
        data: (status) {
          return LayoutBuilder(
            builder: (context, constraints) => ListView(
              padding: CoreLayout.edgeMargin(constraints),
              children: [
                if (status.paused)
                  ReuseCard(
                    child: Row(
                      children: [
                        const Icon(Icons.pause_circle_outline),
                        const SizedBox(width: CoreSpacing.sm),
                        Expanded(child: Text(l10n.controlsPausedNotice)),
                      ],
                    ),
                  ),
                ReuseCard(
                  title: 'Pair actions',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _pairController,
                        decoration: const InputDecoration(
                          hintText: 'Symbol, e.g. BTC or BTCUSDT',
                        ),
                      ),
                      const SizedBox(height: CoreSpacing.sm),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: ReuseButton(
                          label: 'Check',
                          icon: Icons.search,
                          // Per the user (2026-09-09): same tone as Check
                          // now, so the loading spinner matches it exactly
                          // (was defaulting to primary's foreground, a
                          // different color than Check now's neutral tone).
                          tone: ReuseButtonTone.neutral,
                          loading: _activeAction == 'pair-check',
                          onPressed: _actionsBlocked(status, engineProcessAlive)
                              ? null
                              : () => _run('pair-check', () async {
                                  final raw = _requirePairSymbol(
                                    status.engineStatus.redListSymbols,
                                  );
                                  if (raw == null) return;
                                  final result = await repo.requestPairAction(
                                    'check',
                                    raw,
                                  );
                                  setState(() {
                                    _lastCheckResult = result;
                                    _checkCategoryOverride = null;
                                    _investmentController
                                        .text = _formatInvestment(
                                      repo.pairInvestments.investmentOf(raw),
                                    );
                                  });
                                  _notify(
                                    '${result['message'] ?? (result['ok'] == true ? 'Checked.' : 'Check failed.')}',
                                    success: result['ok'] == true,
                                  );
                                }),
                        ),
                      ),
                      if (_lastCheckResult != null) ...[
                        const Divider(height: CoreSpacing.lg),
                        _PairCheckResultView(
                          result: _lastCheckResult!,
                          disabled: _actionsBlocked(status, engineProcessAlive),
                          activeAction: _activeAction,
                          hasAutoBot: status.grids.appRunning.any(
                            (g) =>
                                g.base.toUpperCase() ==
                                _bareBase('${_lastCheckResult!['symbol']}'),
                          ),
                          blocked:
                              _blockedByBase(status, repo)[_bareBase(
                                '${_lastCheckResult!['symbol']}',
                              )] ??
                              const {},
                          onAdd: () => _run('pair-add', () async {
                            final symbol = '${_lastCheckResult!['symbol']}';
                            final result = await repo.requestPairAction(
                              'add',
                              symbol,
                            );
                            _notify(
                              '${result['message'] ?? (result['ok'] == true ? 'Added.' : 'Failed.')}',
                              success: result['ok'] == true,
                            );
                          }),
                          onRemove: () => _run('pair-remove', () async {
                            final symbol = '${_lastCheckResult!['symbol']}';
                            final base = _bareBase(symbol);
                            final result = await repo.requestPairAction(
                              'remove',
                              symbol,
                            );
                            final removed = result['ok'] == true;
                            var message =
                                '${result['message'] ?? (removed ? 'Removed.' : 'Failed.')}';
                            if (removed) {
                              final last = await repo.lastSelect([base]);
                              if (last['ok'] == true) {
                                message =
                                    '$message Also retired $base (was a running auto bot) — will finish naturally and never auto-recreate.';
                              }
                            }
                            _notify(message, success: removed);
                          }),
                          // Special case per the user: pressing Start on a pair
                          // that isn't on the Red List yet doesn't require a
                          // separate "Add to Red List" click first - it adds it
                          // automatically as part of starting.
                          onStart: () => _run('pair-start', () async {
                            final symbol = '${_lastCheckResult!['symbol']}';
                            final base = _bareBase(symbol);
                            final alreadyInRedList = status
                                .engineStatus
                                .redListSymbols
                                .contains(symbol);
                            if (!alreadyInRedList) {
                              final addResult = await repo.requestPairAction(
                                'add',
                                symbol,
                              );
                              if (addResult['ok'] != true) {
                                _notify(
                                  'Could not add $symbol to the Red List first: '
                                  '${addResult['message'] ?? 'failed'}.',
                                  success: false,
                                );
                                return;
                              }
                            }
                            // Per the user (2026-09-05, correcting an
                            // earlier misreading): Start is an on-spot
                            // check of ONLY this pair, never a full
                            // Red-list sweep - and it means "open this
                            // now", so it turns Auto on first if it's off.
                            // Start never changes Auto (per the user, 2026-11-08).
                            // Bug fixed 2026-09-10 - see the Next Trade
                            // table's matching fix: block for the real
                            // duration instead of firing-and-forgetting, so
                            // the button's loading/disabled state actually
                            // covers the whole process.
                            final result = await repo.requestStartAction([
                              symbol,
                            ]);
                            const autoNote = '';
                            final opened =
                                (result['opened'] as List?) ?? const [];
                            final prefix = alreadyInRedList
                                ? ''
                                : 'Added $symbol to the Red List. ';
                            _notify(
                              '$prefix${result['message'] ?? (opened.isNotEmpty ? 'Queued $base for the waiting engine.' : 'Nothing queued.')}$autoNote',
                              success: opened.isNotEmpty,
                            );
                          }),
                          onLast: () => _run('pair-last', () async {
                            final base = _bareBase(
                              '${_lastCheckResult!['symbol']}',
                            );
                            final result = await repo.lastSelect([base]);
                            final ok = result['ok'] == true;
                            _notify(
                              ok
                                  ? 'Retired $base — will finish naturally and never auto-recreate.'
                                  : '$base is not a currently-running auto bot — nothing to retire.',
                              success: ok,
                            );
                          }),
                          onStop: () => _run('pair-stop', () async {
                            final base = _bareBase(
                              '${_lastCheckResult!['symbol']}',
                            );
                            final bot = status.grids.appRunning
                                .cast<GridBot?>()
                                .firstWhere(
                                  (g) => g?.base.toUpperCase() == base,
                                  orElse: () => null,
                                );
                            if (bot == null) {
                              _notify(
                                '$base is not a currently-running auto bot — nothing to stop.',
                                success: false,
                              );
                              return;
                            }
                            await repo.stopSelected([bot.buOrderId]);
                            _notify('Stopped $base.', success: true);
                          }),
                          category:
                              _checkCategoryOverride ??
                              repo.pairCategories.categoryOf(
                                '${_lastCheckResult!['symbol']}',
                              ),
                          onCategoryChanged: (c) {
                            // Per the user (2026-09-10, correcting
                            // 2026-09-09): switching the knob must NOT
                            // pull fresh Pionex data - _lastCheckResult's
                            // own previewByCategory already carries all 3
                            // categories from the last check, so the panel
                            // switches instantly from what's already
                            // known. Only persist the pick for the engine
                            // to use next Start.
                            final symbol = '${_lastCheckResult!['symbol']}';
                            setState(() => _checkCategoryOverride = c);
                            repo.setPairCategory(symbol, c);
                          },
                          isCheckPending: _pendingChecks.contains(
                            '${_lastCheckResult!['symbol']}',
                          ),
                          investmentController: _investmentController,
                          onInvestmentCommitted: () {
                            _commitCheckInvestment(
                              repo,
                              '${_lastCheckResult!['symbol']}',
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
                ReuseCard(
                  // Per the user (2026-09-12): "auto card in controls screen
                  // should match 100% as in dashboard" - kept in lockstep
                  // with dashboard_screen.dart's own matching card,
                  // including its 2026-09-19 header restructuring (title
                  // text + AutoCategorySwitches share their own left
                  // column, independent of PnlSummaryView's height on the
                  // right) - see that file's matching comment for the full
                  // "why" (the summary widget growing a 3rd row used to
                  // push these toggles down via ReuseCard's shared
                  // title-row sizing).
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
                              onSummaryTap: () => context.push('/pnl-summary'),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: CoreSpacing.md),
                      GridsTable(
                    grids: status.grids.appRunning,
                    // Bug fixed 2026-09-16, per the user: same fix as
                    // dashboard_screen.dart's matching GridsTable - was
                    // gated only on `_busy`, never on the engine process
                    // being alive, so Stop/Last/Convert stayed clickable
                    // with Power off.
                    busy: _actionsBlocked(status, engineProcessAlive),
                    emptyMessage: 'No running auto bots right now.',
                    categoryOf: (id) => repo.botCategories.categoryOf(id),
                    entrySignalFor: (id) => repo.entrySignalFor(id),
                    closeCandidateFor: repo.closeCandidateFor,
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
                            // exactly why this refused, offer to bump this
                            // pair to $51 (per the user: "make it 51 usdt
                            // instead of 50" - genuinely clears Pionex's
                            // own "more than 50" wording) and retry, with
                            // a 5s auto-decline per the user's exact spec
                            // - a real, timely yes is required, nothing is
                            // forced silently.
                            final message = '${result['message'] ?? ''}';
                            if (result['ok'] != true &&
                                message.contains('requires investment over') &&
                                mounted &&
                                context.mounted) {
                              final wouldBeBotNumber =
                                  status.grids.appRunning.length +
                                  status.grids.manualRunning.length +
                                  1;
                              final symbol = '${base}USDT';
                              final agreed = await showTierLimitInvestmentDialog(
                                context,
                                symbol: symbol,
                                wouldBeBotNumber: wouldBeBotNumber,
                                bumpedInvestment: 51,
                              );
                              if (agreed) {
                                repo.setPairInvestment(symbol, 51);
                                result = await repo.igniteBase(base, category);
                              }
                            }
                            // Per the user: "if reading (data from trading
                            // view, pionex) fails, it stays in waiting
                            // with snackbar message" - notified directly
                            // (not via _run's throw/catch) so the snackbar
                            // shows the engine's own real reason, not a
                            // generic "Exception: " wrapper.
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
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Renders the last "Check" pair action's result: Red-List membership, and —
/// if the engine could compute one — the same live preview fields the
/// dashboard's "Last report" checklist shows for a Red List candidate. The
/// "Add to Red List" button only appears when the pair isn't already on it.
/// Renders the result of a "Check" and, ONLY once it's clear what actually
/// applies to this pair, the relevant follow-up action(s) - per the user:
/// no action buttons are offered up front, only after a successful check,
/// and only the ones that make sense for this specific pair's actual state
/// (on the Red List or not, has a running auto bot or not).
class _PairCheckResultView extends StatelessWidget {
  const _PairCheckResultView({
    required this.result,
    required this.disabled,
    required this.activeAction,
    required this.hasAutoBot,
    this.blocked = const {},
    required this.onAdd,
    required this.onRemove,
    required this.onStart,
    required this.onLast,
    required this.onStop,
    required this.category,
    required this.onCategoryChanged,
    required this.isCheckPending,
    required this.investmentController,
    required this.onInvestmentCommitted,
  });

  final Map<String, dynamic> result;

  /// True while this symbol's own category/investment edit has fired a
  /// check that hasn't come back from Pionex yet (2026-09-10, per the
  /// user) - shows a spinner in Actual investment/Extra margin instead of
  /// stale or dashed values.
  final bool isCheckPending;

  /// The category (1m/1H/1D) currently on file for this symbol - the knob
  /// next to it, and what a subsequent Start will use (2026-09-07).
  final AutoCategory category;
  final ValueChanged<AutoCategory> onCategoryChanged;

  /// The initial investment (USDT) field next to the knob (2026-09-09) -
  /// owned by the parent so its text survives this view being rebuilt.
  final TextEditingController investmentController;
  final VoidCallback onInvestmentCommitted;

  /// True while ANY action anywhere on the screen is running, or the engine
  /// is paused - disables every button here regardless of which one (if
  /// any) is the one actually in flight.
  final bool disabled;

  /// Which action id is actually running right now, if any - so only the
  /// ONE button that was actually clicked shows a spinner, not all five at
  /// once (matching every other action group on this screen).
  final String? activeAction;

  /// Whether this pair currently has an app-initiated grid running -
  /// determined by the caller from the live status, not from the check
  /// result (the engine's check doesn't know about running grids).
  final bool hasAutoBot;

  /// Which categories already have a running (or waiting-to-reopen) auto
  /// bot for this EXACT base (2026-09-12, per the user: "i want once pair
  /// is check, knob actions should match with next trade table = if the
  /// bot is running (yellow and deactivated check box)"). Drives this
  /// knob's own yellow "blocked" segments - the same [CategoryKnob.blocked]
  /// set the Next Trade table already passes via `_blockedByBase`, just
  /// computed for this one symbol instead of every row at once. (The
  /// "deactivated checkbox" half of the user's request doesn't apply here
  /// - this table is deliberately checkbox-less, see `showCheckboxColumn:
  /// false` below - it's always exactly one pair, nothing to batch-select.)
  final Set<AutoCategory> blocked;

  final VoidCallback onAdd;
  final VoidCallback onRemove;
  final VoidCallback onStart;
  final VoidCallback onLast;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final symbol = '${result['symbol'] ?? ''}';
    final inRedList = result['inRedList'] == true;
    // Only offer symbol-mutating actions (Add, Start - which can add on your
    // behalf) once the symbol was genuinely confirmed real (its 1H chart
    // actually loaded) - a check that timed out (e.g. an invalid/
    // concatenated symbol like "BTCETH") still reports `ok: true`
    // procedurally, but must not offer acting on a symbol that was never
    // actually verified to exist.
    final symbolVerified = result['symbolVerified'] == true;
    // Per the user (2026-09-06): a pair Pionex doesn't list as a tradeable
    // future still keeps Add/Remove (gated by symbolVerified above), but
    // must not offer Start/Last/Stop - none of those can ever actually
    // happen on it. Absent (older result shapes, or paths that only reach
    // this far because Pionex-listing was already confirmed) defaults to
    // listed, never to unlisted.
    final pionexListed = result['pionexListed'] != false;
    // Per the user (2026-09-08): the Check card now gets all 3 categories'
    // data at once (same practice as Check Now) - the knob just switches
    // which one is displayed, no re-check needed. Falls back to the
    // top-level preview/message (older result shape, or the unlisted-on-
    // Pionex short-circuit which never computed any category's data).
    final byCategory = (result['previewByCategory'] as Map?)
        ?.cast<String, dynamic>();
    final forCategory = byCategory?[category.wireValue] as Map?;
    final categoryMessage = forCategory?['message'] as String?;
    final previewJson =
        (forCategory?['preview'] as Map<String, dynamic>?) ??
        result['preview'] as Map<String, dynamic>?;
    final preview = previewJson == null
        ? null
        : PreviewGridPair.fromJson(previewJson);
    // Which categories have no live signal for this symbol right now -
    // drives the knob's red-tinted segments (2026-09-09, per the user).
    // Empty (nothing marked red) when previewByCategory is absent entirely
    // (older result shape, or the unlisted-on-Pionex short-circuit) - there
    // simply isn't enough information to judge any category as unavailable.
    final unavailableCategories = byCategory == null
        ? const <AutoCategory>{}
        : {
            for (final c in allAutoCategories)
              if ((byCategory[c.wireValue] as Map?)?['preview'] == null) c,
          };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(symbol, style: textTheme.titleSmall)),
            ReuseChip(
              label: inRedList ? 'On Red List' : 'Not on Red List',
              tone: inRedList ? ReuseChipTone.success : ReuseChipTone.warning,
            ),
            if (hasAutoBot) ...[
              const SizedBox(width: CoreSpacing.xs),
              const ReuseChip(label: 'Auto bot running'),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Text(
          categoryMessage ?? '${result['message'] ?? ''}',
          style: textTheme.bodySmall,
        ),
        if (symbolVerified) ...[
          const SizedBox(height: CoreSpacing.sm),
          // Same table as the Next Trade table (2026-09-10, per the user) -
          // same columns, same formatting, just no checkbox/loading-
          // indicator column (there's nothing to select here, this is
          // always exactly one pair).
          ReuseDataTable(
            showCheckboxColumn: false,
            columns: previewDataColumns,
            rows: [
              DataRow(
                cells: [
                  DataCell(
                    Text(symbol),
                    onTap: preview == null
                        ? null
                        : () => context.push('/pair-preview', extra: preview),
                  ),
                  DataCell(
                    CategoryKnob(
                      value: category,
                      // Per the user (2026-09-10): tapping the
                      // already-selected segment again must not pull
                      // fresh Pionex data again, same rule as the Next
                      // Trade table's own knob.
                      onChanged: (c) {
                        if (c == category) return;
                        onCategoryChanged(c);
                      },
                      unavailable: unavailableCategories,
                      blocked: blocked,
                    ),
                  ),
                  DataCell(
                    SizedBox(
                      width: 76,
                      child: TextField(
                        controller: investmentController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        style: const TextStyle(fontSize: 13),
                        decoration: const InputDecoration(
                          prefixText: r'$',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 6,
                          ),
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => onInvestmentCommitted(),
                        onTapOutside: (_) => onInvestmentCommitted(),
                      ),
                    ),
                  ),
                  for (final cell in previewComputedCells(
                    preview,
                    pending: isCheckPending,
                  ))
                    DataCell(
                      cell,
                      onTap: preview == null
                          ? null
                          : () =>
                                context.push('/pair-preview', extra: preview),
                    ),
                ],
              ),
            ],
          ),
        ],
        if (symbolVerified) ...[
          const SizedBox(height: CoreSpacing.sm),
          Wrap(
            spacing: CoreSpacing.sm,
            runSpacing: CoreSpacing.sm,
            children: [
              if (inRedList)
                ReuseButton(
                  label: 'Remove from Red List',
                  icon: Icons.playlist_remove,
                  tone: ReuseButtonTone.danger,
                  loading: activeAction == 'pair-remove',
                  onPressed: disabled ? null : onRemove,
                )
              else
                ReuseButton(
                  label: 'Add to Red List',
                  icon: Icons.playlist_add,
                  loading: activeAction == 'pair-add',
                  onPressed: disabled ? null : onAdd,
                ),
              // Per the user (2026-09-12): "once knob is yellow ... it
              // means start button is deactivated ... so if user choose
              // 3m and it is yellow, start button is deactivated." Was
              // gated on `hasAutoBot` (true whenever ANY category has a
              // running bot for this base), so switching the knob to a
              // genuinely free category (e.g. 1H, while only 3m is
              // running) never brought Start back - the exact
              // per-category exception the rest of this app's "blocked"
              // rule already carves out (a pair can have up to 3
              // simultaneous grids, one per category). Now gated on
              // `blocked.contains(category)` - the SELECTED segment's own
              // blocked state - matching the knob's own yellow highlight
              // exactly.
              if (blocked.contains(category)) ...[
                ReuseButton(
                  label: 'Last',
                  icon: Icons.flag_outlined,
                  tone: ReuseButtonTone.neutral,
                  loading: activeAction == 'pair-last',
                  onPressed: disabled ? null : onLast,
                ),
                ReuseButton(
                  label: 'Stop',
                  icon: Icons.stop_circle_outlined,
                  tone: ReuseButtonTone.danger,
                  loading: activeAction == 'pair-stop',
                  onPressed: disabled ? null : onStop,
                ),
              ] else if (pionexListed)
                ReuseButton(
                  label: 'Start',
                  icon: Icons.rocket_launch_outlined,
                  loading: activeAction == 'pair-start',
                  onPressed: disabled ? null : onStart,
                ),
            ],
          ),
        ],
      ],
    );
  }
}
