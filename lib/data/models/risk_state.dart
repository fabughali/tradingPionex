/// Persisted risk-manager state (logs/state.json equivalent). The original
/// engine reset day counters at LOCAL midnight despite its own docs claiming
/// UTC — a doc/code mismatch. This app resolves that explicitly: day
/// boundaries are UTC midnight, deterministic regardless of machine timezone.
///
/// `dayPnlPct`/`cooldownUntilMs` removed 2026-09-15, per the user ("remove
/// all i dont need anything in the code where it is not functioning") -
/// both only ever existed to support the daily-loss-limit/cooldown gate in
/// `RiskGate`, which depended on `RiskGate.recordPnl()` to update
/// `dayPnlPct` - `recordPnl()` had zero callers anywhere in the codebase,
/// so that gate could never actually trip. Removed together as one dead
/// feature rather than left half-wired.
class RiskState {
  RiskState({required this.dayStartUtcMs, Map<String, int>? openPositions})
    : openPositions = openPositions ?? {};

  int dayStartUtcMs;
  final Map<String, int> openPositions;

  int get totalOpenPositions => openPositions.values.fold(0, (a, b) => a + b);

  static int utcMidnightMs(DateTime now) => DateTime.utc(
    now.toUtc().year,
    now.toUtc().month,
    now.toUtc().day,
  ).millisecondsSinceEpoch;

  factory RiskState.freshForToday() =>
      RiskState(dayStartUtcMs: utcMidnightMs(DateTime.now()));

  factory RiskState.fromJson(Map<String, dynamic> json) => RiskState(
    dayStartUtcMs:
        (json['day_start'] as num?)?.toInt() ?? utcMidnightMs(DateTime.now()),
    openPositions: ((json['open_positions'] as Map?) ?? const {}).map(
      (k, v) => MapEntry(k as String, (v as num).toInt()),
    ),
  );

  Map<String, dynamic> toJson() => {
    'day_start': dayStartUtcMs,
    'open_positions': openPositions,
  };
}
