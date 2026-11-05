import '../../core/core_storage.dart';

/// Append-only decision/trade/lesson memory that survives restarts and
/// (per the original design intent) survives swapping which model/agent is
/// operating the app — ported 1:1 from lib/brain.js. Never deletes history,
/// only appends.
class BrainStore {
  BrainStore(this._storage);

  final CoreStorage _storage;

  Map<String, dynamic> recordDecision(Map<String, dynamic> decision) {
    final entry = {'ts': DateTime.now().toIso8601String(), ...decision};
    _storage.appendJsonl(_storage.decisionsFile, entry);
    return entry;
  }

  Map<String, dynamic> recordTrade(Map<String, dynamic> trade) {
    final entry = {'ts': DateTime.now().toIso8601String(), ...trade};
    _storage.appendJsonl(_storage.tradesFile, entry);
    return entry;
  }

  String appendExperience(String lesson) {
    final line = '- [${DateTime.now().toIso8601String()}] $lesson\n';
    _storage.appendString(_storage.experienceFile, line);
    return line;
  }

  String getExperience() => _storage.readString(_storage.experienceFile) ?? '';

  List<Map<String, dynamic>> getRecentDecisions({int limit = 20}) {
    final all = _storage.readJsonl(_storage.decisionsFile);
    return all.length > limit ? all.sublist(all.length - limit) : all;
  }

  List<Map<String, dynamic>> getRecentTrades({int limit = 20}) {
    final all = _storage.readJsonl(_storage.tradesFile);
    return all.length > limit ? all.sublist(all.length - limit) : all;
  }

  String getBrainIndex() => _storage.readString(_storage.brainIndexFile) ?? '';

  void writeTechnique(String markdown) =>
      _storage.writeString(_storage.techniqueFile, markdown);

  String getTechnique() => _storage.readString(_storage.techniqueFile) ?? '';

  Map<String, dynamic> summarizeState() => {
    'brain': _truncate(getBrainIndex(), 400),
    'lessons': _truncate(getExperience(), 600),
    'recentDecisions': getRecentDecisions(limit: 5),
    'recentTrades': getRecentTrades(limit: 5),
  };

  String _truncate(String s, int max) =>
      s.length > max ? s.substring(0, max) : s;
}
