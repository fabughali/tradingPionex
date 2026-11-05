import 'package:flutter/material.dart';

import '../core/core_theme.dart';

/// A small "alive" indicator - lazy-blinking green while [alive] is true,
/// static grey once it's false (2026-09-11, per the user: a green circle
/// before the Auto bots title that blinks "as if auto bot alive," stopping
/// (and turning grey) only once there is no auto bot running).
class PulsingDot extends StatefulWidget {
  const PulsingDot({super.key, required this.alive, this.size = 10});

  final bool alive;
  final double size;

  @override
  State<PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant PulsingDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.alive != oldWidget.alive) _syncAnimation();
  }

  void _syncAnimation() {
    if (widget.alive) {
      _controller.repeat(reverse: true);
    } else {
      _controller.stop();
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final trading = context.tradingColors;
    final color = widget.alive ? trading.profit : Colors.grey;
    return FadeTransition(
      opacity: Tween<double>(
        begin: 0.25,
        end: 1,
      ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}
