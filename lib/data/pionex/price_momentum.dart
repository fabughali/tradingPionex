/// The Next Trade table's star ("Favorite") sort (2026-11-09, per the user):
/// every Pionex pair's 24h % is recorded every 5 seconds while Power is on;
/// each pair shows its 24h % one hour ago and now, ranked by now - then.
class PriceMomentum {
  PriceMomentum({this.window = const Duration(hours: 1)});

  final Duration window;

  /// (time, price by Pionex symbol), oldest first.
  final List<({DateTime at, Map<String, double> prices})> _snaps = [];

  bool get isEmpty => _snaps.isEmpty;

  void add(DateTime at, Map<String, double> prices) {
    if (prices.isEmpty) return;
    _snaps.add((at: at, prices: Map.unmodifiable(prices)));
    final cutoff = at.subtract(window);
    _snaps.removeWhere((s) => s.at.isBefore(cutoff));
  }

  /// Per symbol: its oldest value in the window ([then], about one hour
  /// ago) and its latest ([now]); ranked by now - then.
  Map<String, ({double then, double now})> readings() {
    if (_snaps.length < 2) return const {};
    final latest = <String, double>{};
    final oldest = <String, double>{};
    for (final s in _snaps) {
      s.prices.forEach((sym, v) {
        oldest.putIfAbsent(sym, () => v);
        latest[sym] = v;
      });
    }
    return {
      for (final e in latest.entries)
        if (oldest[e.key] != null) e.key: (then: oldest[e.key]!, now: e.value),
    };
  }

  /// How far back the scores reach right now (under an hour while warming
  /// up, or after a Power-off gap).
  Duration get span =>
      _snaps.length < 2 ? Duration.zero : _snaps.last.at.difference(_snaps.first.at);

  /// Saved with one snapshot per minute (enough for a 1-hour % change, and
  /// small on disk).
  Map<String, dynamic> toJson() {
    final kept = <({DateTime at, Map<String, double> prices})>[];
    for (final s in _snaps) {
      if (kept.isEmpty ||
          s.at.difference(kept.last.at) >= const Duration(minutes: 1) ||
          identical(s, _snaps.last)) {
        kept.add(s);
      }
    }
    return {
      'snaps': [
        for (final s in kept)
          {'at': s.at.millisecondsSinceEpoch, 'prices': s.prices},
      ],
    };
  }

  /// Restores saved snapshots, dropping any older than [window] before [now].
  void loadJson(Map<String, dynamic>? json, DateTime now) {
    _snaps.clear();
    final cutoff = now.subtract(window);
    for (final raw in (json?['snaps'] as List?) ?? const []) {
      if (raw is! Map) continue;
      final at = DateTime.fromMillisecondsSinceEpoch(
        (raw['at'] as num?)?.toInt() ?? 0,
      );
      if (at.isBefore(cutoff)) continue;
      final prices = <String, double>{};
      (raw['prices'] as Map?)?.forEach((k, v) {
        if (v is num) prices['$k'] = v.toDouble();
      });
      if (prices.isNotEmpty) _snaps.add((at: at, prices: prices));
    }
  }
}
