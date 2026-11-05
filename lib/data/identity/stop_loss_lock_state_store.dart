import '../../core/core_storage.dart';

/// Per-buOrderId state for the "Stop Loss Lock" engine (2026-09-22, per the
/// user's exact spec): the highest profit-floor SL percentage locked in so
/// far for that bot instance. Only ever ratchets up - a later hit only
/// updates the stored value if the newly computed SL is higher than what's
/// already locked, same "never loosens" philosophy as [TpSlRatchetStore].
/// Keyed by buOrderId so a recycled auto bot (new buOrderId on reopen)
/// naturally starts over - a fresh bot begins at 0% P&L anyway, so there is
/// nothing to inherit from its predecessor.
///
/// Extended 2026-09-23, per the user's investment-ratchet rules (once P&L
/// clears +200%: round investment up to the next whole USDT, lock SL to a
/// flat +100%, then keep adding +1 USDT every 9 minutes while P&L stays
/// >=200% and no reversal signal has fired yet): two more persisted fields
/// per bot - [signalFired] (has the genuine yellow/HH or blue/LL reversal
/// signal actually fired for this bot instance - once true, the investment
/// ratchet stops for good) and [lastInvestmentIncreaseAt] (when the last
/// investment increase happened - null means the ratchet hasn't started yet
/// for this bot, which is also what lets the very first round-up fire
/// immediately with no 9-minute wait). Persisted (not in-memory only) so an
/// engine restart mid-ratchet can never accidentally resume adding
/// investment after the signal had already fired, or restart the 9-minute
/// cooldown from scratch.
class StopLossLockStateStore {
  StopLossLockStateStore(this._storage) {
    load();
  }

  final CoreStorage _storage;
  final Map<String, double> _lockedSlPercentByBotId = {};
  final Set<String> _signalFiredIds = {};
  final Map<String, DateTime> _lastInvestmentIncreaseAtByBotId = {};

  void load() {
    final raw = _storage.readJsonObject(_storage.stopLossLockStateFile) ?? const {};
    _lockedSlPercentByBotId.clear();
    _signalFiredIds.clear();
    _lastInvestmentIncreaseAtByBotId.clear();
    raw.forEach((id, value) {
      if (value is! Map) return;
      final locked = value['lockedSlPercent'];
      if (locked is num) _lockedSlPercentByBotId[id] = locked.toDouble();
      if (value['signalFired'] == true) _signalFiredIds.add(id);
      final lastIncrease = value['lastInvestmentIncreaseAt'];
      if (lastIncrease is String) {
        final parsed = DateTime.tryParse(lastIncrease);
        if (parsed != null) _lastInvestmentIncreaseAtByBotId[id] = parsed;
      }
    });
  }

  void _persist() {
    final ids = {
      ..._lockedSlPercentByBotId.keys,
      ..._signalFiredIds,
      ..._lastInvestmentIncreaseAtByBotId.keys,
    };
    final out = <String, dynamic>{
      for (final id in ids)
        id: {
          if (_lockedSlPercentByBotId[id] != null)
            'lockedSlPercent': _lockedSlPercentByBotId[id],
          'signalFired': _signalFiredIds.contains(id),
          if (_lastInvestmentIncreaseAtByBotId[id] != null)
            'lastInvestmentIncreaseAt': _lastInvestmentIncreaseAtByBotId[id]!
                .toIso8601String(),
        },
    };
    _storage.writeJson(_storage.stopLossLockStateFile, out);
  }

  double? lockedSlPercent(String buOrderId) => _lockedSlPercentByBotId[buOrderId];

  /// No-op if [slPercent] isn't strictly higher than what's already locked.
  void recordLock(String buOrderId, double slPercent) {
    final current = _lockedSlPercentByBotId[buOrderId];
    if (current != null && current >= slPercent) return;
    _lockedSlPercentByBotId[buOrderId] = slPercent;
    _persist();
  }

  /// Whether the genuine reversal signal has already fired for this bot
  /// instance - once true, the investment ratchet ([lastInvestmentIncreaseAt]
  /// et al) is done for good for this bot; only the signal-driven SL lock
  /// keeps tightening from here on.
  bool signalFired(String buOrderId) => _signalFiredIds.contains(buOrderId);

  void markSignalFired(String buOrderId) {
    if (_signalFiredIds.add(buOrderId)) _persist();
  }

  DateTime? lastInvestmentIncreaseAt(String buOrderId) =>
      _lastInvestmentIncreaseAtByBotId[buOrderId];

  void recordInvestmentIncrease(String buOrderId) {
    _lastInvestmentIncreaseAtByBotId[buOrderId] = DateTime.now();
    _persist();
  }

  void forget(String buOrderId) {
    final removed =
        _lockedSlPercentByBotId.remove(buOrderId) != null ||
        _signalFiredIds.remove(buOrderId) ||
        _lastInvestmentIncreaseAtByBotId.remove(buOrderId) != null;
    if (removed) _persist();
  }
}
