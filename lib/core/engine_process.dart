import 'dart:io';

/// The compiled engine's name, without any platform extension.
const String engineProcessName = 'trading_pionex_engine';

/// The compiled engine's file name on this platform.
String get engineBinaryFileName =>
    Platform.isWindows ? '$engineProcessName.exe' : engineProcessName;

/// Returns true only if [candidatePid] is a real, currently-alive process on
/// this machine that is genuinely THIS engine binary - not just any task
/// holding that PID number. Shared by `bin/engine.dart`'s single-instance lock
/// and the GUI's `isEngineProcessAlive`, so the two can never disagree.
///
/// Bug fixed 2026-09-27, real-money, per the user's own direct question
/// ("why i am need to push you to check this ... why app is not having
/// self healing system?"): `kill -0` alone only proves SOME task currently
/// holds [candidatePid] - it says nothing about what that task actually is.
/// Confirmed live: after this engine crashed ungracefully (no clean
/// shutdown, so `logs/engine.pid` was never removed), Linux reused that
/// exact PID number for an unrelated thread of a completely different
/// process (`ThreadPoolForeg`, confirmed via `/proc/<pid>/status`) within
/// minutes - `kill -0` on it still returned success, so a fresh
/// `dart run bin/engine.dart` refused to start ("REFUSING TO START: engine
/// already running as PID ...") against a process that wasn't this engine
/// at all, and the GUI's OWN watchdog was fooled the exact same way, silently
/// never re-launching it either. Fixed by also requiring the process's own
/// identity to mention this binary's name.
///
/// Windows (2026-11-01): `kill` and `/proc` don't exist there, so both checks
/// would throw and this would always answer false - disabling the
/// single-instance lock and allowing two brains on the same trades. `tasklist`
/// answers both questions (alive, and which image) in one call.
bool isEngineProcess(int candidatePid) {
  try {
    if (Platform.isWindows) {
      final result = Process.runSync('tasklist', [
        '/FI',
        'PID eq $candidatePid',
        '/FO',
        'CSV',
        '/NH',
      ]);
      return result.exitCode == 0 &&
          tasklistOutputIsEngine(result.stdout as String);
    }
    final alive =
        Process.runSync('kill', ['-0', candidatePid.toString()]).exitCode == 0;
    if (!alive) return false;
    final cmdline = File('/proc/$candidatePid/cmdline').readAsStringSync();
    return cmdline.contains(engineProcessName);
  } catch (_) {
    return false;
  }
}

/// Whether `tasklist /FO CSV /NH` output names the engine image. Matches the
/// quoted CSV field exactly, since the "no tasks" message is localized and
/// must simply not match, whatever language it's in.
bool tasklistOutputIsEngine(String output) =>
    output.toLowerCase().contains('"$engineProcessName.exe"');
