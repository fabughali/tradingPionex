import '../../core/core_storage.dart';
import '../models/auto_category.dart';

/// The category (1m/1H/1D) the user has chosen, per pair, via the "knob"
/// next to each Next Trade row (Dashboard/Controls) and the Controls Check
/// card (per the user, 2026-09-07) - consulted whenever a real open happens
/// outside one of the 3 category schedulers' own bases list (Checkup's own
/// sweep, and Start). Defaults to 1H (the pre-existing behavior) for any
/// pair the user has never touched the knob for.
class PairCategoryStore {
  PairCategoryStore(this._storage) {
    load();
  }

  final CoreStorage _storage;
  final Map<String, String> _wireBySymbol = {};

  Map<String, String> load() {
    final raw =
        _storage.readJsonObject(_storage.pairCategoriesFile) ?? const {};
    _wireBySymbol.clear();
    raw.forEach((symbol, value) {
      if (value is String) _wireBySymbol[symbol.toUpperCase()] = value;
    });
    return _wireBySymbol;
  }

  /// Reloads from disk on every call - this store is written by the GUI
  /// process (the per-pair "knob") and read by the long-lived engine
  /// process, so the engine's in-memory copy must never go stale for the
  /// life of the process. The file is tiny and this is only ever called at
  /// pairAction/checkup time, never on a hot per-tick path.
  AutoCategory categoryOf(String symbol) {
    load();
    return autoCategoryFromWire(_wireBySymbol[symbol.toUpperCase()]) ??
        AutoCategory.oneHour;
  }

  void setCategory(String symbol, AutoCategory category) {
    _wireBySymbol[symbol.toUpperCase()] = category.wireValue;
    _storage.writeJson(_storage.pairCategoriesFile, _wireBySymbol);
  }
}
