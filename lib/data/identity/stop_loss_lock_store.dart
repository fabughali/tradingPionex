import '../../core/core_storage.dart';
import '../models/auto_category.dart';

/// Which pairs/bots are governed by the "Stop Loss Lock" engine (2026-09-22,
/// per the user's exact spec) instead of the normal TP/SL ratchet - tagging
/// a pair here disables the ratchet ladder AND the flat -50% baseline SL
/// entirely for it (2026-09-23 revision, per the user: "stop loss lock once
/// it is taged to pair, it should disable regualr -50% rules") - see
/// `EngineService._checkTpSlRatchet`/`._checkStopLossLock`.
///
/// Two tagging shapes, same as the "Last" tag's own composite-key precedent
/// ([RetiredStore]) plus a manual-only extension:
/// - Auto bots: composite "BASE|CATEGORY_WIRE" - persists across recycles,
///   exactly like a Last retirement, since the user tags the standing
///   (base, category) policy, not one specific bot instance.
/// - Manual bots: "MANUAL|`buOrderId`" - manual bots have no inherent
///   category, so the chart timeframe to check RSI/HH-LL on is chosen
///   explicitly at tag time and stored alongside the tag itself.
///
/// Persisted to logs/stop-loss-lock-tags.json as a JSON object keyed by the
/// tag key, value `{"category": "ONE_HOUR"}` in both cases - kept explicit
/// even for auto entries (rather than re-deriving from the key) so every
/// consumer reads the timeframe to check the same simple way regardless of
/// which kind of tag it is.
///
/// CRITICAL bug fixed 2026-09-23, live (per the user: "all current running
/// auto bots are tagged with sll but still the st -50% is active????"):
/// this used to `load()` ONCE in the constructor and cache the result in
/// `_categoryByKey` forever, with every read method (`isTaggedAuto`,
/// `manualCategory`, ...) consulting only that stale in-memory map - since
/// the GUI process and the engine process are separate OS processes
/// communicating only through this file, an engine that had already been
/// running when the GUI wrote a new tag would NEVER see it without a full
/// restart, silently leaving the normal -50% baseline SL active on a
/// genuinely-tagged pair (confirmed live: 8 tagged pairs, zero effect).
/// Every read method now re-reads the file fresh on every call, the same
/// established cross-process-safe pattern [RetiredStore] already uses for
/// the analogous "Last" tag (written by the GUI, read by the engine) -
/// [_lastGood] is kept only as a fallback for a transient read/parse
/// failure, so a corrupt read is never silently treated as "nothing is
/// tagged" (which would just as dangerously restore -50% on a bot the user
/// deliberately tagged).
class StopLossLockStore {
  StopLossLockStore(this._storage);

  final CoreStorage _storage;
  Map<String, AutoCategory>? _lastGood;

  static String _autoKey(String base, AutoCategory category) =>
      '${base.trim().toUpperCase()}|${category.wireValue}';
  static String _manualKey(String buOrderId) => 'MANUAL|$buOrderId';

  Map<String, AutoCategory> _readRaw() {
    Map<String, dynamic>? raw;
    try {
      raw = _storage.readJsonObject(_storage.stopLossLockTagsFile);
    } catch (e) {
      // ignore: avoid_print
      print(
        '[CRITICAL] stop-loss-lock-tags.json exists but failed to parse '
        '($e) - keeping the last known-good tag set instead of treating '
        'this as "nothing is tagged".',
      );
      return _lastGood ?? {};
    }
    final parsed = <String, AutoCategory>{};
    (raw ?? const {}).forEach((key, value) {
      if (value is! Map) return;
      final category = autoCategoryFromWire(value['category'] as String?);
      if (category != null) parsed[key] = category;
    });
    _lastGood = parsed;
    return parsed;
  }

  void _writeRaw(Map<String, AutoCategory> categoryByKey) {
    final out = <String, dynamic>{
      for (final entry in categoryByKey.entries)
        entry.key: {'category': entry.value.wireValue},
    };
    _storage.writeJson(_storage.stopLossLockTagsFile, out);
    _lastGood = categoryByKey;
  }

  bool isTaggedAuto(String base, AutoCategory category) =>
      _readRaw().containsKey(_autoKey(base, category));

  void tagAuto(String base, AutoCategory category) {
    final map = _readRaw();
    final key = _autoKey(base, category);
    if (map[key] == category) return;
    map[key] = category;
    _writeRaw(map);
  }

  void untagAuto(String base, AutoCategory category) {
    final map = _readRaw();
    if (map.remove(_autoKey(base, category)) != null) _writeRaw(map);
  }

  AutoCategory? manualCategory(String buOrderId) =>
      _readRaw()[_manualKey(buOrderId)];

  void tagManual(String buOrderId, AutoCategory category) {
    final map = _readRaw();
    final key = _manualKey(buOrderId);
    if (map[key] == category) return;
    map[key] = category;
    _writeRaw(map);
  }

  void untagManual(String buOrderId) {
    final map = _readRaw();
    if (map.remove(_manualKey(buOrderId)) != null) _writeRaw(map);
  }

  /// Every auto (base, category) tag currently set.
  List<({String base, AutoCategory category})> autoEntries() => [
    for (final entry in _readRaw().entries)
      if (!entry.key.startsWith('MANUAL|'))
        (base: entry.key.split('|').first, category: entry.value),
  ];

  /// Every manual buOrderId tag currently set, with its chosen timeframe.
  List<({String buOrderId, AutoCategory category})> manualEntries() => [
    for (final entry in _readRaw().entries)
      if (entry.key.startsWith('MANUAL|'))
        (buOrderId: entry.key.substring('MANUAL|'.length), category: entry.value),
  ];
}
