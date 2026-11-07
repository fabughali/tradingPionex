# Known gaps / deliberately deferred

Status date: 2026-08-30. Update this file, don't create a second one — see
ARCHITECTURE.md's note on doc drift.

## RESOLVED — pagination bug found and fixed (2026-08-31)

`GET /api/v1/bot/orders` paginates at 10 results per page (undocumented,
confirmed live) and returns a `nextPageToken` when more exist. Both the
original Node bot (`lib/pionex.js`) and this app's initial port only read
page one, silently hiding any 11th+ running bot. You noticed it as "manual
trades only shows 10 bots" — live probe confirmed 12 running futures grids
(10 + 2 on page two). Beyond the UI, this could have let the engine open a
duplicate grid on a pair whose only running bot happened to be past position
10. Fixed in `lib/data/pionex/pionex_client.dart`'s `listBotOrders` to loop
on `pageToken` until `nextPageToken` is null. The original Node bot at
`/home/fabughali/trading-bot` still has this bug — worth patching there too
if it's ever powered back up.

## RESOLVED — corrected per your explicit direction (2026-08-31)

Both of these were flagged as suspected "misunderstandings and gaps" between
the original ask and what OpenCode actually built (found by reading
`ALL_USER_INPUTS.txt`, all 6475 lines, end to end). You've since confirmed
which behavior you actually want for each, and the code now implements that
— **deliberately diverging from the shipped Node engine**, not from a
faithful-port oversight:

1. **Grid count formula** — now `probeMaxGridCount` in
   `lib/data/technique/grid_count.dart`: starts at the configured minimum
   and binary-searches upward, asking Pionex's `checkParams` at each
   candidate row whether the investment still covers it, landing on the
   highest row that validates. This matches your original 2026-08-20 spec
   (the shipped Node engine used a flat `investment/10` heuristic instead,
   which was never actually confirmed with you anywhere in the transcript).
   Per your note that this should work "the same as" the auto-reserve split
   — both are just "ask Pionex before creating" — the grid-count probe and
   the auto-reserve `checkParams` call are now the **same** request:
   `engine_service.dart`'s `_manageGridPair` folds them together, so a
   successful probe at the winning row already carries that row's
   actual/reserve breakdown with no second round-trip.
2. **60/40 liquidation model — which edge moves.** `lib/data/technique/liquidation.dart`
   now implements your original description exactly: the **stop-loss edge
   never moves** (always the original zigzag range bound); when entry isn't
   60% clear of it, the **take-profit edge** is pulled inward instead. This
   is the opposite of the shipped Node engine (which kept TP fixed and
   pushed SL outward). You confirmed explicitly: *"I want to have 40%/60%
   as I described... forget about risk behavior, I want the app to do what
   I want."* Worth knowing as a real consequence, not a defect: when entry
   starts very close to the fixed SL edge, this can produce an extremely
   tight take-profit target (barely above/below entry) — that's the direct,
   intended result of never moving SL, not a bug to fix later.

Also fixed in the same pass: the new-entry create path was missing the
`config.mode == EngineMode.confirm` dry-run gate that the opposite-signal
close path already had — it only checked `pionex.available`. In `confirm`
mode with real API keys configured, this would have let the engine actually
create live grids instead of logging `[CONFIRM] Would create grid`. Now both
paths share the same `isDryRun` check.

## Deliberately not ported (dead-code avoidance, not oversight)

These existed in the original `lib/technique.js` but were already confirmed
non-authoritative (PRD §13) or confirmed dead. Per the "no half-wired
features" rule, they were **not** carried forward as unused code — if you
decide to activate any of these, they should be built fresh, end-to-end, at
that point, wired into `engine_service.dart`'s decision path for real.

1. **Weighted regime** (`computeWeightedRegime`: weekly RSI 30% + daily RSI
   30% + CoinMarketCap Fear&Greed 40%, score <50 → bear). Was computed and
   logged in the original but never actually gated anything — the live
   engine always used the 1H signal + always-max leverage regardless.
   **Resolved, not just deferred:** `ALL_USER_INPUTS.txt` (2026-08-29 22:08)
   has the user stating directly — "coin market cap is not anymore
   integrated in this app." So this isn't a pending decision, it's a closed
   one: CMC/weighted-regime is out of scope, full stop. `lib/cmc-sentiment.js`
   was correctly not ported.
2. **Regime/direction leverage matrix** (bear/bull × long/short → 50%/100%
   of max leverage). The live engine always uses max leverage regardless of
   direction or market — this table was present in code but never the live
   decision. Not ported; `engine_service.dart` just always uses max.
3. **Legacy range sources** (`detectRange`: last-N MSB/OB boxes;
   `detectLabelRange`: last-N MSB labels). Explicitly superseded by the
   zigzag-20 range rule on 2026-08-29 ("remove 10 keep 20"). Not ported —
   the zigzag rule is the only range source now, with no fallback (skip the
   cycle if it yields nothing), exactly as the original ended up.
4. **`detectRegime`** (MSB "Market Trend" table / RSI >50/<50 fallback). Only
   ever fed the leverage matrix above, which isn't used. Not ported.
5. **Legacy TP/SL** (`takeProfit`/`stopLoss` returning `range.top`/`null`).
   Superseded by the 60/40 liquidation-avoidance model + opposite-signal
   close, which is fully ported. Not ported.
6. **`lib/chart.js`** (legacy UI study helpers). PRD confirms it was already
   dead ("not used by enforce"). Not ported.

## Needs live verification (transcribed faithfully, not yet run against a live TradingView session by me)

The entire CDP/TradingView layer (`lib/data/tradingview/*.dart`) was ported
1:1 from the real source, including the exact JS expression strings
evaluated inside the page. One smoke test against the actual running
TradingView Desktop on this machine already succeeded (CDP connect, watchlist
read, indicator-presence verify) — see the session this was built in. Still
worth watching closely on first real use:

- `enforce.dart`'s DOM selectors (`.title-quatTGAC`,
  `[data-qa-id=legend-delete-action]`, etc.) are exactly what the original
  used, but TradingView's own UI could shift them over time.
- The full close-all/reopen-both cycle (`enforceCustomScripts`) hasn't been
  exercised end-to-end by me — only the read/verify paths have.

## Minor note

- The transcript (2026-08-29 17:56) shows you explicitly asked to delete a
  standalone `/checknow` slash command as "duplicated" once `/start`'s
  selection flow triggered it internally. The MCP server here still exposes
  a standalone `checknow` tool alongside `select`. For a tool-calling
  interface (vs. a human-facing command list) a raw "trigger a cycle now"
  primitive has some independent utility, so I left it in — but flagging
  since it's the same duplication shape you rejected before.

## Config decisions carried over, unchanged from the original

- `technique.validate_with_checkparams` still defaults to `false` — gated
  off pending your explicit approval to point it at live Pionex validation.
- `max_grids: null` in config still falls back to the code default of 250.

## Structural

- No automated test suite beyond the one boot smoke test
  (`test/widget_test.dart`) — same as the original, which had no
  package.json test scripts either; verification here is `dart analyze` +
  `flutter build windows` (both currently clean) + manual/live checks.
