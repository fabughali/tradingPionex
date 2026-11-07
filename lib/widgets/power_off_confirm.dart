import 'package:flutter/material.dart';

/// Asks before Power goes off (2026-11-01, v1.6.59, per the user: "the
/// confirmation need the long press of 5 Seconds but cancel can be one
/// click"). At 15:22 that day Power went off and the window closed about 2.5s
/// after a RustDesk session opened, with 12 trades running and nobody meaning
/// to. Only a full hold says yes: a tap outside the dialog dismisses it, and
/// that means keep running.
Future<bool> confirmPowerOff(BuildContext context, {required bool closingApp}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.power_settings_new),
      title: Text(closingApp ? 'Close the app and stop trading?' : 'Turn Power off?'),
      content: const Text(
        'The engine stops. Running bots stay open on Pionex, but signal closes '
        'and stop-loss management will not run until Power is on again.',
      ),
      actions: [
        _HoldToConfirmButton(
          label: closingApp ? 'Hold 5s to close and stop' : 'Hold 5s to turn off',
          onConfirmed: () => Navigator.of(context).pop(true),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep running'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Fires [onConfirmed] once a press has been held for [holdDuration]; letting
/// go earlier resets it. Uses raw pointer events so any held mouse button or
/// touch counts, whichever a remote-desktop client sends.
class _HoldToConfirmButton extends StatefulWidget {
  const _HoldToConfirmButton({required this.label, required this.onConfirmed});

  static const holdDuration = Duration(seconds: 5);

  final String label;
  final VoidCallback onConfirmed;

  @override
  State<_HoldToConfirmButton> createState() => _HoldToConfirmButtonState();
}

class _HoldToConfirmButtonState extends State<_HoldToConfirmButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: _HoldToConfirmButton.holdDuration,
  )..addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onConfirmed();
    });

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  void _reset() {
    if (!_hold.isCompleted) _hold.reset();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Listener(
      onPointerDown: (_) => _hold.forward(from: 0),
      onPointerUp: (_) => _reset(),
      onPointerCancel: (_) => _reset(),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: AnimatedBuilder(
          animation: _hold,
          builder: (context, _) => Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: LinearProgressIndicator(
                  value: _hold.value,
                  backgroundColor: colors.errorContainer,
                  color: colors.error.withValues(alpha: 0.5),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Text(widget.label, style: TextStyle(color: colors.onErrorContainer)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
