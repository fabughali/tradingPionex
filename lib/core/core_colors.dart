import 'package:flutter/material.dart';

/// Brand seed and semantic (non-Material) color tokens. Structural colors
/// (surface, outline, etc.) come from [ColorScheme.fromSeed] in core_theme.dart —
/// this file only holds the seed and the trading-specific semantics that M3
/// doesn't model (profit/loss, risk severity).
class CoreColors {
  CoreColors._();

  static const seed = Color(0xFF3762F0);

  static const profit = Color(0xFF1DB975);
  static const profitContainer = Color(0xFFD8F5E6);
  static const loss = Color(0xFFE5484D);
  static const lossContainer = Color(0xFFFBE0E0);
  static const warning = Color(0xFFE0A62B);
  static const warningContainer = Color(0xFFFBEDCB);

  static const profitDark = Color(0xFF3DDC97);
  static const profitContainerDark = Color(0xFF0F3D2A);
  static const lossDark = Color(0xFFFF6B6F);
  static const lossContainerDark = Color(0xFF4A1113);
  static const warningDark = Color(0xFFF2C155);
  static const warningContainerDark = Color(0xFF4A3607);
}
