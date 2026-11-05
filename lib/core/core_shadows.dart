import 'package:flutter/material.dart';

/// Elevation shadow tokens. M3 leans on tonal elevation (surfaceTint) more
/// than drop shadows, so these are only used for a few floating surfaces
/// that need to lift off busy dashboard backgrounds.
class CoreShadows {
  CoreShadows._();

  static List<BoxShadow> low(Color shadowColor) => [
    BoxShadow(
      color: shadowColor.withValues(alpha: 0.08),
      blurRadius: 4,
      offset: const Offset(0, 1),
    ),
  ];

  static List<BoxShadow> medium(Color shadowColor) => [
    BoxShadow(
      color: shadowColor.withValues(alpha: 0.12),
      blurRadius: 12,
      offset: const Offset(0, 4),
    ),
  ];
}
