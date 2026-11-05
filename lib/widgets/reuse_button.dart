import 'package:flutter/material.dart';

enum ReuseButtonTone { primary, danger, neutral }

/// A filled action button with a built-in loading spinner state — used for
/// every control action (pause/resume/checknow/stop) so a slow file write or
/// Pionex round-trip can't be double-tapped.
class ReuseButton extends StatelessWidget {
  const ReuseButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.tone = ReuseButtonTone.primary,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final ReuseButtonTone tone;
  final bool loading;

  /// Every `ReuseButton` in the app renders at this fixed height (2026-09-09,
  /// per the user - "unified design... centralised and clean code"), so it
  /// always lines up with a `Switch` next to it (Refresh beside the Power
  /// switch) and with every other action button on screen (Check now,
  /// Start selected, Controls' pair Check button) with no per-call-site
  /// wrapping required. Matches `Switch`'s own default tap-target height
  /// (`kMinInteractiveDimension`).
  static const double unifiedHeight = 48;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (tone) {
      ReuseButtonTone.primary => (scheme.primary, scheme.onPrimary),
      ReuseButtonTone.danger => (scheme.error, scheme.onError),
      ReuseButtonTone.neutral => (
        scheme.surfaceContainerHighest,
        scheme.onSurface,
      ),
    };
    return FilledButton.icon(
      onPressed: loading ? null : onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: background,
        foregroundColor: foreground,
        minimumSize: const Size(0, unifiedHeight),
      ),
      icon: loading
          ? const SizedBox(
              width: 16,
              height: 16,
              // Per the user (2026-09-10): Start's spinner must look the
              // same as Check now's - always white regardless of tone,
              // rather than `foreground` (which varied: neutral's
              // onSurface read as white already, but primary's onPrimary
              // did not, so Start's own spinner looked different).
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : Icon(icon ?? Icons.arrow_forward, size: 18),
      label: Text(label),
    );
  }
}
