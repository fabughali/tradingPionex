import 'core_storage.dart';

/// How a [WindowsEngineStopper.stop] call ended.
enum WindowsStopOutcome {
  /// No live engine process to stop (no pid file, or it pointed at a dead
  /// process) - any stale pid/heartbeat files were cleaned up.
  notRunning,

  /// The engine saw the shutdown request and exited by itself.
  graceful,

  /// The engine didn't exit within the grace period; `taskkill /F` did it.
  forceKilled,

  /// The process was still alive even after `taskkill /F` - files left in
  /// place on purpose, since they still describe a live process.
  stillAlive,
}

/// The Windows Power-off / GUI-close stop sequence (2026-10-20, per the
/// user, after confirming live that the old path - a bare `taskkill /F` -
/// never let the engine run its own cleanup: 51 Windows Power-offs, zero
/// "shutting down" lines, and `engine.pid` + `heartbeat` left behind every
/// time, which kept the Dashboard showing a dead engine as live and
/// blinded the GUI's own engine watchdog - see PRD §20):
///
/// 1. Write [CoreStorage.engineShutdownRequestFile]; the engine polls it every
///    second and runs its normal shutdown (bin/engine.dart).
/// 2. Wait up to [graceTimeout] for the PID to disappear.
/// 3. Still alive -> `taskkill /F` ([forceKill]), then confirm it's gone.
/// 4. Once the process is confirmed gone (either way), delete
///    `engine.pid` + `heartbeat` + the request file here, on the GUI side,
///    since a hard kill gives the engine no chance to.
///
/// Process access is injected so the sequencing is unit-testable without
/// spawning real processes.
class WindowsEngineStopper {
  WindowsEngineStopper({
    required this.storage,
    required this.isAlive,
    required this.forceKill,
    this.log,
    this.graceTimeout = const Duration(seconds: 10),
    this.killConfirmTimeout = const Duration(seconds: 5),
    this.pollInterval = const Duration(milliseconds: 500),
    Future<void> Function(Duration)? sleep,
  }) : _sleep = sleep ?? Future<void>.delayed;

  final CoreStorage storage;
  final Future<bool> Function(int pid) isAlive;
  final Future<void> Function(int pid) forceKill;
  final void Function(String message, {String level})? log;
  final Duration graceTimeout;
  final Duration killConfirmTimeout;
  final Duration pollInterval;
  final Future<void> Function(Duration) _sleep;

  Future<WindowsStopOutcome> stop() async {
    final pid = int.tryParse((storage.readString(storage.pidFile) ?? '').trim());
    if (pid == null || !await isAlive(pid)) {
      // Nothing alive to stop - but a previous hard kill may have left the
      // files behind, and those are exactly what make the Dashboard lie.
      _cleanUp(pid);
      return WindowsStopOutcome.notRunning;
    }

    storage.touchFile(storage.engineShutdownRequestFile);
    if (await _waitUntilGone(pid, graceTimeout)) {
      _cleanUp(pid);
      return WindowsStopOutcome.graceful;
    }

    log?.call(
      'Engine (pid=$pid) did not exit within ${graceTimeout.inSeconds}s of '
      'the shutdown request - forcing it with taskkill /F.',
      level: 'WARNING',
    );
    try {
      await forceKill(pid);
    } catch (e) {
      log?.call('taskkill /F failed for engine pid=$pid: $e', level: 'ERROR');
    }
    if (await _waitUntilGone(pid, killConfirmTimeout)) {
      _cleanUp(pid);
      return WindowsStopOutcome.forceKilled;
    }

    log?.call(
      'Engine (pid=$pid) is STILL running after taskkill /F - leaving its '
      'pid/heartbeat files in place, since they still describe a live process.',
      level: 'ERROR',
    );
    return WindowsStopOutcome.stillAlive;
  }

  /// Counts elapsed time in [pollInterval] steps rather than wall-clock, so
  /// the timeout is deterministic (each `tasklist` call adds a little real
  /// time on top - the real wait is "at least" [timeout], never shorter).
  Future<bool> _waitUntilGone(int pid, Duration timeout) async {
    var waited = Duration.zero;
    while (true) {
      if (!await isAlive(pid)) return true;
      if (waited >= timeout) return false;
      await _sleep(pollInterval);
      waited += pollInterval;
    }
  }

  /// Only removes `engine.pid` + `heartbeat` if the pid file still names
  /// the process this call stopped (or none at all) - a Power-on racing
  /// this stop may already have started a NEW engine that rewrote them, and
  /// deleting those would make a live engine look dead.
  void _cleanUp(int? stoppedPid) {
    final currentPid = int.tryParse((storage.readString(storage.pidFile) ?? '').trim());
    if (currentPid == null || currentPid == stoppedPid) {
      storage.deleteFileIfExists(storage.pidFile);
      storage.deleteFileIfExists(storage.heartbeatFile);
    }
    storage.deleteFileIfExists(storage.engineShutdownRequestFile);
  }
}
