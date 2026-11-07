import 'dart:io';

import 'core_storage.dart';

/// One GUI per data directory (2026-10-20, found live): a second
/// `trading_pionex.exe` launched while one was already open ran main()'s
/// "every GUI launch forces Power OFF" step and stopped the live engine
/// with two real positions open - and the two windows then disagreed about
/// what was running. The second launch now exits before touching anything
/// (no Power change, no heartbeat, no watchdog) and, on Windows, brings the
/// already-open window to the front instead.
class GuiInstanceLock {
  GuiInstanceLock._();

  /// Held for the whole process lifetime - never closed. The OS drops the
  /// lock when the process exits, including on a crash, so a stale lock
  /// can't block the next launch.
  ///
  /// MUST stay genuinely read (see [release]) - found live in v1.6.25: when
  /// this field was write-only, the release (AOT) build's tree-shaker
  /// dropped the store, the open handle became unreachable, GC finalized it
  /// (closing the file and releasing the lock) within seconds of startup,
  /// and a second launch got the lock anyway. The unit tests (JIT) never
  /// saw it. A real read here keeps the handle reachable for the process
  /// lifetime.
  static RandomAccessFile? _held;

  /// Explicit release on a graceful GUI exit (the OS would do it anyway) -
  /// also the read that keeps [_held] from being optimized away.
  static void release() {
    final held = _held;
    _held = null;
    if (held == null) return;
    try {
      held.unlockSync();
      held.closeSync();
    } catch (_) {}
  }

  /// Whether this process currently holds the lock.
  static bool get isHeld => _held != null;

  /// True if this process now owns the GUI lock (or the lock couldn't be
  /// set up at all - failing open, so a filesystem problem never stops the
  /// app from starting). False only when another live GUI holds it.
  static bool acquire(CoreStorage storage) {
    try {
      storage.ensureDir(storage.logsDir);
      final raf = File(storage.guiLockFile).openSync(mode: FileMode.append);
      try {
        raf.lockSync(FileLock.exclusive);
      } on FileSystemException {
        raf.closeSync();
        return false;
      }
      _held = raf;
      storage.writeString(storage.guiPidFile, '$pid\n');
      return true;
    } catch (_) {
      return true;
    }
  }

  /// Best effort: focus the GUI that holds the lock (Windows only).
  static Future<void> focusExisting(CoreStorage storage) async {
    if (!Platform.isWindows) return;
    final other = int.tryParse((storage.readString(storage.guiPidFile) ?? '').trim());
    if (other == null) return;
    try {
      await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '(New-Object -ComObject WScript.Shell).AppActivate($other) | Out-Null',
      ]);
    } catch (_) {}
  }
}
