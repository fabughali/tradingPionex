/// Grid count — per the user's original spec (ALL_USER_INPUTS.txt,
/// 2026-08-20): start at the minimum, then keep increasing the grid count,
/// checking with Pionex each time whether the investment still covers it,
/// and take the highest count that still validates.
///
/// REVERTED 2026-09-14 to a genuine linear scan, per the user, explicit and
/// deliberate: "the try should start from 3 then 4 then 5 then 6 until
/// pionex reply (budget not cover) ... if you try 7 and pionex reply budget
/// is not cover, you apply 6." A binary search (tried in between) finds the
/// exact same final row - Pionex's validation is monotonic in row count, a
/// higher count only ever needs MORE per-grid margin, never less, so there
/// is exactly one accept/reject boundary either method converges on - but
/// the user chose the linear, one-at-a-time version anyway. Flagged once,
/// explicitly: for a pair whose true max is high (e.g. 150+), this can cost
/// 150+ Pionex `checkParams` calls for a single grid open, against binary
/// search's ~8 - real exposure to this app's own rate-limit circuit
/// breaker. Accepted by the user regardless.
///
/// Returns [minGrids] unmodified if even the minimum doesn't validate —
/// never goes below the floor; the caller's own create-time shrink-retry
/// handles a genuinely-too-small investment.
///
/// Second reversal, same day, per the user: "row.. keep it 3" / "always" -
/// stop searching upward entirely, every open always uses the floor row
/// (`minGrids`, currently 3). Still calls [checkRowValid] once at
/// [minGrids] - every call site relies on its side effect (capturing the
/// checkParams response used for the investment/extraMargin split) - it
/// just never searches upward from there any more.
Future<int> probeMaxGridCount({
  required int minGrids,
  required int maxGrids,
  required Future<bool> Function(int candidate) checkRowValid,
}) async {
  await checkRowValid(minGrids);
  return minGrids;
}
