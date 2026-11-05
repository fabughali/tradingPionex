import 'package:flutter/material.dart';

import '../core/core_spacing.dart';

class ReuseError extends StatelessWidget {
  const ReuseError({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: CoreSpacing.xl),
      child: Column(
        children: [
          Icon(Icons.error_outline, size: 40, color: scheme.error),
          const SizedBox(height: CoreSpacing.sm),
          Text(
            message,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          if (onRetry != null) ...[
            const SizedBox(height: CoreSpacing.sm),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ],
      ),
    );
  }
}
