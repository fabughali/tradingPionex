import '../../core/core_storage.dart';

/// Per-bot state for the automatic TP/SL ratchet applied to auto
/// (app-initiated) bots: a fixed take-profit at the grid's own top/bottom
/// edge, plus a stop-loss that only ever tightens as floating P&L climbs
/// through fixed milestones - never loosens back down if P&L later
/// retraces (confirmed with the user). [highestThreshold]/[recordThreshold]
/// are unit-agnostic ints - originally percentage-of-investment rungs,
/// now dollar rungs under the Worm10-era dollar ladder (2026-10-25, per
/// the user's "and remove any old technique from code and from prd" -
/// see `tp_sl_ladder.dart`'s `highestDollarThresholdCrossed`). Keyed by
/// buOrderId so a recycled bot (which gets a brand-new buOrderId on
/// reopen) naturally starts over at the baseline instead of inheriting a
/// stale ratchet level from its predecessor. Persisted to
/// logs/tpsl-ratchet.json, same load/parse-safety pattern as
/// [BotCategoryStore].
class TpSlRatchetStore {
  TpSlRatchetStore(this._storage) {
    load();
  }

  final CoreStorage _storage;
  final Map<String, int> _highestThresholdByBotId = {};
  final Set<String> _baselineAppliedIds = {};

  /// When the baseline was applied for each bot (2026-09-18, per the user:
  /// the ratchet ladder itself — rule 2 onward — must not start escalating
  /// until N of the bot's own category candles have elapsed since it was
  /// opened, even though the baseline TP/SL — rule 1 — is instant). This is
  /// that clock's zero point.
  final Map<String, DateTime> _baselineAppliedAtByBotId = {};

  void load() {
    final raw =
        _storage.readJsonObject(_storage.tpSlRatchetFile) ?? const {};
    _highestThresholdByBotId.clear();
    _baselineAppliedIds.clear();
    _baselineAppliedAtByBotId.clear();
    raw.forEach((id, value) {
      if (value is! Map) return;
      final threshold = value['highestThreshold'];
      if (threshold is int) _highestThresholdByBotId[id] = threshold;
      if (value['baselineApplied'] == true) _baselineAppliedIds.add(id);
      final appliedAt = value['baselineAppliedAt'];
      if (appliedAt is String) {
        final parsed = DateTime.tryParse(appliedAt);
        if (parsed != null) _baselineAppliedAtByBotId[id] = parsed;
      }
    });
  }

  void _persist() {
    final out = <String, dynamic>{};
    final ids = {..._highestThresholdByBotId.keys, ..._baselineAppliedIds};
    for (final id in ids) {
      out[id] = {
        'highestThreshold': _highestThresholdByBotId[id] ?? 0,
        'baselineApplied': _baselineAppliedIds.contains(id),
        if (_baselineAppliedAtByBotId[id] != null)
          'baselineAppliedAt': _baselineAppliedAtByBotId[id]!.toIso8601String(),
      };
    }
    _storage.writeJson(_storage.tpSlRatchetFile, out);
  }

  bool baselineApplied(String buOrderId) =>
      _baselineAppliedIds.contains(buOrderId);

  DateTime? baselineAppliedAt(String buOrderId) =>
      _baselineAppliedAtByBotId[buOrderId];

  int highestThreshold(String buOrderId) =>
      _highestThresholdByBotId[buOrderId] ?? 0;

  /// [openedAt] seeds the ratchet-ladder grace-period clock — pass the
  /// bot's REAL open time (Pionex's own `createTime`, via `GridBot
  /// .startTime`) when applying the baseline retroactively to an
  /// already-running bot, so a bot that's already been open for hours
  /// doesn't get an extra fresh grace period just because this feature only
  /// just noticed it. Defaults to now, which is already correct for a
  /// brand-new bot applied at the moment of its own creation.
  void markBaselineApplied(String buOrderId, {DateTime? openedAt}) {
    final isNew = _baselineAppliedIds.add(buOrderId);
    _baselineAppliedAtByBotId.putIfAbsent(
      buOrderId,
      () => openedAt ?? DateTime.now(),
    );
    if (isNew) _persist();
  }

  /// No-op if [threshold] isn't strictly higher than what's already
  /// recorded — the ratchet only ever tightens, per the user.
  void recordThreshold(String buOrderId, int threshold) {
    if ((_highestThresholdByBotId[buOrderId] ?? 0) >= threshold) return;
    _highestThresholdByBotId[buOrderId] = threshold;
    _persist();
  }

  /// Called once a bot is no longer running (closed/recycled away) so this
  /// file doesn't accumulate dead buOrderIds forever.
  void forget(String buOrderId) {
    final removedThreshold = _highestThresholdByBotId.remove(buOrderId) != null;
    final removedBaseline = _baselineAppliedIds.remove(buOrderId);
    _baselineAppliedAtByBotId.remove(buOrderId);
    if (removedThreshold || removedBaseline) _persist();
  }
}
