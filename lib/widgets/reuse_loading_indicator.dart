import 'package:flutter/material.dart';

import '../core/core_spacing.dart';

class ReuseLoadingIndicator extends StatelessWidget {
  const ReuseLoadingIndicator({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: CoreSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            if (message != null) ...[
              const SizedBox(height: CoreSpacing.sm),
              Text(message!),
            ],
          ],
        ),
      ),
    );
  }
}
