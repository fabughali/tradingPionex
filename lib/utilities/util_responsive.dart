import 'package:flutter/material.dart';

/// Breakpoints and small helpers for adapting layout to window size — this
/// app runs as a desktop window (and, later, mobile), so both a narrow phone
/// width and a wide desktop window need sane behavior.
class UtilResponsive {
  UtilResponsive._();

  static const double compactMaxWidth = 600;
  static const double mediumMaxWidth = 1000;

  static bool isCompact(BuildContext context) =>
      MediaQuery.sizeOf(context).width < compactMaxWidth;
  static bool isMedium(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return w >= compactMaxWidth && w < mediumMaxWidth;
  }

  static bool isExpanded(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= mediumMaxWidth;
}
