/// The Auto engine - 1H only, same as tradingMT5 (2026-11-07, per the user:
/// "match MT5"; 1D removed). Kept as an enum so every loop over
/// [allAutoCategories] stays generic.
enum AutoCategory { oneHour }

extension AutoCategoryX on AutoCategory {
  /// Short display tag shown after a pair name wherever an auto bot from
  /// this category appears (e.g. "ETHUSDT (1H)").
  String get label => switch (this) {
    AutoCategory.oneHour => '1H',
  };

  /// Stable identifier used in file names and persisted JSON - never the
  /// display [label], which could change wording without warning.
  String get wireValue => switch (this) {
    AutoCategory.oneHour => 'ONE_HOUR',
  };

  /// TradingView chart resolution this category reads its BUY/SELL signal
  /// from - matches its own cadence (per the user, 2026-09-07: "signal
  /// matches cadence").
  String get signalResolution => switch (this) {
    AutoCategory.oneHour => '60',
  };

  /// TradingView chart resolution this category computes its MSB/OB price
  /// range from - "one level above [signalResolution]" (1H->1D, 1D->1W).
  String get rangeResolution => switch (this) {
    AutoCategory.oneHour => 'D',
  };

  /// Real wall-clock cadence between this category's own candle boundaries -
  /// the single source of truth [EngineControlRepository.nextCheckupEtaFor]
  /// adds to the last real candle time to predict the next one.
  ///
  /// Bug fixed 2026-09-12, per the user ("why there is no count down in
  /// auto 3m toggle (it is walys showing any moment)"): `nextCheckupEtaFor`
  /// still hardcoded `Duration(minutes: 1)` for this category, a leftover
  /// from before the 3m re-timing (see [label]'s note) - since the real
  /// candle boundary is 3 minutes apart now but the ETA was computed as
  /// only 1 minute past the last one, the predicted time was almost always
  /// already in the past by the time anyone looked at it, so the countdown
  /// widget (which treats a past ETA as "due any moment") never showed a
  /// real countdown at all. `_candleBoundary` in engine_service.dart (the
  /// engine's own gating logic) already used the correct 3-minute floor
  /// independently and was never affected by this - only the GUI's
  /// separate ETA-prediction math was stale.
  Duration get candlePeriod => switch (this) {
    AutoCategory.oneHour => const Duration(hours: 1),
  };

  /// The one symbol this category's own rotating "which sweep was this pair
  /// checked in" marker is built from (2026-09-12, per the user - see
  /// `AutoCategoryStatus.cycleMarkerIndex`'s doc for the full feature).
  /// Each category gets its OWN distinct symbol, never shared with another
  /// category's, specifically so two categories' markers can never look
  /// identical even if their rotation happens to land on the same count at
  /// the same time - per the user: "never choose icon/emoji/star that
  /// matches with other toggle."
  String get cycleMarkerSymbol => switch (this) {
    AutoCategory.oneHour => '●',
  };

  /// The actual marker text for rotation position [index] (0/1/2, wrapping)
  /// - the symbol repeated once/twice/three times, per the user's own
  /// suggestion ("* in first interval, ** in next, *** in next, * in
  /// next"). The `% 3` here is the rotation's own fixed period (how many
  /// times a single category repeats before cycling back to one symbol),
  /// unrelated to how many AutoCategory values exist.
  String cycleMarkerFor(int index) =>
      cycleMarkerSymbol * ((index % 3) + 1);
}

AutoCategory? autoCategoryFromWire(String? value) => switch (value) {
  'ONE_HOUR' => AutoCategory.oneHour,
  _ => null,
};

const allAutoCategories = AutoCategory.values;
