import 'package:flutter_test/flutter_test.dart';
import 'package:trading_pionex/data/engine/tp_sl_ladder.dart';

void main() {
  group('highestDollarThresholdCrossed', () {
    test('below +\$5 is null (no ladder protection yet)', () {
      expect(highestDollarThresholdCrossed(0), isNull);
      expect(highestDollarThresholdCrossed(-10), isNull);
      expect(highestDollarThresholdCrossed(4.99), isNull);
    });

    test('exact and in-between values floor to the nearest \$5 rung', () {
      expect(highestDollarThresholdCrossed(5), 5);
      expect(highestDollarThresholdCrossed(7.5), 5);
      expect(highestDollarThresholdCrossed(10), 10);
      expect(highestDollarThresholdCrossed(23.9), 20);
    });
  });

  group('dollarLockFor', () {
    test('first rung (\$5) locks \$2 - the one special case', () {
      expect(dollarLockFor(5), 2);
    });

    test('every rung from \$10 up follows \$5 behind the threshold', () {
      expect(dollarLockFor(10), 5);
      expect(dollarLockFor(15), 10);
      expect(dollarLockFor(20), 15);
      expect(dollarLockFor(50), 45);
    });
  });
}
