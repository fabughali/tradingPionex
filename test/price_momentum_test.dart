import 'package:flutter_test/flutter_test.dart';
import 'package:trading_pionex/data/pionex/price_momentum.dart';

void main() {
  final t0 = DateTime(2026, 11, 9, 10);

  test('gives the 24h % one hour ago and now for each pair', () {
    final m = PriceMomentum()
      ..add(t0, {'A': 2.5, 'B': 4})
      ..add(t0.add(const Duration(minutes: 30)), {'A': 6, 'B': 1})
      ..add(t0.add(const Duration(minutes: 59)), {'A': 9, 'B': -3});
    final r = m.readings();
    expect(r['A'], (then: 2.5, now: 9.0));
    expect(r['B'], (then: 4.0, now: -3.0));
    expect(m.span, const Duration(minutes: 59));
  });

  test('drops readings older than one hour', () {
    final m = PriceMomentum()
      ..add(t0, {'A': 1})
      ..add(t0.add(const Duration(minutes: 30)), {'A': 2})
      ..add(t0.add(const Duration(minutes: 61)), {'A': 3});
    expect(m.readings()['A'], (then: 2.0, now: 3.0));
  });

  test('needs two readings', () {
    final m = PriceMomentum()..add(t0, {'A': 1});
    expect(m.readings(), isEmpty);
  });

  test('saves and restores, dropping stale snapshots', () {
    final m = PriceMomentum();
    for (var s = 0; s <= 600; s += 5) {
      m.add(t0.add(Duration(seconds: s)), {'A': s / 10});
    }
    final restored = PriceMomentum()
      ..loadJson(m.toJson(), t0.add(const Duration(minutes: 20)));
    expect(restored.readings()['A'], m.readings()['A']);
    final stale = PriceMomentum()
      ..loadJson(m.toJson(), t0.add(const Duration(hours: 2)));
    expect(stale.isEmpty, isTrue);
  });
}
