import 'dart:io';

/// Speaks short voice alerts for trade start/stop events ("start long XRP" /
/// "close XRP") with Windows' built-in speech (System.Speech), run through
/// PowerShell - nothing to install or download. Runs as an external process,
/// never on the Flutter UI thread; the engine is never involved.
class SoundService {
  const SoundService();

  /// Speaks [text] and returns once it has finished, so a caller's queue
  /// (see `ReuseNavShell._speak`) never overlaps two phrases.
  Future<void> speak(String text) async {
    try {
      // Passed as an argument, never spliced into the script, so no text can
      // break out of the quoted string.
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'Add-Type -AssemblyName System.Speech; '
            r'$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; '
            r'$s.Speak($args[0])',
        text,
      ]);
      if (result.exitCode != 0) return;
    } catch (_) {
      // Best-effort only - never let speech affect trading.
    }
  }
}
