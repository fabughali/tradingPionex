import '../../core/core_storage.dart';
import '../models/auto_category.dart';

/// Which [AutoCategory] a given app-initiated bot belongs to (buOrderId ->
/// category) - Pionex has no such concept, this is purely the app's own
/// record, stamped the moment a bot is opened under a category or an
/// existing manual bot is converted into one. Drives the "(1H)"/"(1m)"/
/// "(1D)" tag shown after a pair name wherever an auto bot appears.
/// Persisted to logs/bot-categories.json, same load/parse-safety pattern as
/// [CreatedBotsStore]/[WidenAppliedStore].
class BotCategoryStore {
  BotCategoryStore(this._storage) {
    load();
  }

  final CoreStorage _storage;
  final Map<String, String> _wireByBotId = {};

  Map<String, String> load() {
    final raw = _storage.readJsonObject(_storage.botCategoriesFile) ?? const {};
    _wireByBotId.clear();
    raw.forEach((id, value) {
      if (value is String) _wireByBotId[id] = value;
    });
    return _wireByBotId;
  }

  void _persist() =>
      _storage.writeJson(_storage.botCategoriesFile, _wireByBotId);

  /// Reloads from disk on every call - the engine process is this store's
  /// only writer, while the GUI process only ever reads it for display (the
  /// "(1m)/(1H)/(1D)" tag), so the GUI's in-memory copy must never go stale.
  /// Cheap: this file is tiny and only read at table-render time.
  AutoCategory? categoryOf(String? buOrderId) {
    if (buOrderId == null) return null;
    load();
    return autoCategoryFromWire(_wireByBotId[buOrderId]);
  }

  void setCategory(String buOrderId, AutoCategory category) {
    _wireByBotId[buOrderId] = category.wireValue;
    _persist();
  }

  void forget(String buOrderId) {
    if (_wireByBotId.remove(buOrderId) != null) _persist();
  }
}
