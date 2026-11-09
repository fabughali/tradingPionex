import 'package:flutter_test/flutter_test.dart';
import 'package:trading_pionex/data/engine/sll_rules.dart';

void main() {
  group('sllTopUpAmount', () {
    test("rounds the investment up to the next whole dollar (user's examples)", () {
      expect(sllTopUpAmount(actualInvestment: 0.55, extraMargin: 5), 0.45);
      expect(sllTopUpAmount(actualInvestment: 1.2, extraMargin: 5), 0.8);
      expect(sllTopUpAmount(actualInvestment: 2.00, extraMargin: 5), 1);
    });

    test('moves the whole extra margin when it is under \$1', () {
      expect(sllTopUpAmount(actualInvestment: 0.55, extraMargin: 0.3), 0.3);
      expect(sllTopUpAmount(actualInvestment: 3, extraMargin: 0.8), 0.8);
    });

    test('never more than the extra margin', () {
      expect(sllTopUpAmount(actualInvestment: 1.1, extraMargin: 1.5), 0.9);
      expect(sllTopUpAmount(actualInvestment: 2, extraMargin: 1), 1);
    });

    test('nothing when extra margin is gone', () {
      expect(sllTopUpAmount(actualInvestment: 2, extraMargin: 0), 0);
    });
  });

  group('sllLockUsd', () {
    test('nothing below \$50', () {
      expect(sllLockUsd(49.99), isNull);
      expect(sllLockUsd(-10), isNull);
    });

    test('P&L - \$20 in \$10 steps', () {
      expect(sllLockUsd(50), 30);
      expect(sllLockUsd(59.9), 30);
      expect(sllLockUsd(60), 40);
      expect(sllLockUsd(87), 60);
    });
  });
}
