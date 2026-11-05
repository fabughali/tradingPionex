import 'auto_category.dart';

enum EngineRunState { stopped, running, paused, killSwitched }

/// The one symbol the Checkup track's (Check Now/Start) own rotating cycle
/// marker is built from (2026-09-12, per the user - see
/// [EngineStatus.checkupCycleMarkerIndex]'s doc). Distinct from every
/// [AutoCategoryX.cycleMarkerSymbol] so it can never be confused with one
/// of the per-category markers.
const checkupCycleMarkerSymbol = '✓';

/// The actual marker text for rotation position [index] (0/1/2, wrapping) -
/// same single/double/triple-symbol convention as the auto-category
/// markers.
String checkupCycleMarkerFor(int index) =>
    checkupCycleMarkerSymbol * ((index % 3) + 1);

/// One [AutoCategory]'s own status (2026-09-07) - each of the 3 engines is
/// fully independent, so each gets its own message/busy/candle-anchor/
/// enabled state, same shape as the pre-existing single Auto-checkup track
/// used to have.
class AutoCategoryStatus {
  const AutoCategoryStatus({
    this.message = '',
    this.busy = false,
    this.lastCandleTimeMs,
    this.enabled = true,
    this.cycleMarkerIndex = 0,
  });

  final String message;
  final bool busy;
  final int? lastCandleTimeMs;

  /// This category's own on/off switch (independent of Power and of the
  /// other 2 categories) - Power off still overrides every category
  /// regardless of this.
  final bool enabled;

  /// Which of this category's 3 rotating cycle markers (single/double/
  /// triple symbol) is current right now (2026-09-12, per the user: "add
  /// an icon/emoji next to pair name... matching the one selected by auto
  /// interval... each time new interval occurs, new emoji/icon... this
  /// will help user to identify and assure if all list get checked in
  /// this interval or not"). Advances by one (mod 3) each time this
  /// category's own candle-gated cycle genuinely starts a new pass - never
  /// on a force-triggered/manual check, since that isn't a new scheduled
  /// interval. In-memory only, resets to 0 on every engine restart (per
  /// the user, this is purely a visual same-sweep indicator, not something
  /// worth persisting). Each category uses its OWN distinct symbol (see
  /// `AutoCategoryX.cycleMarkerSymbol`) specifically so two categories can
  /// never show the identical marker even if their indices happen to
  /// coincide - per the user: "never choose icon/emoji/star that matches
  /// with other toggle."
  final int cycleMarkerIndex;

  DateTime? get lastCandleTime => lastCandleTimeMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(lastCandleTimeMs!);

  factory AutoCategoryStatus.fromJson(Map<String, dynamic> json) =>
      AutoCategoryStatus(
        message: json['message'] as String? ?? '',
        busy: json['busy'] as bool? ?? false,
        lastCandleTimeMs: (json['last_candle_time_ms'] as num?)?.toInt(),
        enabled: json['enabled'] as bool? ?? true,
        cycleMarkerIndex: (json['cycle_marker_index'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
    'message': message,
    'busy': busy,
    'last_candle_time_ms': lastCandleTimeMs,
    'enabled': enabled,
    'cycle_marker_index': cycleMarkerIndex,
  };
}

/// Snapshot the engine process writes to logs/status.json every mainLoop
/// cycle (see EngineService), and that the GUI reads to report on the
/// engine without needing to be in the same process — the same loose,
/// file-based coupling the original OpenCode control scripts used.
class EngineStatus {
  const EngineStatus({
    required this.state,
    required this.updatedAtMs,
    required this.cdpHealthy,
    required this.pionexHealthy,
    this.internetHealthy = true,
    this.lastCycleMessage = '',
    this.busy = false,
    this.urgent = false,
    this.autoCheckupMessage = '',
    this.autoCheckupBusy = false,
    this.activeGridCount = 0,
    this.appInitiatedGridCount = 0,
    this.lastCandleTimeMs,
    this.lastAutoCandleTimeMs,
    this.redListSymbols = const [],
    this.checkupPairIndex = 0,
    this.checkupPairTotal = 0,
    this.checkupCurrentBase = '',
    this.waitingEngineCurrentBase = '',
    this.waitingEngineIdleReason = '',
    this.waitingEngineTriedBases = const [],
    this.checkupCycleMarkerIndex = 0,
    this.autoCategories = const {},
  });

  final EngineRunState state;
  final int updatedAtMs;
  final bool cdpHealthy;
  final bool pionexHealthy;

  /// Plain DNS-reachability check against Pionex's own domain (2026-09-11,
  /// per the user - a "long time to connect to chart" complaint traced to
  /// intermittent internet outages that were only ever logged to
  /// engine.log, never surfaced to the GUI). Distinct from [cdpHealthy]
  /// (TradingView-specific) and [pionexHealthy] (API-specific) - this
  /// answers "is there internet at all." Defaults true so older/incomplete
  /// status snapshots don't trigger a false alarm.
  final bool internetHealthy;

  /// What the full Checkup track (Check Now/Start, whole Red list) is doing
  /// right now - deliberately separate from [autoCheckupMessage] since the
  /// two are independent processes and must never be shown as one shared
  /// line (per the user, 2026-09-04).
  final String lastCycleMessage;

  /// What the Auto-checkup track (auto-managed bases only) is doing right
  /// now - see [lastCycleMessage].
  final String autoCheckupMessage;

  /// True only while a mainLoop cycle is actively mid-flight (connecting to
  /// TradingView, verifying/reloading indicators, checking balance, syncing
  /// bot memory) — [lastCycleMessage] is the human-readable phase in that
  /// case. Written back to false the moment the cycle finishes, so the GUI
  /// can distinguish "busy right now" from "message left over from the last
  /// cycle" without guessing from timestamps.
  final bool busy;

  /// True only for the per-pair indicator wait-ladder (30s/20s/10s/5s/5s,
  /// resetting once loaded — your original spec) — worth calling more
  /// attention to than an ordinary busy phase since it's the one place a
  /// single problem pair can visibly stall the whole cycle. The GUI blinks
  /// faster and names the pair in a SnackBar while this is true.
  final bool urgent;

  /// [busy]'s equivalent for the Auto-checkup track.
  final bool autoCheckupBusy;
  final int activeGridCount;
  final int appInitiatedGridCount;

  /// The open time (epoch ms) of the last 1H candle the engine actually
  /// processed a checkup for — the candle-gate anchor. Since 1H candles are
  /// aligned to the top of the hour, `lastCandleTime + 1h` is a good estimate
  /// of when the next checkup will fire. Null until the engine completes its
  /// first candle-gated cycle.
  final int? lastCandleTimeMs;

  /// Same idea as [lastCandleTimeMs], but Auto's own anchor - Auto is the
  /// only track that actually runs on a real recurring schedule (once per
  /// hour, on auto-managed bases only), so "next checkup after" in the GUI
  /// is this one, not Checkup's (Checkup is on-demand only - it has no
  /// "next" time to count down to).
  final int? lastAutoCandleTimeMs;

  /// The current "Red list" watchlist, as last read by the engine — the only
  /// process with CDP access. The GUI shows this for "available pairs"
  /// without ever touching TradingView itself.
  final List<String> redListSymbols;

  /// The Checkup track's (Check Now/Start) progress through the current
  /// pass, 1-based - "pair 5 of 27" - so the Dashboard's Check Now button
  /// can show real progress, not just a generic spinner. Both 0 while no
  /// Checkup pass is running.
  final int checkupPairIndex;
  final int checkupPairTotal;

  /// The base symbol (e.g. "ETH") the Checkup track is reading right now -
  /// empty whenever no Checkup pass is mid-flight. Used to swap that one
  /// Next Trade row's checkbox for a loading indicator while its data is
  /// actively being refreshed from TradingView/Pionex.
  final String checkupCurrentBase;

  /// The "SYMBOL/CATEGORY" the waiting engine is retrying right now (2026-09-
  /// 11, per the user: "i want you to add status below waiting to show
  /// user what is going on now once waiting engine is running") - empty
  /// whenever no waiting-engine pass is mid-flight. Deliberately separate
  /// from [checkupCurrentBase] - a different track, same reasoning as
  /// [lastCycleMessage] vs [autoCheckupMessage].
  final String waitingEngineCurrentBase;

  /// Why the waiting engine is currently idle (empty [waitingEngineCurrentBase])
  /// - 2026-09-12, per the user ("nope i dont like this .. i want status
  /// to reflect actual"): the GUI used to show one FIXED idle message
  /// regardless of the real reason ("the regular checkup pass has the
  /// chart right now"), which went stale the moment a second, different
  /// stop condition (the one-attempt-per-cycle throttle, same day) was
  /// added - a base already attempted this cycle is a completely
  /// different situation from the chart genuinely being busy elsewhere,
  /// and deserves its own accurate wording. REVISED same day, per the
  /// user ("i dont want any waiting pairs"): the per-cycle throttle
  /// behind `'attempted'` left the chart sitting fully idle for whatever
  /// remained of a 3-minute cycle once every waiting base had used its
  /// one shot - replaced by a short per-base cooldown, so `'attempted'`
  /// became `'cooldown'`. Gained a fifth value same day, after the
  /// cooldown change above turned into a real (not display-only)
  /// regression: retrying forever with no return meant the real scheduled
  /// 3m pass could never start again, silently starving it for as long
  /// as any base kept failing. `'new_cycle'` marks the fix - the waiting
  /// engine yields the moment a fresh 3m boundary is due, letting that
  /// real pass run before resuming. One of: `''` (never run yet this
  /// session, or genuinely mid-attempt), `'empty'` (waiting list has
  /// nothing left - real success), `'cooldown'` (every remaining base is
  /// on its short retry cooldown - resumes within seconds, not stuck),
  /// `'chart_busy'` (Check Now/a pair action/force-stop genuinely needs
  /// the chart right now), `'new_cycle'` (the real scheduled 3m pass is
  /// due and running now - resumes right after).
  final String waitingEngineIdleReason;

  /// Keys (`"CATEGORY_WIRE_VALUE|BASE"`, e.g. `"ONE_HOUR|XRP"`) of every
  /// waiting base with at least one failed open attempt still on its retry
  /// cooldown - straight off the engine's own `_waitingEngineLastAttemptAt`
  /// map (2026-09-12, per the user: "i want to see xrpusdt (problem pair)
  /// at the last of wrap too"). The engine's own retry loop already checks
  /// these bases last (see the `retryable.sort` in `_runWaitingEngine`);
  /// this field lets the GUI's "Waiting:" chip row apply the exact same
  /// ordering instead of showing the auto-managed list's raw, unsorted
  /// order. Empty whenever nothing has failed yet this session.
  final List<String> waitingEngineTriedBases;

  /// Which of the Checkup track's 3 rotating cycle markers (single/double/
  /// triple checkmark) is current right now (2026-09-12, per the user) -
  /// same idea as `AutoCategoryStatus.cycleMarkerIndex`, but for Check
  /// Now/Start's own sweep over the whole red list rather than a per-
  /// category auto engine. Advances only on a genuinely fresh sweep
  /// (never a resume). In-memory only, resets to 0 on restart.
  final int checkupCycleMarkerIndex;

  /// Per-category status for all 3 Auto engines (2026-09-07) - the 1H
  /// entry duplicates [autoCheckupMessage]/[autoCheckupBusy]/
  /// [lastAutoCandleTimeMs] (kept for anything still reading those
  /// top-level fields directly); 1m/1D only exist here.
  final Map<AutoCategory, AutoCategoryStatus> autoCategories;

  AutoCategoryStatus statusFor(AutoCategory c) =>
      autoCategories[c] ?? const AutoCategoryStatus();

  DateTime get updatedAt => DateTime.fromMillisecondsSinceEpoch(updatedAtMs);
  DateTime? get lastCandleTime => lastCandleTimeMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(lastCandleTimeMs!);
  DateTime? get lastAutoCandleTime => lastAutoCandleTimeMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(lastAutoCandleTimeMs!);

  static const notRunning = EngineStatus(
    state: EngineRunState.stopped,
    updatedAtMs: 0,
    cdpHealthy: false,
    pionexHealthy: false,
  );

  factory EngineStatus.fromJson(Map<String, dynamic> json) => EngineStatus(
    state: EngineRunState.values.firstWhere(
      (s) => s.name == json['state'],
      orElse: () => EngineRunState.stopped,
    ),
    updatedAtMs: (json['updated_at_ms'] as num?)?.toInt() ?? 0,
    cdpHealthy: json['cdp_healthy'] as bool? ?? false,
    pionexHealthy: json['pionex_healthy'] as bool? ?? false,
    internetHealthy: json['internet_healthy'] as bool? ?? true,
    lastCycleMessage: json['last_cycle_message'] as String? ?? '',
    busy: json['busy'] as bool? ?? false,
    urgent: json['urgent'] as bool? ?? false,
    autoCheckupMessage: json['auto_checkup_message'] as String? ?? '',
    autoCheckupBusy: json['auto_checkup_busy'] as bool? ?? false,
    activeGridCount: (json['active_grid_count'] as num?)?.toInt() ?? 0,
    appInitiatedGridCount:
        (json['app_initiated_grid_count'] as num?)?.toInt() ?? 0,
    lastCandleTimeMs: (json['last_candle_time_ms'] as num?)?.toInt(),
    lastAutoCandleTimeMs: (json['last_auto_candle_time_ms'] as num?)?.toInt(),
    redListSymbols: ((json['red_list_symbols'] as List?) ?? const [])
        .cast<String>(),
    checkupPairIndex: (json['checkup_pair_index'] as num?)?.toInt() ?? 0,
    checkupPairTotal: (json['checkup_pair_total'] as num?)?.toInt() ?? 0,
    checkupCurrentBase: json['checkup_current_base'] as String? ?? '',
    waitingEngineCurrentBase:
        json['waiting_engine_current_base'] as String? ?? '',
    waitingEngineIdleReason:
        json['waiting_engine_idle_reason'] as String? ?? '',
    waitingEngineTriedBases:
        ((json['waiting_engine_tried_bases'] as List?) ?? const [])
            .cast<String>(),
    checkupCycleMarkerIndex:
        (json['checkup_cycle_marker_index'] as num?)?.toInt() ?? 0,
    autoCategories: {
      for (final entry
          in ((json['auto_categories'] as Map?) ?? const {}).entries)
        if (autoCategoryFromWire(entry.key as String) != null)
          autoCategoryFromWire(entry.key as String)!:
              AutoCategoryStatus.fromJson(
                (entry.value as Map).cast<String, dynamic>(),
              ),
    },
  );

  Map<String, dynamic> toJson() => {
    'state': state.name,
    'updated_at_ms': updatedAtMs,
    'cdp_healthy': cdpHealthy,
    'pionex_healthy': pionexHealthy,
    'internet_healthy': internetHealthy,
    'last_cycle_message': lastCycleMessage,
    'busy': busy,
    'urgent': urgent,
    'auto_checkup_message': autoCheckupMessage,
    'auto_checkup_busy': autoCheckupBusy,
    'active_grid_count': activeGridCount,
    'app_initiated_grid_count': appInitiatedGridCount,
    'last_candle_time_ms': lastCandleTimeMs,
    'last_auto_candle_time_ms': lastAutoCandleTimeMs,
    'red_list_symbols': redListSymbols,
    'checkup_pair_index': checkupPairIndex,
    'checkup_pair_total': checkupPairTotal,
    'checkup_current_base': checkupCurrentBase,
    'waiting_engine_current_base': waitingEngineCurrentBase,
    'waiting_engine_idle_reason': waitingEngineIdleReason,
    'waiting_engine_tried_bases': waitingEngineTriedBases,
    'checkup_cycle_marker_index': checkupCycleMarkerIndex,
    'auto_categories': {
      for (final entry in autoCategories.entries)
        entry.key.wireValue: entry.value.toJson(),
    },
  };

  /// The heartbeat/status is considered stale (engine process likely dead,
  /// not just idling between hourly candles) past this age.
  bool isStale(Duration maxAge) =>
      DateTime.now().difference(updatedAt) > maxAge;
}
