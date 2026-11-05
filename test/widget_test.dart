// Smoke test: the app boots to the splash screen without throwing.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:trading_pionex/main.dart';
import 'package:trading_pionex/screens/app/splash_screen.dart';

void main() {
  testWidgets('App boots to the splash screen', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: TradingPionexApp()));
    await tester.pump();

    // Was `find.byIcon(Icons.candlestick_chart)` - stale since the splash
    // screen was redesigned to use `assets/logo.png` instead of an icon
    // (2026-10-20, found while testing: that icon no longer appears
    // anywhere in lib/, so this assertion could never pass regardless of
    // app health). Checking for the SplashScreen widget itself is robust
    // to any future visual redesign.
    expect(find.byType(SplashScreen), findsOneWidget);
  });
}
