import 'package:flutter/animation.dart';

/// Shared motion tokens so transitions feel consistent across screens.
class CoreAnimations {
  CoreAnimations._();

  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 360);

  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeOutQuint;
}
