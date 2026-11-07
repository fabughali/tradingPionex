# TradingPionex

## Download (Windows)

Latest version: **https://fabughali.github.io/tradingPionex/**, or the
[latest release](https://github.com/fabughali/tradingPionex/releases/latest).

Every push to `main` runs the tests and builds the Windows installer and a
portable zip on GitHub Actions (`.github/workflows/windows-build.yml`). Each
build is published as a release tagged from the `version:` in `pubspec.yaml`,
so every update must bump that version and `CoreConstants.appVersion` together
(a test checks they match, and the build refuses a version already released).
The version shows in the app under Settings → About.

A deterministic crypto futures-grid trading engine, rebuilt in Flutter/Dart
from the original Node.js `bot-grid.js` engine (see `../PRD.md` for the full
original spec), with an embedded MCP server so **Claude Desktop** — not
OpenCode — operates it.

Read [ARCHITECTURE.md](ARCHITECTURE.md) first — it explains the 3-process
design (engine / GUI / MCP server), the exact old-component → new-component
mapping, and what's real vs. what's deliberately deferred (see
[GAPS.md](GAPS.md)).

## Running it

Windows only.

```bash
flutter run -d windows
```

Power works like tradingMT5's:

- The app always opens with Power OFF.
- Power ON starts the engine (`trading_pionex_engine.exe`, next to the app).
- Power OFF stops it: it asks the engine to shut down, waits 10s, then runs
  `taskkill /F`. Auto goes off too.
- Closing the app does the same (it asks first if Power is on). If the app
  crashes, the engine stops itself within 60s once the app's heartbeat file
  goes stale.
- Only one copy of the app runs at a time.
- While Power is on, a watchdog restarts the engine if it dies.

Running bots stay open on Pionex while Power is off.

TradingView Desktop is shared with tradingMT5 (one chart tab each, on debug
port 9222), so this app never starts, restarts or kills TradingView. Open
it yourself with `--remote-debugging-port=9222`.

Everything reads and writes one data directory: `%TRADING_PIONEX_HOME%`, or
`%USERPROFILE%\.tradingpionex` by default (config.json, .env, logs/,
brain/). Enter your Pionex API key and secret in the app's **Settings**
screen. They are saved only in that data directory, never in this code or
repo.
