import '../technique/worm10_decision.dart';
import 'grid_bot.dart';

/// What a pair's currently-open (or just-confirmed, in dry-run) position was
/// entered on — records the direction/time/price to detect the opposite-
/// signal close later, plus which exact bot id it targets (the same-id close
/// guard, PRD §10 rule 4). In-memory only; resets on engine restart (fully
/// re-derivable from Pionex + brain/trades.jsonl, same as the original).
class OpenEntry {
  const OpenEntry({
    required this.direction,
    required this.entryTime,
    required this.entryPrice,
    required this.investment,
    this.buOrderId,
    this.openEventType,
    this.openEventTime,
  });

  final GridDirection direction;
  final int entryTime;
  final double entryPrice;
  final double investment;
  final String? buOrderId;

  /// Worm10 Hybrid Decision technique (2026-10-25) - which exact event
  /// type opened this trade, alongside [entryTime] for its bar time.
  /// Needed because two DIFFERENT event types can legitimately share the
  /// same bar time (e.g. an LL and a zigzag BUY run both starting on the
  /// same bar) - `entryTime` alone can't uniquely identify "the exact
  /// event that opened this trade" the way the spec's "a recycle or flip
  /// is ignored if it's the same event that opened the current trade"
  /// rule needs. Null for any entry not opened by this technique (an
  /// adopted bot, or one opened before this field existed) - treated as
  /// "never matches," same as any other unset identity check.
  final Worm10EventType? openEventType;

  /// The bar time of [openEventType] when the retroactive audit has corrected
  /// the record; [entryTime] stays the trade's real start. Null means the event
  /// is the one at [entryTime].
  final int? openEventTime;

  /// Whether [event] is the exact event recorded as having opened this trade.
  bool openedBy(Worm10Event event) =>
      openEventType == event.type && (openEventTime ?? entryTime) == event.time;

  OpenEntry copyWith({
    String? buOrderId,
    Worm10EventType? openEventType,
    int? openEventTime,
  }) => OpenEntry(
    direction: direction,
    entryTime: entryTime,
    entryPrice: entryPrice,
    investment: investment,
    buOrderId: buOrderId ?? this.buOrderId,
    openEventType: openEventType ?? this.openEventType,
    openEventTime: openEventTime ?? this.openEventTime,
  );
}
