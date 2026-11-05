import '../../core/core_storage.dart';
import '../models/auto_category.dart';

/// Persistent "never auto-recreate this pair" store — ported 1:1 from
/// lib/retired.js. Backs the /last-equivalent control: the user picks running
/// AUTO grids that should finish their current run and then never be
/// re-created automatically. An explicit selection (the pending-create file)
/// or an explicit unretire can still re-enable a retired pair.
/// Persisted to logs/retired-pairs.json.
///
/// Bug fixed 2026-09-20, live (per the user: "i choose btc 5m and clicked
/// on last button ... but then both btc 5m and btc 1h was triggered last"):
/// this used to store bare base names ("BTC"), so retiring one base under
/// ONE category (5m) silently retired it under every OTHER category too
/// (1H, 15m, 3m, 1D), since every consumer only ever checked
/// `isRetiredBase(base)` with no category at all. Now stores composite
/// "BASE|CATEGORY_WIRE" keys, category-scoped like every other per-base
/// piece of state in this app (auto-managed lists, running grids, etc).
///
/// Every existing bare legacy entry was migrated to explicit per-category
/// composite keys the moment this fix shipped (2026-09-20) - see the
/// one-time data migration in the same commit. `isRetiredBase` still
/// tolerates a bare key on read (belt-and-suspenders, matches a base
/// that's genuinely retired under every category), but removal is
/// strictly scoped to the exact (base, category) pair requested - per the
/// user ("i dont want you to invent something new.. if user toggle
/// something to a pair... then only this pair take an action" / "no same
/// pair with different interval"), unretiring one interval must NEVER
/// touch another interval of the same base. A bare key is only ever
/// produced by hand-editing the file now; the app itself never writes one.
class RetiredStore {
  RetiredStore(this._storage);

  final CoreStorage _storage;

  /// The last successfully-parsed read, kept so a corrupt/unparseable file
  /// doesn't collapse into "nothing is retired" - a pair the operator
  /// explicitly retired (finish naturally, never auto-recreate) would
  /// otherwise become eligible for auto-trading again on the very next
  /// cycle, silently undoing an explicit safety decision. Null only before
  /// the first-ever successful read.
  Set<String>? _lastGood;

  static String _key(String base, AutoCategory category) =>
      '${base.trim().toUpperCase()}|${category.wireValue}';

  Set<String> _readRaw() {
    List<dynamic> arr;
    try {
      arr = _storage.readJsonArrayStrict(_storage.retiredPairsFile);
    } catch (e) {
      // ignore: avoid_print
      print(
        '[CRITICAL] retired-pairs.json exists but failed to parse ($e) - '
        'keeping the last known-good retired set instead of treating this '
        'as "nothing is retired".',
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

  Set<String> _writeRaw(Iterable<String> keys) {
    final clean = keys
        .map((k) => k.toUpperCase())
        .where((k) => k.isNotEmpty)
        .toSet();
    final sorted = clean.toList()..sort();
    _storage.writeJson(_storage.retiredPairsFile, sorted);
    _lastGood = clean;
    return clean;
  }

  /// Raw stored keys (composite "BASE|CATEGORY", or a legacy bare "BASE").
  /// Mostly for internal use and for the handful of call sites that still
  /// need "is this base retired under ANY category" (e.g. the GUI's Last
  /// tag, which currently has no per-category display).
  Set<String> loadRetiredBases() => _readRaw();

  bool isRetiredBase(String base, AutoCategory category) {
    final raw = loadRetiredBases();
    final bare = base.trim().toUpperCase();
    return raw.contains(_key(bare, category)) || raw.contains(bare);
  }

  /// True if [base] is retired under any category at all - legacy-style,
  /// used only where no specific category is available (the GUI's Last
  /// tag/toggle, which isn't category-scoped in the UI yet).
  bool isRetiredBaseAnyCategory(String base) {
    final bare = base.trim().toUpperCase();
    return loadRetiredBases().any(
      (k) => k == bare || k.startsWith('$bare|'),
    );
  }

  Set<String> addRetiredBases(
    Iterable<({String base, AutoCategory category})> pairs,
  ) {
    final set = loadRetiredBases();
    set.addAll(pairs.map((p) => _key(p.base, p.category)));
    return _writeRaw(set);
  }

  /// Removes ONLY the exact (base, category) retirement - never touches
  /// any other category's key for the same base, and never touches a
  /// bare legacy key (there shouldn't be any left; see the class doc).
  Set<String> removeRetiredBases(
    Iterable<({String base, AutoCategory category})> pairs,
  ) {
    final set = loadRetiredBases();
    for (final p in pairs) {
      set.remove(_key(p.base, p.category));
    }
    return _writeRaw(set);
  }
}
