# TradingPionex

## Download (Windows)

Latest version: **https://fabughali.github.io/tradingPionex/**, or the
[latest release](https://github.com/fabughali/tradingPionex/releases/latest).

Every push to `main` runs the tests and builds the Windows installer and a
portable zip on GitHub Actions (`.github/workflows/windows-build.yml`). Each
build is published as a release tagged from the `version:` in `pubspec.yaml`,
so bump that version for every new release.

A deterministic crypto futures-grid trading engine, rebuilt in Flutter/Dart
from the original Node.js `bot-grid.js` engine (see `../PRD.md` for the full
original spec), with an embedded MCP server so **Claude Desktop** — not
OpenCode — operates it.

Read [ARCHITECTURE.md](ARCHITECTURE.md) first — it explains the 3-process
design (engine / GUI / MCP server), the exact old-component → new-component
mapping, and what's real vs. what's deliberately deferred (see
[GAPS.md](GAPS.md)).

## Running it

```bash
# 1. The dashboard GUI (start this first — it controls the engine):
flutter run -d linux    # or macos / windows / your target

# 2. Claude Desktop's MCP server (point Claude Desktop's MCP config at this):
dart run bin/mcp_server.dart
```

The engine is launched BY the GUI's Power toggle, not run standalone
(`dart run bin/engine.dart` manually will self-terminate within ~60s since
the GUI isn't there to keep its heartbeat file fresh — see PRD §4.4). Power
off always stops the engine too, with no exception.

All three read/write the same data directory: `$TRADING_PIONEX_HOME`, or
`~/.tradingpionex` by default (config.json, .env, logs/, brain/, and the
PAUSE/STOP/CHECKNOW control files). Put your Pionex API credentials in
`~/.tradingpionex/.env` — see `.env.example`.

**Known environment note:** if this project directory lives on a FAT32/exFAT
mount (as it currently does on this machine — `/media/.../PARTITION11`),
built binaries lose their executable bit (`fmask=0022`), which can make
`flutter run -d linux` hang trying to launch the built app. `flutter build
linux` itself still works; copying the resulting `build/linux/x64/*/bundle/`
to an ext4-backed path (e.g. under `$HOME`) before running it works around
this. Worth moving the project off FAT32 if this becomes a recurring
friction point.
