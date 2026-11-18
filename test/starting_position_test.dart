import 'package:flutter_test/flutter_test.dart';
import 'package:trading_pionex/data/models/grid_bot.dart';
import 'package:trading_pionex/data/technique/liquidation.dart';

void main() {
  test('short opened in its lowest cell is shifted down (live XRP case)', () {
    final s = startingPositionShift(
      top: 1.699,
      bottom: 0.8923,
      entry: 0.9995,
      rows: 3,
      direction: GridDirection.short,
    );
    expect(s, isNotNull);
    final step = (1.699 - 0.8923) / 3;
    expect(s!.bottom, closeTo(0.9995 - 1.5 * step, 1e-9));
    expect(s.top - s.bottom, closeTo(1.699 - 0.8923, 1e-9));
    // Now one inner line sits below the entry.
    expect(s.bottom + step, lessThan(0.9995));
  });

  test('short with an inner line below the entry is left alone', () {
    expect(
      startingPositionShift(
        top: 1.699,
        bottom: 0.8923,
        entry: 1.3,
        rows: 3,
        direction: GridDirection.short,
      ),
      isNull,
    );
  });

  test('long opened in its top cell is shifted up', () {
    final s = startingPositionShift(
      top: 100,
      bottom: 40,
      entry: 95,
      rows: 3,
      direction: GridDirection.long,
    );
    expect(s, isNotNull);
    expect(s!.top, closeTo(95 + 1.5 * 20, 1e-9));
    expect(s.top - s.bottom, closeTo(60, 1e-9));
    expect(s.top - 20, greaterThan(95));
  });

  test('long with an inner line above the entry is left alone (live ETH)', () {
    expect(
      startingPositionShift(
        top: 2530.94,
        bottom: 632.71,
        entry: 1771.45,
        rows: 3,
        direction: GridDirection.long,
      ),
      isNull,
    );
  });

  test('fewer than 2 rows has no inner lines - nothing to shift', () {
    expect(
      startingPositionShift(
        top: 2,
        bottom: 1,
        entry: 1.1,
        rows: 1,
        direction: GridDirection.short,
      ),
      isNull,
    );
  });
}
