# Architecture

Status date: 2026-08-30. This is the **single** authoritative design doc for
this app — see the note at the bottom on why there's only one.

## Why this exists

The original engine (`/home/fabughali/trading-bot`, spec'd in `../PRD.md`) is
Node.js, operated by OpenCode via slash commands. This app keeps the exact
same trading rules and safety invariants but:

- is written in **Flutter/Dart** instead of Node.js,
- is operated **standalone**, through its own Dashboard GUI, talking directly
  to TradingView and Pionex — no external operator app in the loop,
- has no cloud backend (Supabase/Firebase) — everything is local files, by
  explicit choice (no remote dependency, no data leaves the machine).

> **2026-08-31 update**: this app originally also shipped a Claude-Desktop-
> operated MCP server (`bin/mcp_server.dart` / `lib/mcp/mcp_server.dart`) as
> a second, chat-based operator surface alongside the GUI — one of the four
> founding project ground-rules. It was explicitly removed by user decision:
> "I want it 100% independent (standalone = TradingView + Pionex)." It never
> made trading decisions itself (reporter/operator only, same contract the
> GUI still follows), so removing it has zero effect on trading behavior —
> only the optional chat-based remote control is gone.

## Two processes, one shared data directory

Exactly like the original engine and its opencode helper scripts never
shared a process (they only communicated through files — `PAUSE`, `STOP`,
`CHECKNOW`, `logs/state.json`, `logs/created-bots.json`, `logs/pending-create.json`)
this app has two independent entry points, both built from the same `lib/`
code, coordinating only through `$TRADING_PIONEX_HOME` (`~/.tradingpionex` by
default — see `lib/core/core_storage.dart`):

```
bin/engine.dart          — the app brain. Long-running. The ONLY process
                            that talks to TradingView (CDP) or decides a
                            trading parameter. Writes logs/status.json,
                            logs/heartbeat, logs/*.jsonl, logs/last-report.json,
                            honors PAUSE/STOP/CHECKNOW. Single-instance-locked
                            via logs/engine.pid — refuses to start a second
                            one against the same data directory. Run this
                            once, leave it running, on the same machine as
                            TradingView Desktop (the GUI's Power toggle
                            launches it automatically if it isn't running).

Flutter GUI (lib/main.dart) — the dashboard. Reads status/reports, toggles
                            control files, never decides a trading parameter
                            itself.
```

This is a **deliberate correction** vs. one instinct I had early on (embedding
the engine inside the Flutter app's own process) — that would tie the
trading engine's lifecycle to whether you happen to have the GUI open, which
is wrong. The file-based, three-process design is what the original already
proved out; I kept it.

## Component map: old → new

| Old (Node) | New (Dart) | Fidelity |
|---|---|---|
| `bot-grid.js` | `lib/data/engine/engine_service.dart` | Full port: candle gate, re-entrancy guard + 600s watchdog, sleep/awake health recovery, indicator retry ladder, funds/selection scoping, same-id close guard, auto-reserve 2-step, shrink retry. One intentional bug fix — see below. |
| `lib/cdp.js` | `lib/data/tradingview/cdp_client.dart` | Full port. Raw WebSocket JSON-RPC, not a browser-automation framework. |
| `lib/chart-state.js` | `lib/data/tradingview/chart_state.dart` | Full port. |
| `lib/signals.js` | `lib/data/tradingview/signals_reader.dart` | Full port — same JS expression strings evaluated via CDP. |
| `lib/watchlist.js` | `lib/data/tradingview/watchlist_reader.dart` | Full port. |
| `lib/enforce.js` | `lib/data/tradingview/enforce.dart` | Full port, including the hover-then-trash real-mouse-event sequence and the promo-dialog dismissal. |
| `lib/launch.js` | `lib/data/tradingview/launch.dart` | Full port. |
| `lib/pionex.js` | `lib/data/pionex/pionex_client.dart` | Full port — same endpoints, same signing, same `cancel` being a POST not a DELETE. |
| `lib/risk.js` | `lib/data/risk/risk_gate.dart` | Full port, **except** day-boundary is UTC midnight, not local midnight (see below). |
| `lib/brain.js` | `lib/data/brain/brain_store.dart` | Full port. |
| `lib/created-bots.js` | `lib/data/identity/created_bots_store.dart` | Full port. |
| `lib/retired.js` | `lib/data/identity/retired_store.dart` | Full port. |
| `lib/logger.js` | `lib/data/logging/app_logger.dart` | Full port. |
| `lib/technique.js` (live path only) | `lib/data/technique/{zigzag_range,grid_count,liquidation,shrink_retry}.dart` | Zigzag range and shrink-retry ported 1:1. Grid count and the 60/40 liquidation model deliberately **corrected**, not ported, per your original spec — see GAPS.md "RESOLVED" section. |
| `scripts/botctl.mjs` + `scripts/trading.mjs` | `lib/data/control/engine_control_repository.dart` | Behavior-equivalent, used by the GUI. |
| OpenCode plugin + slash commands | *(not carried forward)* | The Claude-Desktop/MCP operator surface that replaced this was itself removed 2026-08-31 — see the note near the top of this doc. The GUI is now the only operator surface. |
| `lib/chart.js` | *(not ported)* | Confirmed dead/legacy in the original (PRD: "not used by enforce"). Not carried forward. |
| `lib/cmc-sentiment.js` | *(not ported)* | Only feeds the not-yet-authoritative weighted regime — see GAPS.md. |

## Corrected vs. the original (don't regress these back)

1. **Candle-gate fail path.** The original logged `"could not read reference
   1H bar time — skipping cycle"` but the code didn't actually return there —
   it fell through and ran the full checkup anyway. `engine_service.dart`'s
   `_runCycle()` now actually returns in that branch, matching what the log
   message always claimed.
2. **Day-boundary timezone.** `risk.js` reset counters at *local* midnight
   despite the PRD's prose claiming UTC. `risk_gate.dart` uses UTC midnight,
   deterministically, regardless of the host machine's timezone.
3. **No half-wired features.** The original had several "computed and
   logged, but not authoritative" code paths (weighted regime, the
   regime/direction leverage matrix, label/box range fallbacks, legacy
   TP/SL). None of those were ported. If you decide to activate any of them,
   they get built fresh, end-to-end, at that point — not carried forward as
   dead code waiting for a decision. See GAPS.md.
4. **`refreshSync` actually runs where it was supposed to.** The transcript
   (2026-08-30 21:35) has the user asking for memory-sync-to-Pionex to run
   "before any /checkup and once /trading-bot and before any action." The
   original `trading.mjs` wired this before `checkup`/`start`/autorun.
   `engine_control_repository.dart`'s `status()`, `report()`, and `select()`
   now all call `refreshSync()` first, matching that intent for every
   read/action path the GUI exposes.
5. **One doc, not four.** The original accumulated `HANDOFF.md`,
   `MASTER_HANDOFF.md`, `CURRENT_STATE.md`, and `brain/technique.md`, which
   drifted out of sync with each other and with the actual code over time.
   This app has exactly one architecture doc (this file) and one gaps
   tracker (GAPS.md) — update them in place, don't add a third.

## Data directory layout (`$TRADING_PIONEX_HOME`, default `~/.tradingpionex`)

```
config.json              — mirrors the old config.json shape (see AppConfig)
.env                      — Pionex API key/secret, written only by the Settings screen
PAUSE / STOP / CHECKNOW   — control files (same semantics as the original)
logs/
  engine.log              — structured log, 20MB rotation, 60-day purge
  state.json              — risk gate state (UTC day boundary)
  status.json             — engine status snapshot (read by the GUI)
  last-report.json         — per-cycle preview of actionable candidates
  heartbeat               — liveness timestamp
  engine.pid              — single-instance lock (see bin/engine.dart)
  created-bots.json        — app-initiated buOrderIds
  retired-pairs.json       — bases the engine will never auto-recreate
  pending-create.json      — active /start-equivalent selection, if any
brain/
  BRAIN.md, experience.md, technique.md, decisions.jsonl, trades.jsonl
```

## Platform notes

- **No Supabase/Firebase, by choice.** Cross-platform here means the Flutter
  UI *code* runs anywhere Flutter targets; the actual trading engine only
  ever runs on the Linux machine with TradingView Desktop + CDP, since that
  access can't be remoted without a relay we deliberately didn't build.
- **English only**, l10n architecture (l10n.yaml, ARB, generated
  `AppLocalizations`) is wired for real and used for the static UI chrome
  (nav labels, screen titles, buttons); adding Arabic later is just adding
  `app_ar.arb` entries.
- **Single role.** No admin/viewer split — this app has one operator (you).
