import 'package:flutter/material.dart';

enum ReuseChipTone { neutral, success, danger, warning }

/// A small status pill — used for grid status (running/paused), app vs
/// manual origin, and engine health.
class ReuseChip extends StatelessWidget {
  const ReuseChip({
    super.key,
    required this.label,
    this.tone = ReuseChipTone.neutral,
  });

  final String label;
  final ReuseChipTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (tone) {
      ReuseChipTone.neutral => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      ReuseChipTone.success => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      ReuseChipTone.danger => (scheme.errorContainer, scheme.onErrorContainer),
      ReuseChipTone.warning => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
