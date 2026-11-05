import '../../core/core_storage.dart';

/// USER RULES (PRD §10):
///  1. The human may manually edit or stop ANY bot the app initiated.
///  2. The app may NEVER modify (stop/close/edit) a bot that was initiated
///     manually — only bots on this list are considered "app-initiated".
///  3. The app may open a new trade on a pair even if a MANUAL bot is
///     already running there (a manual bot never blocks a new app grid).
///
/// Persisted to logs/created-bots.json — ported 1:1 from lib/created-bots.js.
/// Every buOrderId the app itself creates is remembered here so a running
/// bot can be told apart from a manually-created one across restarts.
class CreatedBotsStore {
  CreatedBotsStore(this._storage) {
    load();
  }

  final CoreStorage _storage;
  final Set<String> _ids = {};

  /// Reads `created-bots.json`. On a corrupt/unparseable file (as opposed to
  /// one that simply doesn't exist yet), deliberately KEEPS whatever `_ids`
  /// already holds in memory rather than resetting to empty - treating
  /// corruption as "nothing is app-initiated" would make `isAppInitiated`
  /// return false for every real running app bot, which lets the engine's
  /// main loop fall through its "grid already running" guard and open a
  /// second real grid on an already-live pair. Logged to stderr (visible in
  /// the process log even without going through AppLogger) so this never
  /// fails silently.
  Set<String> load() {
    List<dynamic> arr;
    try {
      arr = _storage.readJsonArrayStrict(_storage.createdBotsFile);
    } catch (e) {
      // ignore: avoid_print
      print(
        '[CRITICAL] created-bots.json exists but failed to parse ($e) - '
        'keeping the last known-good in-memory app-initiated set instead of '
        'treating this as "nothing is app-initiated".',
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
      _storage.writeJson(_storage.createdBotsFile, _ids.toList());

  bool isAppInitiated(String? buOrderId) =>
      buOrderId != null && _ids.contains(buOrderId);

  bool rememberBot(String? buOrderId) {
    if (buOrderId == null) return false;
    _ids.add(buOrderId);
    _persist();
    return true;
  }

  bool forgetBot(String? buOrderId) {
    if (buOrderId == null) return false;
    final removed = _ids.remove(buOrderId);
    if (removed) _persist();
    return removed;
  }

  List<String> listAppBots() => _ids.toList();
}
