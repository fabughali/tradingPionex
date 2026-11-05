import 'package:flutter/widgets.dart';

import 'core_spacing.dart';

/// Layout helpers for wide-screen content.
///
/// Per the user (2026-09-05): cards must expand to fill the full window
/// width, not be capped to a fixed content width - only a constant margin
/// from the window edge, regardless of how wide the window is. This used to
/// grow the horizontal padding to keep content centered under a `maxWidth`
/// cap; that cap is gone, so it's always just [base] on every side now.
class CoreLayout {
  CoreLayout._();

  static EdgeInsets edgeMargin(
    BoxConstraints constraints, {
    double base = CoreSpacing.lg,
  }) => EdgeInsets.symmetric(horizontal: base, vertical: base);
}
