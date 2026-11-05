import 'package:flutter/material.dart';

import '../utilities/util_string.dart';

/// A credential field that shows a partially-masked value at rest (e.g.
/// `abcd••••••••wxyz`) instead of either the full secret or a fully-hidden
/// dot field — enough for the user to recognize *which* key is configured
/// without it being fully visible on screen. Tapping the eye icon reveals
/// the real value in an editable [TextField]; the controller always holds
/// the real value underneath, masked or not.
class MaskedSecretField extends StatefulWidget {
  const MaskedSecretField({
    super.key,
    required this.controller,
    required this.label,
  });

  final TextEditingController controller;
  final String label;

  @override
  State<MaskedSecretField> createState() => _MaskedSecretFieldState();
}

class _MaskedSecretFieldState extends State<MaskedSecretField> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    if (_revealed || widget.controller.text.isEmpty) {
      return TextField(
        controller: widget.controller,
        decoration: InputDecoration(
          labelText: widget.label,
          suffixIcon: IconButton(
            icon: const Icon(Icons.visibility_off_outlined),
            tooltip: 'Hide',
            onPressed: () => setState(() => _revealed = false),
          ),
        ),
      );
    }
    return InputDecorator(
      decoration: InputDecoration(
        labelText: widget.label,
        suffixIcon: IconButton(
          icon: const Icon(Icons.visibility_outlined),
          tooltip: 'Reveal / edit',
          onPressed: () => setState(() => _revealed = true),
        ),
      ),
      child: Text(
        UtilString.maskSecret(widget.controller.text),
        style: const TextStyle(fontFamily: 'monospace'),
      ),
    );
  }
}
