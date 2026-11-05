import 'package:flutter/material.dart';

import '../core/core_spacing.dart';

/// Consistent page padding/max-width/scroll behavior for every top-level
/// screen — a wide desktop window still reads comfortably instead of
/// stretching cards edge-to-edge.
class ReuseScreenWrapper extends StatelessWidget {
  const ReuseScreenWrapper({
    super.key,
    required this.title,
    required this.children,
    this.actions,
  });

  final String title;
  final List<Widget> children;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: ListView(
            padding: const EdgeInsets.all(CoreSpacing.lg),
            children: children,
          ),
        ),
      ),
    );
  }
}
