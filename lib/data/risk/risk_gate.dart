import '../../core/core_storage.dart';
import '../models/app_config.dart';
import '../models/auto_category.dart';
import '../models/risk_state.dart';

class GateResult {
  const GateResult.allowed() : allowed = true, reason = null;
  const GateResult.blocked(this.reason) : allowed = false;

  final bool allowed;
  final String? reason;
}

/// Per-symbol position cap and the STOP kill switch — ported 1:1 from
/// lib/risk.js. `close` is always allowed; `open` is the only gated action
/// (PRD §10 rule 7). Day boundaries are UTC midnight (see RiskState doc)
/// rather than the original's local-midnight bug.
///
/// Daily loss limit, trade-count cap, and cooldown removed 2026-09-15, per
/// the user - none of them were ever actually functioning (see
/// `RiskConfig`'s doc for the full explanation).
class RiskGate {
  RiskGate(this._storage, this._config) {
    _state = _loadOrReset();
  }

  final CoreStorage _storage;
  final RiskConfig _config;
  late RiskState _state;

  RiskState _loadOrReset() {
    final json = _storage.readJsonObject(_storage.stateFile);
    var state = json != null
        ? RiskState.fromJson(json)
        : RiskState.freshForToday();
    final todayStart = RiskState.utcMidnightMs(DateTime.now());
    if (state.dayStartUtcMs != todayStart) {
      state = RiskState.freshForToday();
      _persist(state);
    }
    return state;
  }

  void _persist(RiskState state) =>
      _storage.writeJson(_storage.stateFile, state.toJson());

  bool get killSwitchTripped => _storage.fileExists(_storage.stopFile);

  /// Keys [RiskState.openPositions] by symbol+category (2026-09-18, per the
  /// user: "this form is wrong. you have to make it max per symbol per
  /// interval = 1") — was keyed by bare symbol alone, which meant a symbol
  /// could only ever hold ONE real position across ALL THREE categories
  /// combined, contradicting the engine's own already-documented design
  /// ("a pair can have up to 3 simultaneous app-owned grids, one per
  /// category" — see `_manageGridPair`'s `entryKey`/`_appGridForKey`, which
  /// were ALREADY correctly category-scoped). `maxPerSymbol` now means "per
  /// symbol, per category" — e.g. XRP can hold one real position under 3m
  /// AND a separate one under 1H AND a separate one under 1D at the same
  /// time, but never two under the SAME category at once. This restores
  /// the category-scoping every other piece of per-pair bookkeeping in the
  /// engine already uses (`entryKey`, `_nextInvestmentByPair`,
  /// `_openEntryByPair`), which this was the one remaining exception to.
  String _key(String symbol, AutoCategory category) =>
      '$symbol|${category.wireValue}';

  /// [replacingOne]: the caller is about to close this pair's running position
  /// and reopen it (a recycle), so that position doesn't count against the cap.
  GateResult gate(
    String action,
    String symbol,
    AutoCategory category, {
    bool replacingOne = false,
  }) {
    if (action == 'close') return const GateResult.allowed();

    _rolloverIfNewDay();

    if (killSwitchTripped) {
      return const GateResult.blocked('KILL SWITCH: STOP file present');
    }
    // REMOVED ENTIRELY (2026-09-10, explicit user instruction: "max number
    // of trades per day is unlimited... i did not request this at all") -
    // there is no daily trade-count cap. `dayTrades`/`maxTradesPerDay` were
    // removed outright from RiskState/RiskConfig, not just left unused -
    // per the user, disabling it wasn't enough, it had to be gone.
    final key = _key(symbol, category);
    final perSymbol = _state.openPositions[key] ?? 0;
    if (perSymbol - (replacingOne ? 1 : 0) >= _config.maxPerSymbol) {
      return GateResult.blocked(
        'Max positions for $symbol[${category.label}]: $perSymbol/${_config.maxPerSymbol}',
      );
    }
    return const GateResult.allowed();
  }

  void openPosition(String symbol, AutoCategory category) {
    _rolloverIfNewDay();
    final key = _key(symbol, category);
    _state.openPositions[key] = (_state.openPositions[key] ?? 0) + 1;
    _persist(_state);
  }

  /// BUG FIX carried over intentionally from the original (2026-08-29): this
  /// MUST be called on every close, mirroring openPosition — the original
  /// engine went weeks without calling it, so position counters only ever
  /// grew until max_positions/max_per_symbol permanently blocked all further
  /// opens. Never regress this.
  void closePosition(String symbol, AutoCategory category) {
    final key = _key(symbol, category);
    final current = _state.openPositions[key];
    if (current != null) {
      final next = current - 1;
      if (next <= 0) {
        _state.openPositions.remove(key);
      } else {
        _state.openPositions[key] = next;
      }
    }
    _persist(_state);
  }

  /// One-time migration hook (2026-09-18) — replaces the ENTIRE
  /// [RiskState.openPositions] map with counts rebuilt from a real,
  /// just-fetched Pionex snapshot (one `(symbol, category)` entry per
  /// currently-open app-initiated position), instead of trying to migrate
  /// old bare-symbol keys that never carried a category to migrate from.
  /// Called exactly once by the engine right after the key format changed
  /// from bare-symbol to symbol+category, so an already-open real position
  /// doesn't silently read back as "0 open" (and let something exceed
  /// [RiskConfig.maxPerSymbol] that shouldn't) just because its old key
  /// stopped matching anything.
  void resetTo(Iterable<(String symbol, AutoCategory category)> openPositions) {
    final counts = <String, int>{};
    for (final (symbol, category) in openPositions) {
      final key = _key(symbol, category);
      counts[key] = (counts[key] ?? 0) + 1;
    }
    _state.openPositions
      ..clear()
      ..addAll(counts);
    _persist(_state);
  }

  RiskState get status => _state;

  void _rolloverIfNewDay() {
    final todayStart = RiskState.utcMidnightMs(DateTime.now());
    if (_state.dayStartUtcMs != todayStart) {
      _state = RiskState.freshForToday();
      _persist(_state);
    }
  }
}
