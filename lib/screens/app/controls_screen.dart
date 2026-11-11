import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/core_layout.dart';
import '../../core/core_spacing.dart';
import '../../data/control/engine_control_repository.dart';
import '../../data/models/auto_category.dart';
import '../../data/models/grid_bot.dart';
import '../../data/models/preview_grid_pair.dart';
import '../../data/pionex/pionex_market.dart';
import '../../data/providers/app_providers.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/category_knob.dart';
import '../../widgets/reuse_button.dart';
import '../../widgets/reuse_card.dart';
import '../../widgets/reuse_chip.dart';
import '../../widgets/reuse_error.dart';
import '../../widgets/reuse_data_table.dart';
import '../../widgets/reuse_loading_indicator.dart';
import '../../widgets/report_section.dart';

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

  /// Check Now's spinner while Pionex's list refreshes.
  bool _refreshingMarket = false;

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

  @override
  void dispose() {
    _pairController.dispose();
    super.dispose();
  }

  /// What the user typed, as a Pionex base: "eth", "ETHUSDT", "eth/usdt",
  /// "ETH_USDT_PERP" -> "ETH".
  String _searchBase(String raw) {
    var s = raw.trim().toUpperCase();
    if (s.contains(':')) s = s.split(':').last;
    s = s.replaceAll(RegExp(r'[^A-Z0-9]'), '');
    s = s.replaceAll(RegExp(r'PERP$'), '');
    for (final quote in const ['USDT', 'USD']) {
      if (s.length > quote.length && s.endsWith(quote)) {
        s = s.substring(0, s.length - quote.length);
        break;
      }
    }
    return s;
  }

  /// Start for the ticked pairs (Next Trade and the Pair actions search).
  Future<void> _startSymbols(
    EngineControlRepository repo,
    List<String> symbols,
    String actionId,
  ) => _run(actionId, () async {
    // Start never changes Auto (per the user, 2026-11-08).
    final result = await repo.requestStartAction(
      symbols,
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
    final skipped = (result['skipped'] as Map?) ?? const {};
    if (opened.isEmpty && skipped.isEmpty) {
      _notify(
        '${result['message'] ?? 'Start did not complete.'}',
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
    _notify(parts.join(' '), success: opened.isNotEmpty);
  });

  Future<void> _run(    String actionId,
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
                  child: Builder(
                    builder: (context) {
                      // Searches Pionex's own list only - no TradingView
                      // (per the user, 2026-11-11). "eth", "ETHUSDT",
                      // "eth/usdt" all find ETH; a pair with a running or
                      // waiting Auto trade can't be ticked.
                      final market =
                          ref.watch(pionexMarketProvider).value ?? const [];
                      final q = _searchBase(_pairController.text);
                      final found = q.isEmpty
                          ? const <MarketPair>[]
                          : market.where((m) => m.base.startsWith(q)).toList();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextField(
                            controller: _pairController,
                            decoration: const InputDecoration(
                              hintText: 'Search Pionex, e.g. ETH or ETHUSDT',
                              prefixIcon: Icon(Icons.search),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                          if (q.isNotEmpty && found.isEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: CoreSpacing.sm),
                              child: Text('No Pionex pair matches "${_pairController.text.trim()}".'),
                            ),
                          if (found.isNotEmpty) ...[
                            const SizedBox(height: CoreSpacing.sm),
                            PreviewChecklist(
                              key: ValueKey('search-$q'),
                              entries: status.lastReport.entries,
                              freeBalance: status.availableBalance,
                              busy: _actionsBlocked(status, engineProcessAlive),
                              startLoading: _activeAction == 'start-search',
                              onStart: (symbols) =>
                                  _startSymbols(repo, symbols, 'start-search'),
                              categoryOf: (symbol) =>
                                  repo.pairCategories.categoryOf(symbol),
                              onCategoryChanged: (symbol, category) =>
                                  repo.setPairCategory(symbol, category),
                              investmentOf: (symbol) =>
                                  repo.pairInvestments.investmentOf(symbol),
                              onInvestmentChanged:
                                  (symbol, amount, category, hasData) =>
                                      repo.setPairInvestment(symbol, amount),
                              isCheckPending: (symbol) =>
                                  _pendingChecks.contains(symbol),
                              blockedByBase: _blockedByBase(status, repo),
                              market: found,
                              momentum:
                                  ref.watch(priceMomentumProvider).value?.readings ??
                                  const {},
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ),
                ReportSection(
                  report: status.lastReport,
                  engineStatus: status.engineStatus,
                  freeBalance: status.availableBalance,
                  pionexBalance: status.balance.free,
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
                  momentum:
                      ref.watch(priceMomentumProvider).value?.readings ??
                      const {},

                  // Per the user (2026-09-05, correcting an earlier
                  // misreading): Start is an on-spot check of ONLY the
                  // selected pair(s) - never a full Red-list sweep.
                  // Pressing it while Auto is off also means "open these
                  // now", so it turns Auto on first (same as the Auto
                  // switch's own turnOn path) before triggering the
                  // targeted check; whatever Checkup/Auto-checkup pass it
                  // interrupts resumes automatically once it's done.
                  onStart: (symbols) => _startSymbols(repo, symbols, 'start-selected'),
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
              ],
            ),
          );
        },
      ),
    );
  }
}
