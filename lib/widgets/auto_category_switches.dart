import 'package:flutter/material.dart';

import '../core/core_spacing.dart';
import '../data/models/auto_category.dart';
import '../data/models/engine_status.dart';
import 'countdown_text.dart';

/// The independent Auto-engine switches (one per AutoCategory), each with
/// its own on/off state and status line - per the user (2026-09-07): "each
/// category has its own engine and toggle switch and status". Sits below
/// the master Auto switch. Per the user (2026-09-09, corrected same day):
/// these rows must always stay visible (never disappear when Power/Auto is
/// off), AND must always keep showing their own REAL saved on/off state -
/// the master switch never flips what a row visually shows, in either
/// direction ("switching on auto should not toggle 1m/1H/1D to become
/// on... it does not mean it should become on"; "once auto becomes off, it
/// should not toggle 1m/1H/1D to become off"). The master switch only gates
/// whether a row is *clickable* right now - turning master Auto on allows
/// whichever categories are already on to actually run; turning it off
/// (or Power off) just disables the rows without touching what they show.
///
/// Reverted 2026-09-19, per the user, back to one full-width row per
/// category stacked vertically ("i wat toggle 3m to be at top, then 5m
/// below it, 15m below it, 1H below it, 1d below it. and each toggle
/// status is next to it") - a same-day "compact Wrap" redesign (several
/// categories side by side, status lines listed separately below) was
/// explicitly rejected: "why you change the design" / "they were below
/// each other". Each category's label, cycle marker, switch, and its own
/// status/countdown live together in one row again.
class AutoCategorySwitches extends StatelessWidget {
  const AutoCategorySwitches({
    super.key,
    required this.engineStatus,
    required this.nextCheckupEtaFor,
    required this.busy,
    required this.masterActive,
    required this.onToggle,
  });

  final EngineStatus engineStatus;
  final DateTime? Function(AutoCategory) nextCheckupEtaFor;
  final bool busy;

  /// Whether the master Auto switch is genuinely on right now (Power is on
  /// AND Auto isn't paused) - not just whether it's visually checked.
  final bool masterActive;
  final void Function(AutoCategory category, bool turnOn) onToggle;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final c in allAutoCategories)
          Padding(
            padding: const EdgeInsets.only(top: CoreSpacing.xs),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Text(c.label, style: textTheme.labelLarge),
                ),
                // Current rotating cycle marker (2026-09-12, per the user:
                // "each time this interval occurs, new emoji/icon... this
                // will help user to identify and assure if all list get
                // checked in this interval or not") - compare this against
                // the same symbol shown next to a pair's name in the Auto
                // bots table to tell whether that row was covered in the
                // CURRENT sweep or an older one.
                SizedBox(
                  width: 36,
                  child: Text(
                    c.cycleMarkerFor(engineStatus.statusFor(c).cycleMarkerIndex),
                    style: textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.clip,
                  ),
                ),
                const SizedBox(width: CoreSpacing.sm),
                Switch(
                  // Always the row's own real saved state - never forced
                  // to false just because the master switch is off.
                  value: engineStatus.statusFor(c).enabled,
                  onChanged: (busy || !masterActive)
                      ? null
                      : (v) => onToggle(c, v),
                ),
                const SizedBox(width: CoreSpacing.xs),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (engineStatus.statusFor(c).message.isNotEmpty)
                        Text(
                          engineStatus.statusFor(c).message,
                          style: textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      if (engineStatus.statusFor(c).enabled)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Next: ',
                              style: textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            CountdownText(
                              target: nextCheckupEtaFor(c),
                              style: textTheme.bodySmall,
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
