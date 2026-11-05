import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/core_storage.dart';

/// Central logging — ported 1:1 from lib/logger.js. Structured lines
/// (`[ISO-timestamp] [LEVEL] message`), 20MB rotation into timestamped
/// archives, and an automatic 60-day purge throttled to ~once/minute so it
/// never slows a hot write loop.
class AppLogger {
  AppLogger(this._storage);

  final CoreStorage _storage;
  static const _rotateSizeBytes = 20 * 1024 * 1024;
  static const _defaultRetentionDays = 60;
  static const _purgeInterval = Duration(minutes: 1);
  DateTime _lastPurge = DateTime.fromMillisecondsSinceEpoch(0);

  String _inferLevel(String message) {
    if (RegExp(
      r'^(CRITICAL|FATAL|MAINLOOP WATCHDOG)',
      caseSensitive: false,
    ).hasMatch(message))
      return 'CRITICAL';
    if (RegExp(
      r'\b(FAILED|ERROR|ERR\b|EXCEPTION|DOWN|REFUSING|BLOCKED|WARNING|warning:)',
      caseSensitive: false,
    ).hasMatch(message))
      return 'ERROR';
    return 'INFO';
  }

  void _maybeRotate() {
    final file = File(_storage.logFile);
    if (!file.existsSync()) return;
    final stat = file.statSync();
    if (stat.size < _rotateSizeBytes) return;
    final stamp = stat.modified.toUtc().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final archive = p.join(_storage.logsDir, 'engine.$stamp.log');
    file.renameSync(archive);
    File(_storage.logFile).writeAsStringSync('');
  }

  Map<String, dynamic> purgeOldLogs({
    int days = _defaultRetentionDays,
    bool force = false,
  }) {
    final now = DateTime.now();
    if (!force && now.difference(_lastPurge) < _purgeInterval)
      return {'purged': 0, 'skipped': 'throttled'};
    _lastPurge = now;
    final cutoff = now.subtract(Duration(days: days));
    var purged = 0;
    final dir = Directory(_storage.logsDir);
    if (!dir.existsSync())
      return {'purged': 0, 'error': 'cannot read logs dir'};
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!RegExp(r'^engine(\..*)?\.log$').hasMatch(name)) continue;
      if (entity.statSync().modified.isBefore(cutoff)) {
        try {
          entity.deleteSync();
          purged++;
        } catch (_) {}
      }
    }
    return {
      'purged': purged,
      'days': days,
      'cutoff': cutoff.toUtc().toIso8601String(),
    };
  }

  Map<String, dynamic> clearLogs() {
    var cleared = 0;
    final dir = Directory(_storage.logsDir);
    if (!dir.existsSync())
      return {'cleared': 0, 'error': 'cannot read logs dir'};
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      if (!RegExp(r'^engine(\..*)?\.log$').hasMatch(p.basename(entity.path)))
        continue;
      try {
        entity.deleteSync();
        cleared++;
      } catch (_) {}
    }
    return {'cleared': cleared};
  }

  List<Map<String, dynamic>> listLogs() {
    final dir = Directory(_storage.logsDir);
    if (!dir.existsSync()) return const [];
    final out = <Map<String, dynamic>>[];
    final entries = dir.listSync()..sort((a, b) => a.path.compareTo(b.path));
    for (final entity in entries) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!RegExp(r'^engine(\..*)?\.log$').hasMatch(name)) continue;
      final stat = entity.statSync();
      out.add({
        'name': name,
        'bytes': stat.size,
        'ageDays': DateTime.now().difference(stat.modified).inMinutes / 1440.0,
        'mtime': stat.modified.toUtc().toIso8601String(),
      });
    }
    return out;
  }

  String log(String line, {String? level}) {
    final stamp = DateTime.now().toUtc().toIso8601String();
    final lvl = (level ?? _inferLevel(line)).toUpperCase();
    final text = '[$stamp] [$lvl] $line';
    // ignore: avoid_print
    print(text);
    try {
      _storage.ensureRuntimeDirs();
      _maybeRotate();
      _storage.appendString(_storage.logFile, '$text\n');
      purgeOldLogs();
    } catch (_) {}
    return text;
  }
}
