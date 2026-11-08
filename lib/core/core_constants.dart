/// App-wide constants. Anything the user might reasonably want to change
/// lives in config.json instead (see data/models/app_config.dart) â€” this file
/// is for values that are structural, not user preference.
class CoreConstants {
  CoreConstants._();

  static const String appName = 'TradingPionex';

  /// Shown in Settings â†’ About and logged by the engine at start. Must equal
  /// `version:` in pubspec.yaml (test/app_version_test.dart enforces it), and
  /// every release must change it: the Windows build refuses to publish a
  /// version that is already released.
  static const String appVersion = '1.0.28+29';

  // Mirrors bot-grid.js's MAINLOOP WATCHDOG: a stuck cycle is force-aborted
  // past this ceiling so the engine never wedges itself permanently.
  /// Check Now's trending list (technique/trending.dart): Pionex USDT perps
  /// with at least this much 24h turnover, the biggest 24h movers first,
  /// capped at [trendingMaxPairs] (each pair takes ~40s of chart time).
  static const double trendingMinTurnoverUsdt = 1000000;
  static const int trendingMaxPairs = 20;

  static const Duration mainLoopWatchdog = Duration(seconds: 600);

  // Per the user (2026-09-05): while Power is on, the app must keep
  // checking TradingView is up and both custom indicators are attached on
  // its own, continuously - not just once, and not just on failure. This
  // drives that recurring check (and dismisses any upgrade dialog).
  static const Duration indicatorVerifyInterval = Duration(seconds: 5);

  static const Duration heartbeatTick = Duration(minutes: 1);

  // How long a freshly-created grid bot is actively polled for a confirmed
  // RUNNING status before the app stops polling and leaves it to the
  // normal reconciliation loop - never cancelled/forgotten locally just
  // for taking longer than this (2026-09-15, per the user: no local
  // action without real feedback from Pionex).
  static const Duration gridPrepareTimeout = Duration(seconds: 60);
  static const Duration gridPreparePoll = Duration(seconds: 5);

  static const int maxShrinkRetries = 12;
  static const double stableLiquidationFraction = 0.60;

  static const Duration pionexRequestTimeout = Duration(seconds: 15);
  static const Duration cdpRequestTimeout = Duration(seconds: 60);
  static const Duration cdpJsonListTimeout = Duration(seconds: 10);
  static const Duration cdpConnectTimeout = Duration(seconds: 10);

  static const String cmcFearGreedUrl =
      'https://pro-api.coinmarketcap.com/public-api/v3/fear-and-greed/latest';
  static const Duration cmcRequestTimeout = Duration(seconds: 8);
}
