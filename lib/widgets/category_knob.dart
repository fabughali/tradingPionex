import 'package:flutter/material.dart';

import '../data/models/auto_category.dart';

/// The per-pair "knob": a segmented control (1H/1D, trimmed down from a
/// 5-way 1m/5m/15m/1H/1D control on 2026-09-30) letting the user pick
/// which Auto engine a pair belongs to (2026-09-07) - used on the
/// Next Trade table (Dashboard + Controls), the Controls screen's single-pair
/// Check card, and the manual-bot "convert to auto" prompt.
///
/// Same pill-shaped/divided look as the original `SegmentedButton` (per the
/// user, 2026-09-09: keep the old design) - hand-built only because
/// `SegmentedButton` has no per-segment background hook, and a segment
/// blocked or missing data for this pair needs its own background.
class CategoryKnob extends StatelessWidget {
  const CategoryKnob({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.unavailable = const {},
    this.blocked = const {},
  });

  final AutoCategory value;
  final ValueChanged<AutoCategory> onChanged;
  final bool enabled;

  /// Categories the app can't pull data for right now (no live signal from
  /// TradingView/Pionex for this pair) - their segment gets a RED
  /// background (2026-09-11, per the user - was amber; split out from
  /// [blocked] so the two distinct reasons a segment can't be used read as
  /// two distinct colors).
  final Set<AutoCategory> unavailable;

  /// Categories that already have a running auto bot for this EXACT pair
  /// (2026-09-11, per the user's rule: a pair can only have one running
  /// auto bot per interval - XRPUSDT/1m already running blocks starting
  /// XRPUSDT/1m again, but never blocks XRPUSDT/1H or XRPUSDT/1D). Their
  /// segment gets a YELLOW background - distinct from [unavailable]'s red
  /// ("no data"), since this is a real, selectable timeframe the app is
  /// simply already managing.
  final Set<AutoCategory> blocked;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 32,
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outline),
        borderRadius: const BorderRadius.all(Radius.circular(999)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        // Without this, each segment/divider only takes its own text's
        // intrinsic height and gets centered as a block within the pill -
        // stretching them to the full 32px height first, then centering
        // the label text inside that (via each segment's own
        // `alignment: Alignment.center`), is what actually guarantees
        // pixel-true vertical centering.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final c in allAutoCategories) ...[
            if (c != allAutoCategories.first)
              VerticalDivider(width: 1, thickness: 1, color: scheme.outline),
            _segment(context, scheme, c),
          ],
        ],
      ),
    );
  }

  Widget _segment(BuildContext context, ColorScheme scheme, AutoCategory c) {
    final selected = c == value;
    final isBlocked = blocked.contains(c);
    final noData = !isBlocked && unavailable.contains(c);
    final Color background;
    final Color foreground;
    if (isBlocked) {
      background = selected
          ? Colors.amber.shade700
          : Colors.amber.shade700.withValues(alpha: 0.25);
      foreground = selected ? Colors.black : Colors.amber.shade300;
    } else if (noData) {
      background = selected
          ? Colors.red.shade700
          : Colors.red.shade700.withValues(alpha: 0.25);
      foreground = selected ? Colors.white : Colors.red.shade300;
    } else if (selected) {
      background = scheme.secondaryContainer;
      foreground = scheme.onSecondaryContainer;
    } else {
      background = Colors.transparent;
      foreground = scheme.onSurfaceVariant;
    }
    // The hover/press highlight needs its OWN matching corner radius - left
    // undone, InkWell clips its ripple to a plain rectangle regardless of
    // the outer pill's rounded ends, so on the first/last segment the
    // highlight visibly overshoots past the border before the outer clip
    // cuts it off, looking like it doesn't match the pill shape.
    const pillRadius = Radius.circular(999);
    final isFirst = c == allAutoCategories.first;
    final isLast = c == allAutoCategories.last;
    final radius = BorderRadius.only(
      topLeft: isFirst ? pillRadius : Radius.zero,
      bottomLeft: isFirst ? pillRadius : Radius.zero,
      topRight: isLast ? pillRadius : Radius.zero,
      bottomRight: isLast ? pillRadius : Radius.zero,
    );
    return InkWell(
      borderRadius: radius,
      onTap: enabled ? () => onChanged(c) : null,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(color: background, borderRadius: radius),
        child: Text(c.label, style: TextStyle(color: foreground, fontSize: 12)),
      ),
    );
  }
}

/// A blocking picker for the "convert manual bot(s) to auto" flow (2026-09-07,
/// per the user: "same practice, user need to choose (1m, 1H, 1D)") - returns
/// null if the user backs out, in which case the caller must not convert
/// anything.
Future<AutoCategory?> showCategoryPickerDialog(
  BuildContext context, {
  String title = 'Choose a category',
  AutoCategory initial = AutoCategory.oneHour,
}) {
  var selected = initial;
  return showDialog<AutoCategory>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Which Auto engine should manage this? Each runs on its own '
              'schedule and range timeframe (1m/1H, 1H/1D, 1D/1W).',
            ),
            const SizedBox(height: 16),
            CategoryKnob(
              value: selected,
              onChanged: (c) => setState(() => selected = c),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(selected),
            child: const Text('Convert'),
          ),
        ],
      ),
    ),
  );
}
