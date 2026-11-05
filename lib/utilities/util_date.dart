/// Date/time formatting helpers used across the dashboard/logs screens.
class UtilDate {
  UtilDate._();

  static String relative(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 5) return 'just now';
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  static String hms(DateTime time) {
    final hour12 = time.hour % 12 == 0 ? 12 : time.hour % 12;
    final period = time.hour < 12 ? 'AM' : 'PM';
    return '${hour12.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')} $period';
  }

  /// Full local date + time, e.g. `2026-08-31 17:58:32` — for "last login"
  /// style timestamps where the exact moment matters, not just "how long ago".
  static String dateTime(DateTime time) {
    final local = time.toLocal();
    final date =
        '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    return '$date ${hms(local)}';
  }
}
