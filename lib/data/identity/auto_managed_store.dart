import '../../core/core_storage.dart';

/// Persistent "the app is currently responsible for this base" store - see
/// [CoreStorage.autoManagedBasesFile] for why this exists separately from
/// created-bots.json/retired-pairs.json. Persisted to
/// logs/auto-managed-bases.json as uppercase BASE names (e.g. "ETH").
class AutoManagedStore {
  /// [filePath] defaults to the original single file (the 1H category, per
  /// the user 2026-09-07) - pass a per-category path (see
  /// `CoreStorage.autoManagedBasesFileFor`) to get an independent store for
  /// the 1m/1D categories.
  AutoManagedStore(this._storage, {String? filePath})
    : _filePath = filePath ?? _storage.autoManagedBasesFile;

  final CoreStorage _storage;
  final String _filePath;

  /// The last successfully-parsed read, kept so a corrupt/unparseable file
  /// doesn't collapse into "nothing is auto-managed" - same reasoning as
  /// RetiredStore's own _lastGood.
  Set<String>? _lastGood;

  Set<String> _readRaw() {
    List<dynamic> arr;
    try {
      arr = _storage.readJsonArrayStrict(_filePath);
    } catch (e) {
      // ignore: avoid_print
      print(
        '[CRITICAL] auto-managed-bases.json exists but failed to parse ($e) '
        '- keeping the last known-good set instead of treating this as '
        '"nothing is auto-managed".',
      );
      return _lastGood ?? {};
    }
    final parsed = arr
        .map((e) => e.toString().toUpperCase())
        .where((e) => e.isNotEmpty)
        .toSet();
    _lastGood = parsed;
    return parsed;
  }

  Set<String> _write(Iterable<String> bases) {
    final clean = bases
        .map((b) => b.toUpperCase())
        .where((b) => b.isNotEmpty)
        .toSet();
    final sorted = clean.toList()..sort();
    _storage.writeJson(_filePath, sorted);
    _lastGood = clean;
    return clean;
  }

  Set<String> loadAutoManagedBases() => _readRaw();

  bool isAutoManaged(String base) =>
      loadAutoManagedBases().contains(base.toUpperCase());

  void addBase(String base) {
    final set = loadAutoManagedBases();
    if (set.add(base.toUpperCase())) _write(set);
  }

  void removeBase(String base) {
    final set = loadAutoManagedBases();
    if (set.remove(base.toUpperCase())) _write(set);
  }

  void removeBases(Iterable<String> bases) {
    final set = loadAutoManagedBases();
    final before = set.length;
    for (final b in bases) {
      set.remove(b.toUpperCase());
    }
    if (set.length != before) _write(set);
  }
}
