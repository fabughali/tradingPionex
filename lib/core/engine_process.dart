import 'dart:io';

/// The compiled engine's name, without the extension.
const String engineProcessName = 'trading_pionex_engine';

/// The compiled engine's file name (Windows).
const String engineBinaryFileName = '$engineProcessName.exe';

/// True only if [candidatePid] is alive AND is this engine's image, not just
/// any process that happens to hold that PID number now (Windows reuses
/// PIDs). Shared by `bin/engine.dart`'s single-instance lock and the GUI, so
/// the two can never disagree. Same `tasklist` check as tradingMT5.
bool isEngineProcess(int candidatePid) {
  try {
    final result = Process.runSync('tasklist', _tasklistArgs(candidatePid));
    return result.exitCode == 0 &&
        tasklistOutputIsEngine(result.stdout as String);
  } catch (_) {
    return false;
  }
}

/// Async twin of [isEngineProcess] for the GUI: `tasklist` takes a noticeable
/// fraction of a second and the GUI polls it, so it must not block the UI.
Future<bool> isEngineProcessAsync(int candidatePid) async {
  try {
    final result = await Process.run('tasklist', _tasklistArgs(candidatePid));
    return result.exitCode == 0 &&
        tasklistOutputIsEngine(result.stdout as String);
  } catch (_) {
    return false;
  }
}

/// Force-stops the engine process (`taskkill /F`), the last step of a stop
/// that the engine didn't finish by itself.
Future<void> forceKillEngine(int pid) async {
  await Process.run('taskkill', ['/F', '/PID', '$pid']);
}

List<String> _tasklistArgs(int candidatePid) => [
  '/FI',
  'PID eq $candidatePid',
  '/FO',
  'CSV',
  '/NH',
];

/// Whether `tasklist /FO CSV /NH` output names the engine image. Matches the
/// quoted CSV field exactly, since the "no tasks" message is localized and
/// must simply not match, whatever language it's in.
bool tasklistOutputIsEngine(String output) =>
    output.toLowerCase().contains('"$engineProcessName.exe"');
