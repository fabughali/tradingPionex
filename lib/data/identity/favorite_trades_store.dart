import '../../core/core_storage.dart';

/// Favorite trades (2026-11-11, per the user): while Power and Auto are on
/// and at least $10 is free for new trades, the engine opens up to 5
/// favorite trades per UTC day - 3 shorts from the filled-star list
/// (biggest 24h % rise in the last hour, opened on HH + RSI yellow +
/// Supertrend buy) and 2 longs from the empty-star list (biggest drop,
/// opened on LL + RSI blue + Supertrend sell). $10 each, marked Last right
/// away. After a trade is opened the next check is 2 hours later; a check
/// that finds nothing tries again at the next 1H candle close. Unused
/// trades do not carry over to the next day.
const int favoriteShortsPerDay = 3;
const int favoriteLongsPerDay = 2;
const double favoriteInvestmentUsdt = 10;
const int favoriteListDepth = 10;
const Duration favoriteSpacing = Duration(hours: 2);

/// The UTC day key, e.g. `2026-11-11`.
String utcDayKey(DateTime t) {
  final u = t.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year}-${two(u.month)}-${two(u.day)}';
}

/// A minute after the next 1H candle closes (UTC hour boundary).
DateTime nextCandleCheck(DateTime now) {
  final u = now.toUtc();
  final hour = DateTime.utc(u.year, u.month, u.day, u.hour);
  return hour.add(const Duration(hours: 1, minutes: 1));
}

/// Candidates for one check: up to [depth] symbols from each list that still
/// has quota, alternating short / long. [scores] is now - then per Pionex
/// symbol (`AKE_USDT_PERP`); only USDT perps count (COIN-M and coin futures
/// are not tradable). [exclude] holds bases to skip (running, in Auto's
/// list, already a favorite today). Returns app symbols (`AKEUSDT`).
List<({String symbol, bool short})> favoriteCandidates(
  Map<String, double> scores, {
  required bool wantShorts,
  required bool wantLongs,
  Set<String> exclude = const {},
  int depth = favoriteListDepth,
}) {
  final usdt = <String, double>{};
  scores.forEach((sym, score) {
    final m = RegExp(r'^([A-Z0-9]+)_USDT_PERP$').firstMatch(sym);
    if (m == null) return;
    final base = m.group(1)!;
    if (base == 'USDT' || exclude.contains(base)) return;
    usdt['${base}USDT'] = score;
  });
  final byRise = usdt.keys.toList()
    ..sort((a, b) => usdt[b]!.compareTo(usdt[a]!));
  final shorts = wantShorts ? byRise.take(depth).toList() : const <String>[];
  final longs = wantLongs
      ? byRise.reversed.take(depth).toList()
      : const <String>[];
  final out = <({String symbol, bool short})>[];
  final seen = <String>{};
  for (var i = 0; i < depth; i++) {
    if (i < shorts.length && seen.add(shorts[i])) {
      out.add((symbol: shorts[i], short: true));
    }
    if (i < longs.length && seen.add(longs[i])) {
      out.add((symbol: longs[i], short: false));
    }
  }
  return out;
}

/// Today's favorite-trade count and when the next check is due. Saved so a
/// restart keeps the day's count and spacing.
class FavoriteTradesStore {
  FavoriteTradesStore(this._storage) {
    _load();
  }

  final CoreStorage _storage;
  String _day = '';
  int _shorts = 0;
  int _longs = 0;
  DateTime? _nextCheckAt;
  final Set<String> _basesToday = {};

  void _load() {
    try {
      final raw = _storage.readJsonObject(_storage.favoriteTradesFile);
      if (raw == null) return;
      _day = '${raw['day'] ?? ''}';
      _shorts = (raw['shorts'] as num?)?.toInt() ?? 0;
      _longs = (raw['longs'] as num?)?.toInt() ?? 0;
      final next = raw['nextCheckAt'];
      if (next is String) _nextCheckAt = DateTime.tryParse(next);
      for (final b in (raw['bases'] as List?) ?? const []) {
        _basesToday.add('$b');
      }
    } catch (_) {}
  }

  void _persist() {
    _storage.writeJson(_storage.favoriteTradesFile, {
      'day': _day,
      'shorts': _shorts,
      'longs': _longs,
      if (_nextCheckAt != null) 'nextCheckAt': _nextCheckAt!.toIso8601String(),
      'bases': _basesToday.toList(),
    });
  }

  /// Starts a fresh count at each new UTC day.
  void _roll(DateTime now) {
    final today = utcDayKey(now);
    if (_day == today) return;
    _day = today;
    _shorts = 0;
    _longs = 0;
    _basesToday.clear();
    _persist();
  }

  bool canShort(DateTime now) {
    _roll(now);
    return _shorts < favoriteShortsPerDay;
  }

  bool canLong(DateTime now) {
    _roll(now);
    return _longs < favoriteLongsPerDay;
  }

  int openedToday(DateTime now) {
    _roll(now);
    return _shorts + _longs;
  }

  Set<String> basesToday(DateTime now) {
    _roll(now);
    return Set.unmodifiable(_basesToday);
  }

  bool isDue(DateTime now) {
    _roll(now);
    if (!canShort(now) && !canLong(now)) return false;
    return _nextCheckAt == null || !now.isBefore(_nextCheckAt!);
  }

  DateTime? get nextCheckAt => _nextCheckAt;

  void recordOpened(String base, {required bool short, required DateTime now}) {
    _roll(now);
    if (short) {
      _shorts++;
    } else {
      _longs++;
    }
    _basesToday.add(base);
    _nextCheckAt = now.add(favoriteSpacing);
    _persist();
  }

  /// Nothing opened this check - try again at the next 1H candle close.
  void recordNothing(DateTime now) {
    _roll(now);
    _nextCheckAt = nextCandleCheck(now);
    _persist();
  }
}
