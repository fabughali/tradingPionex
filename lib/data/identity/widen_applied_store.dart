import '../../core/core_storage.dart';

/// Remembers which app-opened bots had the 40/60 range-widen adjustment
/// applied at open time - Pionex's own grid data has no such field, so this
/// is purely the app's own record of a decision it made once, at open.
/// Manual bots (never opened by the app) are never in this set - "40/60
/// applied" doesn't apply to them, they always read as neutral.
/// Persisted to logs/widen-applied-bots.json, same shape/pattern as
/// [CreatedBotsStore].
class WidenAppliedStore {
  WidenAppliedStore(this._storage) {
    load();
  }

  final CoreStorage _storage;
  final Set<String> _ids = {};

  Set<String> load() {
    List<dynamic> arr;
    try {
      arr = _storage.readJsonArrayStrict(_storage.widenAppliedBotsFile);
    } catch (e) {
      // ignore: avoid_print
      print(
        '[CRITICAL] widen-applied-bots.json exists but failed to parse ($e) - '
        'keeping the last known-good in-memory set instead of resetting it.',
      );
      return _ids;
    }
    _ids.clear();
    for (final id in arr) {
      if (id != null) _ids.add(id.toString());
    }
    return _ids;
  }

  void _persist() =>
      _storage.writeJson(_storage.widenAppliedBotsFile, _ids.toList());

  bool isWidenApplied(String? buOrderId) =>
      buOrderId != null && _ids.contains(buOrderId);

  bool markWidened(String? buOrderId) {
    if (buOrderId == null) return false;
    _ids.add(buOrderId);
    _persist();
    return true;
  }

  bool forget(String? buOrderId) {
    if (buOrderId == null) return false;
    final removed = _ids.remove(buOrderId);
    if (removed) _persist();
    return removed;
  }
}
