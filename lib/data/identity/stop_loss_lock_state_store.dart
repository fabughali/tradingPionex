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

  /// When SL was last cleared for a top-up (per the user, 2026-11-15): the
  /// $50 lock waits [sllLockPauseAfterTopUp] after this, then starts fresh.
  final Map<String, DateTime> _topUpAtByBotId = {};

  void load() {
    final raw = _storage.readJsonObject(_storage.stopLossLockStateFile) ?? const {};
    _startedIds.clear();
    _lockedUsdByBotId.clear();
    _owedByBotId.clear();
    _topUpAtByBotId.clear();
    raw.forEach((id, value) {
      if (value is! Map) return;
      if (value['started'] == true) _startedIds.add(id);
      final usd = value['lockedUsd'];
      if (usd is num) _lockedUsdByBotId[id] = usd.toDouble();
      final owed = value['owed'];
      if (owed is num && owed > 0) _owedByBotId[id] = owed.toDouble();
      final at = DateTime.tryParse('${value['topUpAt']}');
      if (at != null) _topUpAtByBotId[id] = at;
    });
  }

  void _persist() {
    final ids = {
      ..._startedIds,
      ..._lockedUsdByBotId.keys,
      ..._owedByBotId.keys,
      ..._topUpAtByBotId.keys,
    };
    _storage.writeJson(_storage.stopLossLockStateFile, {
      for (final id in ids)
        id: {
          'started': _startedIds.contains(id),
          if (_lockedUsdByBotId[id] != null) 'lockedUsd': _lockedUsdByBotId[id],
          if (_owedByBotId[id] != null) 'owed': _owedByBotId[id],
          if (_topUpAtByBotId[id] != null)
            'topUpAt': _topUpAtByBotId[id]!.toIso8601String(),
        },
    });
  }

  DateTime? lastTopUpAt(String buOrderId) => _topUpAtByBotId[buOrderId];

  /// SL was cleared on Pionex for a top-up: the old lock is gone, and the
  /// pause before a fresh lock restarts from [at].
  void markSlClearedForTopUp(String buOrderId, DateTime at) {
    _lockedUsdByBotId.remove(buOrderId);
    _topUpAtByBotId[buOrderId] = at;
    _persist();
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
        (_owedByBotId.remove(buOrderId) != null) |
        (_topUpAtByBotId.remove(buOrderId) != null);
    if (removed) _persist();
  }
}
