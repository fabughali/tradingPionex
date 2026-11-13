import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// TradingView sync between TradingPionex and tradingMT5 (2026-11-13, per
/// the user: "a sync tool where this app communicates with tradingmt5 so
/// they are synchronised for tradingview" - tradingMT5 builds the same side).
/// Both apps share ONE TradingView Desktop (one chart tab each). They talk
/// through plain files in one shared folder, `%USERPROFILE%\.tvsync\`:
///
/// - `<app>.heartbeat.json` - written by each app's engine every 5 s:
///   `{"app","pid","version","at" (epoch ms),"power","tab","busy","tvHealthy"}`
///   (`tab` is "claimed" | "missing" | "unknown"). Older than [peerStaleAfter]
///   = that app is offline.
/// - `tv.lock` - taken before a big TradingView action (restart TradingView,
///   reload or open a tab): `{"app","action","at","expiresAt"}` (epoch ms).
///   Created exclusively; an expired lock may be replaced. The other app waits
///   instead of acting while it is held - and pauses chart reads while it is
///   held for "restart_tradingview".
/// - `requests\<id>.json` - a request for the other app:
///   `{"id","from","to","type","reason","at"}`. The receiver deletes it once
///   handled. Types: "restart_tradingview" (only tradingMT5 restarts
///   TradingView - TradingPionex never does).
///
/// Every write goes to a temp file first and is renamed into place, so a
/// reader never sees half a file.
class TvSync {
  TvSync({required this.app, String? dir, DateTime Function()? clock})
    : dir = dir ?? defaultDir(),
      _now = clock ?? DateTime.now;

  final String app;
  final String dir;
  final DateTime Function() _now;

  static const String pionex = 'tradingpionex';
  static const String mt5 = 'tradingmt5';
  static const Duration peerStaleAfter = Duration(seconds: 20);
  static const Duration lockTtl = Duration(minutes: 2);

  static String defaultDir() {
    final home =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
    return '$home${Platform.pathSeparator}.tvsync';
  }

  String _path(String name) => '$dir${Platform.pathSeparator}$name';
  String get _lockPath => _path('tv.lock');
  String get _requestsDir => _path('requests');

  void _ensureDirs() {
    Directory(dir).createSync(recursive: true);
    Directory(_requestsDir).createSync(recursive: true);
  }

  void _writeAtomic(String path, Map<String, dynamic> json) {
    _ensureDirs();
    final tmp = File('$path.${pid}_${Random().nextInt(1 << 30)}.tmp');
    tmp.writeAsStringSync(jsonEncode(json), flush: true);
    tmp.renameSync(path);
  }

  Map<String, dynamic>? _read(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return null;
      final v = jsonDecode(f.readAsStringSync());
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  // --- heartbeat -----------------------------------------------------------

  void writeHeartbeat({
    required bool power,
    required String tab,
    required bool busy,
    required bool tvHealthy,
    String version = '',
  }) {
    _writeAtomic(_path('$app.heartbeat.json'), {
      'app': app,
      'pid': pid,
      'version': version,
      'at': _now().millisecondsSinceEpoch,
      'power': power,
      'tab': tab,
      'busy': busy,
      'tvHealthy': tvHealthy,
    });
  }

  /// The other app's latest heartbeat, or null if it has none or it is
  /// older than [peerStaleAfter] (offline).
  PeerStatus? peer(String otherApp) {
    final j = _read(_path('$otherApp.heartbeat.json'));
    if (j == null) return null;
    final at = DateTime.fromMillisecondsSinceEpoch((j['at'] as num?)?.toInt() ?? 0);
    if (_now().difference(at) > peerStaleAfter) return null;
    return PeerStatus(
      app: otherApp,
      at: at,
      power: j['power'] == true,
      tab: '${j['tab'] ?? 'unknown'}',
      busy: j['busy'] == true,
      tvHealthy: j['tvHealthy'] == true,
      version: '${j['version'] ?? ''}',
    );
  }

  // --- lock ------------------------------------------------------------------

  /// The current lock holder, or null if there is none (or it expired).
  LockInfo? lockHolder() {
    final j = _read(_lockPath);
    if (j == null) return null;
    final expires = DateTime.fromMillisecondsSinceEpoch(
      (j['expiresAt'] as num?)?.toInt() ?? 0,
    );
    if (!_now().isBefore(expires)) return null;
    return LockInfo(app: '${j['app']}', action: '${j['action']}', expiresAt: expires);
  }

  /// Takes the TradingView lock for [action]; false if the other app holds
  /// it. Re-taking our own lock refreshes it.
  bool tryLock(String action, {Duration ttl = lockTtl}) {
    _ensureDirs();
    final holder = lockHolder();
    if (holder != null && holder.app != app) return false;
    final now = _now();
    final body = jsonEncode({
      'app': app,
      'action': action,
      'at': now.millisecondsSinceEpoch,
      'expiresAt': now.add(ttl).millisecondsSinceEpoch,
    });
    final file = File(_lockPath);
    if (holder != null || file.existsSync()) {
      // Ours, or expired: replace it.
      try {
        file.deleteSync();
      } catch (_) {}
    }
    try {
      file.createSync(exclusive: true);
      file.writeAsStringSync(body, flush: true);
      return true;
    } on FileSystemException {
      // The other app created it in between.
      final now2 = lockHolder();
      return now2 != null && now2.app == app;
    }
  }

  /// Releases the lock if this app holds it.
  void releaseLock() {
    final j = _read(_lockPath);
    if (j != null && j['app'] == app) {
      try {
        File(_lockPath).deleteSync();
      } catch (_) {}
    }
  }

  /// True while the other app holds the lock to restart TradingView - chart
  /// reads should pause until it is released.
  bool peerRestartingTradingView() {
    final h = lockHolder();
    return h != null && h.app != app && h.action == 'restart_tradingview';
  }

  // --- requests ------------------------------------------------------------

  void sendRequest({required String to, required String type, String reason = ''}) {
    final now = _now();
    final id = '${now.millisecondsSinceEpoch}_${app}_$type';
    _writeAtomic('$_requestsDir${Platform.pathSeparator}$id.json', {
      'id': id,
      'from': app,
      'to': to,
      'type': type,
      'reason': reason,
      'at': now.millisecondsSinceEpoch,
    });
  }

  /// Requests addressed to this app, oldest first; each is deleted as it is
  /// returned (so it is handled once).
  List<Map<String, dynamic>> takeRequests() {
    final d = Directory(_requestsDir);
    if (!d.existsSync()) return const [];
    final files = d
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final out = <Map<String, dynamic>>[];
    for (final f in files) {
      final j = _read(f.path);
      if (j == null || j['to'] != app) continue;
      try {
        f.deleteSync();
      } catch (_) {
        continue;
      }
      out.add(j);
    }
    return out;
  }

  /// True if a request of [type] from this app to [to] is still waiting.
  bool hasPendingRequest({required String to, required String type}) {
    final d = Directory(_requestsDir);
    if (!d.existsSync()) return false;
    for (final f in d.listSync().whereType<File>()) {
      final j = _read(f.path);
      if (j != null && j['from'] == app && j['to'] == to && j['type'] == type) {
        return true;
      }
    }
    return false;
  }
}

class PeerStatus {
  const PeerStatus({
    required this.app,
    required this.at,
    required this.power,
    required this.tab,
    required this.busy,
    required this.tvHealthy,
    required this.version,
  });

  final String app;
  final DateTime at;
  final bool power;
  final String tab;
  final bool busy;
  final bool tvHealthy;
  final String version;
}

class LockInfo {
  const LockInfo({required this.app, required this.action, required this.expiresAt});

  final String app;
  final String action;
  final DateTime expiresAt;
}
