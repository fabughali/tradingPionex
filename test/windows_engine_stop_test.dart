import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_pionex/core/core_storage.dart';
import 'package:trading_pionex/core/windows_engine_stop.dart';

/// Fake process table: [aliveFor] polls after which a pid reports dead, or
/// never if null. [killWorks] decides whether forceKill actually kills.
class _FakeProcess {
  _FakeProcess({this.aliveFor, this.killWorks = true});
  int? aliveFor;
  final bool killWorks;
  int polls = 0;
  bool killed = false;
  final killedPids = <int>[];

  Future<bool> isAlive(int pid) async {
    if (killed) return false;
    polls++;
    return aliveFor == null || polls <= aliveFor!;
  }

  Future<void> forceKill(int pid) async {
    killedPids.add(pid);
    if (killWorks) killed = true;
  }
}

void main() {
  late Directory dir;
  late CoreStorage storage;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tpx_stop_test');
    storage = CoreStorage.forRoot(dir.path);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void seedRunningEngine(int pid) {
    storage.writeString(storage.pidFile, '$pid\n');
    storage.touchFile(storage.heartbeatFile);
  }

  WindowsEngineStopper stopper(_FakeProcess fake, {List<String>? logs}) => WindowsEngineStopper(
    storage: storage,
    isAlive: fake.isAlive,
    forceKill: fake.forceKill,
    log: (m, {String level = 'INFO'}) => logs?.add('$level $m'),
    graceTimeout: const Duration(seconds: 10),
    killConfirmTimeout: const Duration(seconds: 5),
    pollInterval: const Duration(milliseconds: 500),
    sleep: (_) async {},
  );

  group('WindowsEngineStopper', () {
    test('graceful: request file written, engine exits, GUI cleans up, no kill', () async {
      seedRunningEngine(4242);
      final fake = _FakeProcess(aliveFor: 3);
      var sawRequest = false;
      final s = WindowsEngineStopper(
        storage: storage,
        isAlive: (pid) async {
          sawRequest = sawRequest || storage.fileExists(storage.engineShutdownRequestFile);
          return fake.isAlive(pid);
        },
        forceKill: fake.forceKill,
        sleep: (_) async {},
      );
      expect(await s.stop(), WindowsStopOutcome.graceful);
      expect(sawRequest, isTrue);
      expect(fake.killedPids, isEmpty);
      expect(storage.fileExists(storage.pidFile), isFalse);
      expect(storage.fileExists(storage.heartbeatFile), isFalse);
      expect(storage.fileExists(storage.engineShutdownRequestFile), isFalse);
    });

    test('engine ignores the request: taskkill /F only after the grace period, then cleanup', () async {
      seedRunningEngine(4242);
      final fake = _FakeProcess(aliveFor: null);
      final logs = <String>[];
      expect(await stopper(fake, logs: logs).stop(), WindowsStopOutcome.forceKilled);
      expect(fake.killedPids, [4242]);
      // 1 initial "is anything running" check + the grace wait: checks at
      // 0s, 0.5s ... 10s (21) - the kill never happens before the full 10s.
      expect(fake.polls, 22);
      expect(storage.fileExists(storage.pidFile), isFalse);
      expect(storage.fileExists(storage.heartbeatFile), isFalse);
      expect(storage.fileExists(storage.engineShutdownRequestFile), isFalse);
      expect(logs.any((l) => l.startsWith('WARNING') && l.contains('taskkill /F')), isTrue);
    });

    test('still alive after taskkill: files left in place, reported as such', () async {
      seedRunningEngine(4242);
      final fake = _FakeProcess(aliveFor: null, killWorks: false);
      expect(await stopper(fake).stop(), WindowsStopOutcome.stillAlive);
      expect(storage.fileExists(storage.pidFile), isTrue);
      expect(storage.fileExists(storage.heartbeatFile), isTrue);
    });

    test('stale files from an earlier hard kill are cleaned even with nothing to stop', () async {
      seedRunningEngine(4242);
      final fake = _FakeProcess(aliveFor: 0); // pid file points at a dead process
      expect(await stopper(fake).stop(), WindowsStopOutcome.notRunning);
      expect(fake.killedPids, isEmpty);
      expect(storage.fileExists(storage.pidFile), isFalse);
      expect(storage.fileExists(storage.heartbeatFile), isFalse);
      expect(storage.fileExists(storage.engineShutdownRequestFile), isFalse);
    });

    test('no pid file at all: still clears a stale heartbeat, never kills anything', () async {
      storage.touchFile(storage.heartbeatFile);
      final fake = _FakeProcess(aliveFor: null);
      expect(await stopper(fake).stop(), WindowsStopOutcome.notRunning);
      expect(fake.killedPids, isEmpty);
      expect(storage.fileExists(storage.heartbeatFile), isFalse);
    });

    test('a NEW engine that rewrote engine.pid mid-stop keeps its files', () async {
      seedRunningEngine(4242);
      final fake = _FakeProcess(aliveFor: 2);
      final s = WindowsEngineStopper(
        storage: storage,
        isAlive: (pid) async {
          final alive = await fake.isAlive(pid);
          // A racing Power-on starts a new engine the moment the old one dies.
          if (!alive) seedRunningEngine(5151);
          return alive;
        },
        forceKill: fake.forceKill,
        sleep: (_) async {},
      );
      expect(await s.stop(), WindowsStopOutcome.graceful);
      expect(storage.readString(storage.pidFile)?.trim(), '5151');
      expect(storage.fileExists(storage.heartbeatFile), isTrue);
    });
  });
}
