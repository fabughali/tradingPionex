import 'dart:io';

import 'package:path/path.dart' as p;

import 'core_storage.dart';

/// Speaks short voice alerts for trade start/stop events (2026-09-17, per
/// the user - "start long XRP" / "close XRP"). Uses Piper (a small offline
/// neural TTS engine, `en_US-amy-medium` voice - see [CoreStorage.piperDir]
/// for the install) rather than the system's `spd-say`/espeak-ng: the user
/// explicitly asked for a natural-sounding female voice instead of
/// espeak-ng's robotic formant synthesis. Piper has no "speak this now" CLI
/// mode - it synthesizes to a WAV file, so each call runs piper (fed the
/// phrase on stdin, ~1-2s including model load, since each invocation is a
/// fresh process - Piper has no persistent daemon) then plays the result
/// via `aplay`. Both steps run as external OS processes, never on the
/// Flutter UI thread; the engine process is never involved.
class SoundService {
  SoundService(this._storage);

  final CoreStorage _storage;

  /// Bug fixed 2026-09-20, live (per the user: "i feel there is echo in
  /// the sound" - confirmed real: the paired close+start announcement
  /// (2026-09-19 feature) writes two events milliseconds apart on
  /// purpose, and `aplay` used to run detached - this function returned
  /// the instant it LAUNCHED playback, not when it finished, so a second
  /// call landing while the first phrase was still playing started a
  /// second `aplay` on top of it, audibly overlapping into what sounded
  /// like an echo). Now genuinely awaits `aplay`'s own exit before
  /// returning, so the caller (see `ReuseNavShell._speak`'s serialized
  /// queue) can guarantee one phrase fully finishes before the next one
  /// starts, no matter how close together the underlying events are.
  Future<void> speak(String text) async {
    try {
      final wavPath = p.join(
        _storage.piperDir,
        'tmp_${DateTime.now().microsecondsSinceEpoch}.wav',
      );
      final synth = await Process.start(_storage.piperBinary, [
        '-m',
        _storage.piperVoiceModel,
        '-c',
        _storage.piperVoiceConfig,
        '-f',
        wavPath,
        '-q',
      ]);
      synth.stdin.writeln(text);
      await synth.stdin.close();
      final exitCode = await synth.exitCode;
      if (exitCode != 0) return;
      final player = await Process.start('aplay', ['-q', wavPath]);
      await player.exitCode;
      try {
        File(wavPath).deleteSync();
      } catch (_) {}
    } catch (_) {
      // Best-effort notification only - never let a missing engine/model
      // affect trading logic.
    }
  }

  /// Desktop push notification (2026-09-17, per the user: "along with
  /// voice, push notification appears in system... same as the voice") -
  /// fired alongside every [speak] call with the identical phrase, via
  /// `notify-send` (confirmed present and working on this machine), the
  /// standard Linux desktop notification CLI. Same non-blocking, external-
  /// process pattern as [speak]/`aplay` - never touches the engine.
  Future<void> notify(String body) async {
    try {
      await Process.start('notify-send', [
        'TradingPionex',
        body,
      ], mode: ProcessStartMode.detached);
    } catch (_) {
      // Best-effort only - never let a missing notify-send affect trading
      // logic.
    }
  }
}
