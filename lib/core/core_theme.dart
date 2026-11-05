import 'package:flutter/material.dart';

import 'core_colors.dart';

/// Trading-specific semantic colors (profit/loss/warning) exposed as a
/// [ThemeExtension] so they respect light/dark mode the same way the rest of
/// the M3 [ColorScheme] does. Access via `Theme.of(context).extension<TradingColors>()!`.
@immutable
class TradingColors extends ThemeExtension<TradingColors> {
  const TradingColors({
    required this.profit,
    required this.profitContainer,
    required this.loss,
    required this.lossContainer,
    required this.warning,
    required this.warningContainer,
  });

  final Color profit;
  final Color profitContainer;
  final Color loss;
  final Color lossContainer;
  final Color warning;
  final Color warningContainer;

  static const light = TradingColors(
    profit: CoreColors.profit,
    profitContainer: CoreColors.profitContainer,
    loss: CoreColors.loss,
    lossContainer: CoreColors.lossContainer,
    warning: CoreColors.warning,
    warningContainer: CoreColors.warningContainer,
  );

  static const dark = TradingColors(
    profit: CoreColors.profitDark,
    profitContainer: CoreColors.profitContainerDark,
    loss: CoreColors.lossDark,
    lossContainer: CoreColors.lossContainerDark,
    warning: CoreColors.warningDark,
    warningContainer: CoreColors.warningContainerDark,
  );

  @override
  TradingColors copyWith({
    Color? profit,
    Color? profitContainer,
    Color? loss,
    Color? lossContainer,
    Color? warning,
    Color? warningContainer,
  }) {
    return TradingColors(
      profit: profit ?? this.profit,
      profitContainer: profitContainer ?? this.profitContainer,
      loss: loss ?? this.loss,
      lossContainer: lossContainer ?? this.lossContainer,
      warning: warning ?? this.warning,
      warningContainer: warningContainer ?? this.warningContainer,
    );
  }

  @override
  TradingColors lerp(ThemeExtension<TradingColors>? other, double t) {
    if (other is! TradingColors) return this;
    return TradingColors(
      profit: Color.lerp(profit, other.profit, t)!,
      profitContainer: Color.lerp(profitContainer, other.profitContainer, t)!,
      loss: Color.lerp(loss, other.loss, t)!,
      lossContainer: Color.lerp(lossContainer, other.lossContainer, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningContainer: Color.lerp(
        warningContainer,
        other.warningContainer,
        t,
      )!,
    );
  }
}

extension TradingColorsX on BuildContext {
  TradingColors get tradingColors => Theme.of(this).extension<TradingColors>()!;
}

/// Builds the app's Material 3 light/dark themes from a single seed color.
class CoreTheme {
  CoreTheme._();

  static ThemeData light() => _build(Brightness.light, TradingColors.light);
  static ThemeData dark() => _build(Brightness.dark, TradingColors.dark);

  static ThemeData _build(Brightness brightness, TradingColors tradingColors) {
    final scheme = ColorScheme.fromSeed(
      seedColor: CoreColors.seed,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: scheme.surface,
      extensions: [tradingColors],
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
        surfaceTintColor: scheme.surfaceTint,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainerLow,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
