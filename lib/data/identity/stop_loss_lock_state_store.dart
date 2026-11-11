import '../../core/core_storage.dart';

/// Per-buOrderId state for Stop Loss Lock (rewritten 2026-11-09, per the
/// user - see `sll_rules.dart`). Persisted so an engine restart never
/// re-clears an SL that SLL already locked, and never loosens a lock.
///
/// - [started]: the bot's start-of-trade TP/SL was set once (TP at the
///   range edge, SL blank) - never touched again.
/// - [lockedUsd]: the profit (USDT) SL is locked at - only ever goes up.
class StopLossLockStateStore {
  StopLossLockStateStore(this._storage) {
    load();
  }

  final CoreStorage _storage;
  final Set<String> _startedIds = {};
  final Map<String, double> _lockedUsdByBotId = {};

  /// Money taken out of a bot's margin for a top-up whose add-investment
  /// step failed (per the user, 2026-11-09): it stays booked for that bot
  /// and is retried until it is added.
  final Map<String, double> _owedByBotId = {};

  void load() {
    final raw = _storage.readJsonObject(_storage.stopLossLockStateFile) ?? const {};
    _startedIds.clear();
    _lockedUsdByBotId.clear();
    _owedByBotId.clear();
    raw.forEach((id, value) {
      if (value is! Map) return;
      if (value['started'] == true) _startedIds.add(id);
      final usd = value['lockedUsd'];
      if (usd is num) _lockedUsdByBotId[id] = usd.toDouble();
      final owed = value['owed'];
      if (owed is num && owed > 0) _owedByBotId[id] = owed.toDouble();
    });
  }

  void _persist() {
    final ids = {..._startedIds, ..._lockedUsdByBotId.keys, ..._owedByBotId.keys};
    _storage.writeJson(_storage.stopLossLockStateFile, {
      for (final id in ids)
        id: {
          'started': _startedIds.contains(id),
          if (_lockedUsdByBotId[id] != null) 'lockedUsd': _lockedUsdByBotId[id],
          if (_owedByBotId[id] != null) 'owed': _owedByBotId[id],
        },
    });
  }

  double? owed(String buOrderId) => _owedByBotId[buOrderId];

  /// All booked top-up money, across bots.
  double get totalOwed => _owedByBotId.values.fold(0.0, (a, b) => a + b);

  /// 0 (or less) clears it.
  void setOwed(String buOrderId, double amount) {
    if (amount > 0) {
      _owedByBotId[buOrderId] = amount;
    } else if (_owedByBotId.remove(buOrderId) == null) {
      return;
    }
    _persist();
  }

  bool started(String buOrderId) => _startedIds.contains(buOrderId);

  void markStarted(String buOrderId) {
    if (_startedIds.add(buOrderId)) _persist();
  }

  double? lockedUsd(String buOrderId) => _lockedUsdByBotId[buOrderId];

  /// Never lowers an existing lock.
  void recordLock(String buOrderId, double usd) {
    final current = _lockedUsdByBotId[buOrderId];
    if (current != null && usd <= current) return;
    _lockedUsdByBotId[buOrderId] = usd;
    _persist();
  }

  void forget(String buOrderId) {
    final removed =
        _startedIds.remove(buOrderId) |
        (_lockedUsdByBotId.remove(buOrderId) != null) |
        (_owedByBotId.remove(buOrderId) != null);
    if (removed) _persist();
  }
}
