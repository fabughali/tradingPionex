import 'dart:async';

import 'package:flutter/material.dart';

/// Ticks once a second to show a live "time remaining" countdown. Used for
/// "time until next checkup" — an estimate, not a guarantee: the engine
/// anchors to the chart's own candle open time, not the wall clock, so a
/// slow/late TradingView read can push the real checkup a little later than
/// this shows.
class CountdownText extends StatefulWidget {
  const CountdownText({
    super.key,
    required this.target,
    this.style,
    this.whenPast = 'any moment now',
  });

  final DateTime? target;
  final TextStyle? style;
  final String whenPast;

  @override
  State<CountdownText> createState() => _CountdownTextState();
}

class _CountdownTextState extends State<CountdownText> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final target = widget.target;
    if (target == null) return Text('—', style: widget.style);
    final remaining = target.difference(DateTime.now());
    if (remaining.isNegative) return Text(widget.whenPast, style: widget.style);
    final h = remaining.inHours;
    final m = remaining.inMinutes % 60;
    final s = remaining.inSeconds % 60;
    final text = h > 0
        ? '${h}h ${m.toString().padLeft(2, '0')}m ${s.toString().padLeft(2, '0')}s'
        : '${m}m ${s.toString().padLeft(2, '0')}s';
    return Text(text, style: widget.style);
  }
}
