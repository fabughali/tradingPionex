import '../../core/core_storage.dart';

/// Per-buOrderId state for Stop Loss Lock (rewritten 2026-11-09, per the
/// user - see `sll_rules.dart`). Persisted so an engine restart never
/// re-clears an SL that SLL already locked, and never loosens a lock.
///
/// - [cleared]: TP and SL were blanked once for this bot (a trade starts
///   with both blank).
/// - [lockedUsd]: the profit (USDT) SL is locked at - only ever goes up.
/// - [sentRatio]: the `profit_ratio` last sent to Pionex for that lock
///   (lockedUsd / actual investment) - resent when the investment changes.
class StopLossLockStateStore {
  StopLossLockStateStore(this._storage) {
    load();
  }

  final CoreStorage _storage;
  final Set<String> _clearedIds = {};
  final Map<String, double> _lockedUsdByBotId = {};
  final Map<String, double> _sentRatioByBotId = {};

  void load() {
    final raw = _storage.readJsonObject(_storage.stopLossLockStateFile) ?? const {};
    _clearedIds.clear();
    _lockedUsdByBotId.clear();
    _sentRatioByBotId.clear();
    raw.forEach((id, value) {
      if (value is! Map) return;
      if (value['cleared'] == true) _clearedIds.add(id);
      final usd = value['lockedUsd'];
      if (usd is num) _lockedUsdByBotId[id] = usd.toDouble();
      final ratio = value['sentRatio'];
      if (ratio is num) _sentRatioByBotId[id] = ratio.toDouble();
    });
  }

  void _persist() {
    final ids = {..._clearedIds, ..._lockedUsdByBotId.keys};
    _storage.writeJson(_storage.stopLossLockStateFile, {
      for (final id in ids)
        id: {
          'cleared': _clearedIds.contains(id),
          if (_lockedUsdByBotId[id] != null) 'lockedUsd': _lockedUsdByBotId[id],
          if (_sentRatioByBotId[id] != null) 'sentRatio': _sentRatioByBotId[id],
        },
    });
  }

  bool cleared(String buOrderId) => _clearedIds.contains(buOrderId);

  void markCleared(String buOrderId) {
    if (_clearedIds.add(buOrderId)) _persist();
  }

  double? lockedUsd(String buOrderId) => _lockedUsdByBotId[buOrderId];

  double? sentRatio(String buOrderId) => _sentRatioByBotId[buOrderId];

  /// Never lowers an existing lock.
  void recordLock(String buOrderId, double usd, double ratio) {
    final current = _lockedUsdByBotId[buOrderId];
    if (current == null || usd > current) _lockedUsdByBotId[buOrderId] = usd;
    _sentRatioByBotId[buOrderId] = ratio;
    _persist();
  }

  void forget(String buOrderId) {
    final removed =
        _clearedIds.remove(buOrderId) |
        (_lockedUsdByBotId.remove(buOrderId) != null) |
        (_sentRatioByBotId.remove(buOrderId) != null);
    if (removed) _persist();
  }
}
