/// Small string formatting helpers used across the dashboard.
import 'package:intl/intl.dart';

class UtilString {
  UtilString._();

  static String usd(double value) => '\$${value.toStringAsFixed(2)}';

  /// Local date + 12-hour time with AM/PM, e.g. "Sep 14, 2026, 2:35 PM"
  /// (2026-09-15, per the user - shown under the P&L reset icon).
  static String dateTime12h(DateTime value) =>
      DateFormat('MMM d, y, h:mm a').format(value.toLocal());

  static String price(double value) {
    if (value >= 100) return value.toStringAsFixed(2);
    if (value >= 1) return value.toStringAsFixed(4);
    return value.toStringAsFixed(6);
  }

  static String truncate(String s, int max) =>
      s.length > max ? '${s.substring(0, max)}…' : s;

  /// Partially masks a secret for display: first/last [visible] characters
  /// shown, the rest replaced with a fixed-length run of bullets regardless
  /// of the real length (so the mask never leaks length information either).
  static String maskSecret(String value, {int visible = 4}) {
    if (value.isEmpty) return '';
    if (value.length <= visible * 2) return '•' * value.length;
    return '${value.substring(0, visible)}${'•' * 10}${value.substring(value.length - visible)}';
  }
}
