import '../../core/core_storage.dart';

/// Which worm_9_26 signal type applied at a single moment - open or close -
/// for one bot instance. [type] is one of 'HH'/'LL'/'BUY'/'SELL' (see
/// `readWormSignals`'s doc). [zone]/[value] are legacy only (2026-09-29):
/// the RSI-zone concept they used to record no longer exists, so they're
/// always null for a moment built from a current signal - kept nullable
/// only so records written before this change still deserialize and
/// display correctly. [at] is TradingView's own bar open time (2026-09-26,
/// per the user: "time stamp for signals should be according to trading
/// view timing not according to my laptop") - NOT the wall-clock moment the
/// engine happened to process it, which can lag the real signal by
/// anywhere from a few seconds to (for a Stop Loss Lock reversal check,
/// which only runs every 3 minutes) several minutes.
class EntrySignalMoment {
  const EntrySignalMoment({
    required this.at,
    required this.type,
    this.zone,
    this.value,
  });

  final DateTime at;
  final String type;
  final String? zone;
  final double? value;

  factory EntrySignalMoment.fromJson(Map<String, dynamic> json) =>
      EntrySignalMoment(
        at: DateTime.tryParse('${json['at']}') ?? DateTime(1970),
        type: '${json['type']}',
        zone: json['zone'] as String?,
        value: (json['value'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toJson() => {
    'at': at.toIso8601String(),
    'type': type,
    if (zone != null) 'zone': zone,
    if (value != null) 'value': value,
  };
}

/// One bot instance's entry-signal record (2026-09-26, per the user: "the
/// record should be one out of those 60 entries" - identifies exactly
/// which of the 60-row table's entries opened it, and, once known, which
/// one closed it).
class EntrySignalRecord {
  const EntrySignalRecord({
    required this.base,
    required this.direction,
    required this.open,
    this.close,
  });

  final String base;

  /// 'long'/'short' - the bot's own trend, same convention as
  /// `GridDirection.wireValue`.
  final String direction;
  final EntrySignalMoment open;

  /// Only ever set for a genuine opposite-signal auto-close - every other
  /// close reason (real Pionex TP/SL, liquidation, manual cancel, the
  /// never-filled safety cancel) isn't signal-driven, so there is no
  /// "stop signal" to record.
  final EntrySignalMoment? close;

  EntrySignalRecord withClose(EntrySignalMoment close) => EntrySignalRecord(
    base: base,
    direction: direction,
    open: open,
    close: close,
  );

  factory EntrySignalRecord.fromJson(Map<String, dynamic> json) =>
      EntrySignalRecord(
        base: '${json['base']}',
        direction: '${json['direction']}',
        open: EntrySignalMoment.fromJson(
          (json['open'] as Map).cast<String, dynamic>(),
        ),
        close: json['close'] == null
            ? null
            : EntrySignalMoment.fromJson(
                (json['close'] as Map).cast<String, dynamic>(),
              ),
      );

  Map<String, dynamic> toJson() => {
    'base': base,
    'direction': direction,
    'open': open.toJson(),
    if (close != null) 'close': close!.toJson(),
  };
}

/// Per-buOrderId entry-signal store, persisted so it survives an engine
/// restart (unlike `_openEntryByPair`, which is in-memory only) - a bot can
/// easily still be running hours or days after the engine that opened it
/// last restarted. Keyed by buOrderId; a recycled bot gets a fresh key
/// (fresh buOrderId), so nothing needs resetting on recycle.
///
/// Lifecycle: [recordOpen] the moment a bot is confirmed created (real
/// signal on hand); [recordClose] the moment a genuine opposite-signal
/// close fires (real signal on hand again); [forget] once the closed
/// record has been copied into the matching `BotHistoryEntry` - this store
/// only ever holds currently-open bots, never a permanent archive (that's
/// `bot-history.jsonl`'s job).
class EntrySignalStore {
  EntrySignalStore(this._storage) {
    load();
  }

  final CoreStorage _storage;
  final Map<String, EntrySignalRecord> _byBotId = {};

  void load() {
    final raw = _storage.readJsonObject(_storage.entrySignalsFile) ?? const {};
    _byBotId.clear();
    raw.forEach((id, value) {
      if (value is! Map) return;
      try {
        _byBotId[id] = EntrySignalRecord.fromJson(value.cast<String, dynamic>());
      } catch (_) {
        // Malformed entry for this one id - skip it, never let one bad
        // record take down the whole store.
      }
    });
  }

  void _persist() {
    final out = <String, dynamic>{
      for (final entry in _byBotId.entries) entry.key: entry.value.toJson(),
    };
    _storage.writeJson(_storage.entrySignalsFile, out);
  }

  EntrySignalRecord? recordFor(String? buOrderId) =>
      buOrderId == null ? null : _byBotId[buOrderId];

  void recordOpen(
    String buOrderId, {
    required String base,
    required String direction,
    required DateTime at,
    required String type,
    String? zone,
    double? value,
  }) {
    _byBotId[buOrderId] = EntrySignalRecord(
      base: base,
      direction: direction,
      open: EntrySignalMoment(at: at, type: type, zone: zone, value: value),
    );
    _persist();
  }

  void recordClose(
    String buOrderId, {
    required DateTime at,
    required String type,
    String? zone,
    double? value,
  }) {
    final existing = _byBotId[buOrderId];
    if (existing == null) return;
    _byBotId[buOrderId] = existing.withClose(
      EntrySignalMoment(at: at, type: type, zone: zone, value: value),
    );
    _persist();
  }

  void forget(String? buOrderId) {
    if (buOrderId == null) return;
    if (_byBotId.remove(buOrderId) != null) _persist();
  }
}
