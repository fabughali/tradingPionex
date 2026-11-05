import 'package:flutter/material.dart';

/// Text styles beyond the standard M3 [TextTheme] scale — used for prices,
/// log lines and other tabular/monospace content where digit alignment matters.
class CoreTypography {
  CoreTypography._();

  static const _mono = 'monospace';

  static TextStyle price(TextTheme base, {required Color color}) => base
      .headlineSmall!
      .copyWith(fontFamily: _mono, fontWeight: FontWeight.w600, color: color);

  static TextStyle priceSmall(TextTheme base, {required Color color}) => base
      .titleMedium!
      .copyWith(fontFamily: _mono, fontWeight: FontWeight.w600, color: color);

  static TextStyle logLine(TextTheme base, {required Color color}) =>
      base.bodySmall!.copyWith(fontFamily: _mono, color: color, height: 1.4);
}
