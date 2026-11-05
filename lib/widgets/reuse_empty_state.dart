import 'package:flutter/material.dart';

import '../core/core_spacing.dart';

class ReuseEmptyState extends StatelessWidget {
  const ReuseEmptyState({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
  });

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: CoreSpacing.xl),
      child: Column(
        children: [
          Icon(icon, size: 40, color: scheme.onSurfaceVariant),
          const SizedBox(height: CoreSpacing.sm),
          Text(
            message,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
