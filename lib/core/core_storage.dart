import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/models/auto_category.dart';

/// Local filesystem layout for the app's runtime data (config, secrets, logs,
/// brain memory, control files). Shared verbatim by both entry points — the
/// Flutter GUI and `bin/engine.dart` — so they agree on where PAUSE/STOP/
/// CHECKNOW and the JSON state files live, exactly like the original Node
/// engine and its opencode helper scripts agreed on one `config.json` full
/// of absolute paths. Native platforms only (dart:io); there is no
/// local-file runtime on Flutter Web by design (no cloud relay).
class CoreStorage {
  CoreStorage._(this.rootDir);

  final String rootDir;

  static CoreStorage? _instance;

  static CoreStorage get instance =>
      _instance ??= CoreStorage._(_resolveRootDir());

  /// A storage rooted at [rootDir] - for tests.
  factory CoreStorage.forRoot(String rootDir) => CoreStorage._(rootDir);

  static String _resolveRootDir() {
    final override = Platform.environment['TRADING_PIONEX_HOME'];
    if (override != null && override.trim().isNotEmpty) return override;
    final home = Platform.environment['USERPROFILE'] ?? '.';
    return p.join(home, '.tradingpionex');
  }

  /// The pairs Check Now reads, in the table's order (written by the app,
  /// read by the engine): `{round, symbols}`. A new Check Now press starts a
  /// new round; "Show more" keeps the round and adds rows, so pairs already
  /// read in this round aren't read again.
  String get checkNowPairsFile => p.join(logsDir, 'check-now-pairs.json');

  /// The Pionex stock-token bases (AAPLX, SNDKX...), one JSON array, edited
  /// by the user when Pionex adds or removes stock tokens. Written from the
  /// app's built-in list when missing.
  String get stockTokensFile => p.join(rootDir, 'stock-tokens.json');

  /// Held (locked) by the one running GUI - see `GuiInstanceLock`.
  String get guiLockFile => p.join(logsDir, 'gui.lock');

  /// The running GUI's PID, so a second launch can focus its window.
  String get guiPidFile => p.join(logsDir, 'gui.pid');

  /// Present while the user has Power on (written by Power ON, removed by
  /// Power OFF, app close and every app launch). The GUI's engine watchdog
  /// restarts a dead engine only while this exists - same role as
  /// tradingMT5's "Power on" state.
  String get powerOnFile => p.join(logsDir, 'power-on');

  String get configFile => p.join(rootDir, 'config.json');
  String get envFile => p.join(rootDir, '.env');

  String get logsDir => p.join(rootDir, 'logs');
  String get logFile => p.join(logsDir, 'engine.log');
  String get stateFile => p.join(logsDir, 'state.json');
  String get createdBotsFile => p.join(logsDir, 'created-bots.json');
  String get widenAppliedBotsFile => p.join(logsDir, 'widen-applied-bots.json');
  String get retiredPairsFile => p.join(logsDir, 'retired-pairs.json');

  /// Which rotating cycle-marker index (see `AutoCategoryStatus
  /// .cycleMarkerIndex`) each "BASE|CATEGORY_WIRE" pair was last actually
  /// checked under (2026-09-12, per the user) - lets the GUI show a bot's
  /// row with the same marker its category's toggle is currently showing
  /// once it's been checked in the CURRENT sweep, so the user can spot at
  /// a glance whether the whole list has been covered yet. In-memory
  /// resets are fine (this file just gets overwritten fresh); not read
  /// back by the engine itself, GUI-display-only.
  String get cycleMarkersFile => p.join(logsDir, 'cycle-markers.json');

  /// Bases the app is currently responsible for autonomously managing -
  /// added the moment a grid is created (by the app itself, or a manual
  /// bot converted via the Dashboard toggle), and, unlike created-bots.json
  /// (which only tracks the CURRENT bot's id and forgets it the instant
  /// that bot closes), this deliberately survives a close: a base stays
  /// auto-managed through a signal-flip close so the very next auto-
  /// checkup pass still picks it up and reopens it fresh - the "close then
  /// reopen" cycle the user described. Only removed by an explicit
  /// Stop/Last.
  String get autoManagedBasesFile => p.join(logsDir, 'auto-managed-bases.json');

  /// Per-buOrderId auto TP/SL ratchet state (see [TpSlRatchetStore]) —
  /// which threshold each auto bot's stop-loss has already been ratcheted
  /// to, and whether its baseline TP/SL has been set yet.
  String get tpSlRatchetFile => p.join(logsDir, 'tpsl-ratchet.json');

  /// Which pairs/bots are governed by the "Stop Loss Lock" engine (see
  /// `StopLossLockStore`, 2026-09-22, per the user) instead of the normal
  /// TP/SL ratchet - composite "BASE|CATEGORY" keys for auto bots (persists
  /// across recycles, same convention as [retiredPairsFile]), "MANUAL|
  /// `buOrderId`" keys for manual bots (which have no inherent category, so
  /// the picked chart timeframe is stored alongside the tag itself).
  String get stopLossLockTagsFile =>
      p.join(logsDir, 'stop-loss-lock-tags.json');

  /// Per-buOrderId Stop Loss Lock state (see `StopLossLockStateStore`) -
  /// the highest profit-floor SL percentage locked in so far for that bot
  /// instance. Keyed by buOrderId, same reset-on-recycle convention as
  /// [tpSlRatchetFile].
  String get stopLossLockStateFile =>
      p.join(logsDir, 'stop-loss-lock-state.json');

  /// Per-buOrderId entry-signal record (see `EntrySignalStore`) - which of
  /// the user's 60 (signal, zone) entries opened this bot, and, once known,
  /// which one closed it. Keyed by buOrderId; a fresh recycle gets its own
  /// fresh entry (this file only ever holds currently-open bots - a closed
  /// bot's record moves into `bot-history.jsonl` and is removed from here).
  String get entrySignalsFile => p.join(logsDir, 'entry-signals.json');
  String get pendingCreateFile => p.join(logsDir, 'pending-create.json');
  String get heartbeatFile => p.join(logsDir, 'heartbeat');
  String get statusFile => p.join(logsDir, 'status.json');

  /// The engine's per-cycle preview of every currently-actionable Red List
  /// candidate (see `PreviewGridPair`/`LastReport`) — backs the dashboard's
  /// "Last report" checklist. Written by the engine, read-only elsewhere.
  String get lastReportFile => p.join(logsDir, 'last-report.json');

  /// The same checkup cycle's read on every currently-RUNNING auto bot (see
  /// `RunningBotCheck`/`RunningBotsReport`) - a separate file from
  /// [lastReportFile] since it's a different subject (bots that already
  /// exist vs. candidates that don't yet).
  String get runningBotsReportFile =>
      p.join(logsDir, 'running-bots-report.json');

  /// The running engine process's PID, written on startup by `bin/engine.dart`
  /// and removed on clean shutdown — lets the GUI tell "engine process is
  /// actually alive" apart from "status.json just hasn't been touched
  /// recently" before deciding whether Power-on needs to launch a new one
  /// (launching a second engine process would be two brains fighting over
  /// the same trades).
  String get pidFile => p.join(logsDir, 'engine.pid');

  /// Windows only: the GUI's Power off creates this to ask the engine to run
  /// its normal graceful shutdown, standing in for SIGTERM, which Windows
  /// can't deliver. The engine deletes it on sight and on startup.
  String get engineShutdownRequestFile =>
      p.join(logsDir, 'engine-shutdown-request');

  String get pauseFile => p.join(rootDir, 'PAUSE');

  /// Touched by the GUI every few seconds while it's running (2026-10-20,
  /// per the user: "gui off == engine is off"). The engine
  /// treats a stale/missing file as "the GUI is gone" and shuts itself
  /// down - see `EngineService._checkGuiHeartbeat`. Replaces the old
  /// `LAST_ONLY_MODE` lingering behavior entirely: Power off now always
  /// stops the engine process outright, no exception for a still-running
  /// Last-marked bot (that position stays open and untouched on Pionex,
  /// simply unmonitored until Power is turned back on).
  String get guiHeartbeatFile => p.join(logsDir, 'gui-heartbeat');
  String get stopFile => p.join(rootDir, 'STOP');
  String get checknowFile => p.join(rootDir, 'CHECKNOW');

  /// Touched when Auto is explicitly turned on - tells the Auto-checkup
  /// track's own poll to force its way in ahead of a running checkup this
  /// one time, the same way CHECKNOW does for Checkup itself. Deleted by
  /// the engine once consumed.
  String get autoCheckNowFile => p.join(rootDir, 'AUTO_CHECKNOW');

  /// Per-category equivalent of [autoCheckNowFile] - each of the 3 Auto
  /// engines (2026-09-07) forces its way in ahead of a running checkup
  /// independently of the other two.
  String autoCheckNowFileFor(AutoCategory c) =>
      p.join(rootDir, 'AUTO_CHECKNOW_${c.wireValue}');

  /// Per-category on/off switch, independent of [pauseFile] (Power) and of
  /// the other two categories - presence means THIS category is paused,
  /// same convention as [pauseFile] itself. Power off still overrides every
  /// category regardless of this file's state (Auto must never appear on
  /// while Power is off).
  String autoCategoryPausedFileFor(AutoCategory c) =>
      p.join(rootDir, 'AUTO_PAUSED_${c.wireValue}');

  /// Which bases are auto-managed under this specific category - the 1H
  /// category keeps the original filename (it's the pre-existing engine,
  /// per the user: "current auto trades... are at engine 1H list"); 1m and
  /// 1D get their own separate files.
  String autoManagedBasesFileFor(AutoCategory c) => c == AutoCategory.oneHour
      ? autoManagedBasesFile
      : p.join(logsDir, 'auto-managed-bases-${c.wireValue}.json');

  /// Which category a given app-initiated bot belongs to (buOrderId ->
  /// category) - Pionex has no such concept, this is purely the app's own
  /// record, stamped at open/convert time. Drives the "(1H)"/"(1m)"/"(1D)"
  /// tag shown after a pair name.
  String get botCategoriesFile => p.join(logsDir, 'bot-categories.json');

  /// The category (1m/1H/1D) chosen per pair via the Next Trade/Check-card
  /// knob (2026-09-07) - defaults to 1H when a pair has never been touched.
  String get pairCategoriesFile => p.join(logsDir, 'pair-categories.json');

  /// The initial investment (USDT) chosen per pair via the Next Trade/
  /// Check-card text field (2026-09-09) - defaults to $10 when a pair has
  /// never been touched. Only ever consulted for a pair's very first real
  /// open - an already-recycling bot's P&L-adjusted amount is untouched.
  String get pairInvestmentsFile => p.join(logsDir, 'pair-investments.json');

  /// One-shot trigger (same touch-file handshake as CHECKNOW): asks the
  /// engine to connect to TradingView and re-read the Red List right now,
  /// independent of PAUSE - Power ON uses this so the Red List is fresh
  /// even while Auto is still off (the main loop, which normally reads it,
  /// doesn't run at all while paused).
  String get refreshRedListFile => p.join(rootDir, 'REFRESH_REDLIST');

  /// Controls screen's single-pair actions (check/add/remove against the
  /// TradingView Red List watchlist) - a one-shot JSON request file, same
  /// PAUSE/STOP/CHECKNOW-style handshake, consumed by the engine within a
  /// couple seconds and answered via [pairActionResultFile]. "Last"/"Stop"
  /// for a single pair don't go through this file at all - they're plain
  /// Pionex API + local-store calls the GUI makes directly, no TradingView
  /// CDP session (and therefore no engine involvement) required.
  String get pairActionFile => p.join(rootDir, 'PAIR_ACTION');
  String get pairActionResultFile => p.join(logsDir, 'pair-action-result.json');

  /// History screen's data: one line per Last/Stop/converted-to-manual
  /// event on an app-initiated bot (see `BotHistoryEntry`). Append-only in
  /// normal operation (written by both the engine and the GUI repository,
  /// whichever side observes the event first) - only the History screen's
  /// own delete/clear actions ever rewrite it.
  String get botHistoryFile => p.join(logsDir, 'bot-history.jsonl');

  /// Reset point (2026-09-10) for the Auto bots card's profit/loss summary
  /// - GUI-only, never read by the engine. Holds `{"reset_at_ms": ...}`;
  /// the summary sums `BotHistoryEntry.realizedProfit` for entries with
  /// `ts` after this point only. Resetting the summary is deliberately
  /// non-destructive - it never touches `bot-history.jsonl` itself (the
  /// permanent audit trail the History screen reads), it just moves this
  /// cutoff forward.
  String get pnlResetFile => p.join(logsDir, 'pnl-reset.json');

  /// Engine-written checkpoint (2026-09-21) for the startup history-gap
  /// reconciliation - see `EngineService._reconcileHistoryGapOnStartup`'s
  /// own doc comment for the live incidents (a redeploy gap, then a
  /// multi-hour disk-full/CDP outage) that motivated it. Holds
  /// `{"checked_through_ms": <epoch ms>}`, the wall-clock moment the last
  /// successful reconciliation pass finished - the next startup's query to
  /// Pionex's real closed-grids history starts from here, not from
  /// scratch, so a long-running engine's occasional restarts stay cheap
  /// (only ever re-checking the gap since the last check, never the
  /// entire trading history).
  String get historyReconcileCheckpointFile =>
      p.join(logsDir, 'history-reconcile-checkpoint.json');

  /// Engine-written export (2026-09-10) of `_nextInvestmentByPair` - the
  /// in-memory-only pending recycled investment for a base+category that's
  /// closed and waiting for its next auto-checkup reopen attempt. Keyed
  /// `"BASE|CATEGORY_WIRE_VALUE"` (e.g. `"XRP|ONE_HOUR"`), value is the
  /// USDT amount that reopen will actually use. Lets the GUI show a
  /// "waiting" pair before it succeeds, without needing to guess the
  /// engine's own in-memory state.
  String get pendingInvestmentsFile =>
      p.join(logsDir, 'pending-investments.json');

  /// The symbols a multi-symbol Start request is currently still working
  /// through - written by the engine, read by the GUI so a user-initiated
  /// pair still waiting to be checked shows in the Auto bots card's
  /// "Waiting" row too (2026-09-11, per the user), not just recycled
  /// bases waiting for their next auto-checkup attempt.
  String get startInProgressFile =>
      p.join(logsDir, 'start-in-progress.json');

  /// Engine-written export (2026-10-25) of `_worm10Pending`/
  /// `_worm10Confirmed` - Worm10's confirm+survive-one-candle gate (§5 of
  /// the user's spec). Replaces `fresh-entry-signal.json`/the old
  /// worm_9_26-era fresh-signal-wait entirely (per the user: "remove any
  /// old technique from code and from prd") - same restart-resilience
  /// reasoning: without this, a restart mid-wait would silently forget
  /// which candidate is pending and how long it's survived, or forget an
  /// already-confirmed event and stop acting on it. Keyed
  /// `"BASE|CATEGORY_WIRE_VALUE"`; each entry carries the pending
  /// candidate (if any) and the currently-confirmed event (if any) as
  /// `{type, time}` pairs.
  String get worm10GateFile => p.join(logsDir, 'worm10-gate.json');

  /// One line per real TradingView-driven open/close decision (2026-09-17,
  /// per the user: voice alerts - "start long/short PAIR" / "close PAIR").
  /// Written only by the engine (see `TradeStartEvent`'s doc comment for
  /// exactly which moment, and why) - always engine-initiated regardless of
  /// kind (a close is only ever decided inside `_manageGridPair`'s own
  /// opposite-signal branch, same as an open), unlike [botHistoryFile]
  /// (which also covers GUI-initiated closes like Stop/Last - deliberately
  /// NOT what this feature announces, since those aren't TradingView
  /// triggers). Append-only, GUI-read-only; purely a notification feed, not
  /// a source of truth for anything else already tracked elsewhere.
  String get tradeStartEventsFile =>
      p.join(logsDir, 'trade-start-events.jsonl');

  /// Per-trigger mute state for the voice-alert feature (2026-09-17) -
  /// GUI-only, never read by the engine, same "own tiny file" convention as
  /// [pnlResetFile]. Holds `{"start": bool, "stop": bool}`, true meaning
  /// muted; a trigger missing from the file defaults to unmuted.
  String get soundSettingsFile => p.join(logsDir, 'sound-settings.json');


  String get brainDir => p.join(rootDir, 'brain');
  String get brainIndexFile => p.join(brainDir, 'BRAIN.md');
  String get experienceFile => p.join(brainDir, 'experience.md');
  String get techniqueFile => p.join(brainDir, 'technique.md');
  String get decisionsFile => p.join(brainDir, 'decisions.jsonl');
  String get tradesFile => p.join(brainDir, 'trades.jsonl');

  void ensureDir(String dirPath) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) dir.createSync(recursive: true);
  }

  void ensureRuntimeDirs() {
    ensureDir(rootDir);
    ensureDir(logsDir);
    ensureDir(brainDir);
  }

  bool fileExists(String path) => File(path).existsSync();

  void touchFile(String path, {String? contents}) {
    ensureDir(p.dirname(path));
    File(
      path,
    ).writeAsStringSync(contents ?? '${DateTime.now().toIso8601String()}\n');
  }

  void deleteFileIfExists(String path) {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  }

  String? readString(String path) {
    final f = File(path);
    if (!f.existsSync()) return null;
    try {
      return _retryIfLocked(f.readAsStringSync);
    } catch (_) {
      return null;
    }
  }

  /// Windows (2026-11-01): a file the other process has open can briefly refuse
  /// a read or a rename-over, where POSIX never would. Callers treat a failed
  /// read like a missing file - for the GUI heartbeat that means shutting the
  /// engine down - so a momentary lock gets a few short retries first. Runs
  /// [action] exactly once everywhere else.
  T _retryIfLocked<T>(T Function() action) {
    for (var attempt = 0; Platform.isWindows && attempt < 5; attempt++) {
      try {
        return action();
      } on FileSystemException {
        sleep(const Duration(milliseconds: 20));
      }
    }
    return action();
  }

  /// Atomic write: writes to a sibling temp file, then renames it over
  /// [path]. `rename` is atomic on the same filesystem (POSIX), so a
  /// concurrent reader (the other process, or this same process's next
  /// cycle) always sees either the complete old content or the complete new
  /// content - never a truncated write mid-flight. A direct
  /// `writeAsStringSync` on the real path would leave exactly that
  /// torn-content window open, which is indistinguishable from a corrupt
  /// file to every reader in this codebase (readJsonObject/readJsonArray
  /// both catch a decode failure and return null - the same value used for
  /// "file doesn't exist yet").
  void writeString(String path, String contents) {
    ensureDir(p.dirname(path));
    final tmp = File('$path.tmp-${DateTime.now().microsecondsSinceEpoch}');
    tmp.writeAsStringSync(contents);
    _retryIfLocked(() => tmp.renameSync(path));
  }

  void appendString(String path, String contents) {
    ensureDir(p.dirname(path));
    File(path).writeAsStringSync(contents, mode: FileMode.append);
  }

  Map<String, dynamic>? readJsonObject(String path) {
    final raw = readString(path);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  List<dynamic>? readJsonArray(String path) {
    final raw = readString(path);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Same data as [readJsonArray], but for callers where "the file exists
  /// but failed to parse" must NOT collapse into the same outcome as "the
  /// file doesn't exist yet" - e.g. `created-bots.json`/`retired-pairs.json`,
  /// where silently treating corruption as "empty" would let the engine
  /// forget a real running bot's app-initiated/retired status and act on
  /// real money as if it were a fresh pair. Returns `[]` only when [path]
  /// genuinely doesn't exist; throws [FormatException] when it exists but
  /// couldn't be parsed as a JSON array, so the caller can keep its
  /// last-known-good in-memory state instead of resetting to empty.
  List<dynamic> readJsonArrayStrict(String path) {
    if (!fileExists(path)) return const [];
    final raw = readString(path);
    if (raw == null) {
      throw FormatException('$path exists but could not be read');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw FormatException('$path does not contain a JSON array');
    }
    return decoded;
  }

  void writeJson(String path, Object value) {
    writeString(path, '${const JsonEncoder.withIndent('  ').convert(value)}\n');
  }

  List<Map<String, dynamic>> readJsonl(String path) {
    final raw = readString(path);
    if (raw == null) return const [];
    final out = <Map<String, dynamic>>[];
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) out.add(decoded);
      } catch (_) {
        // Skip a corrupt line rather than failing the whole read.
      }
    }
    return out;
  }

  void appendJsonl(String path, Map<String, dynamic> entry) {
    appendString(path, '${jsonEncode(entry)}\n');
  }

  /// Rewrites the whole file from [entries] - used by History's per-record
  /// delete and clear-all, the only things allowed to remove lines from an
  /// otherwise append-only `.jsonl` file.
  ///
  /// Bug fixed 2026-09-11: this used to join entries with `\n` but never
  /// write a trailing one, so the file ended exactly at the last entry's
  /// closing `}` with no newline. The next [appendJsonl] call on the same
  /// file (mode: append, raw bytes) then landed directly after that `}`
  /// with no separator - silently merging two JSON objects onto one line,
  /// which [readJsonl] treats as corrupt and drops entirely. Every entry
  /// [entries] is empty ('' below) still gets the trailing newline so a
  /// clear-all followed by the very next append starts clean too.
  void writeJsonl(String path, List<Map<String, dynamic>> entries) {
    final body = entries.map((e) => jsonEncode(e)).join('\n');
    writeString(path, entries.isEmpty ? '' : '$body\n');
  }

  /// `.env`-style `KEY=value` parsing (no quoting/escaping support, matching
  /// the original engine's minimal loader — this file never holds anything
  /// beyond flat secrets).
  Map<String, String> readEnvFile() {
    final raw = readString(envFile);
    if (raw == null) return const {};
    final out = <String, String>{};
    final pattern = RegExp(r'^([A-Z_][A-Z0-9_]*)=(.*)$');
    for (final line in raw.split('\n')) {
      final match = pattern.firstMatch(line);
      if (match != null) out[match.group(1)!] = match.group(2)!;
    }
    return out;
  }

}
