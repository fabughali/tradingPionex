import 'package:flutter_test/flutter_test.dart';
import 'package:trading_pionex/widgets/bot_tp_sl_sheet.dart';

void main() {
  String? check(
    TpSlMode mode,
    bool tp,
    double v, {
    bool long = true,
  }) => validateTpSl(
    mode: mode,
    isTakeProfit: tp,
    value: v,
    long: long,
    currentPnlPercent: 12,
    currentPnlUsd: 3.5,
    currentPrice: 100,
  );

  test('P&L %: TP above current, SL below, negatives allowed', () {
    expect(check(TpSlMode.pnlPercent, true, 20), isNull);
    expect(check(TpSlMode.pnlPercent, true, 12), isNotNull);
    expect(check(TpSlMode.pnlPercent, false, -5), isNull);
    expect(check(TpSlMode.pnlPercent, false, 15), isNotNull);
  });

  test('P&L \$: TP above current, SL below', () {
    expect(check(TpSlMode.pnlUsd, true, 4), isNull);
    expect(check(TpSlMode.pnlUsd, true, 3), isNotNull);
    expect(check(TpSlMode.pnlUsd, false, 1), isNull);
    expect(check(TpSlMode.pnlUsd, false, 3.5), isNotNull);
  });

  test('Price: long TP above / SL below; short is the opposite', () {
    expect(check(TpSlMode.price, true, 110), isNull);
    expect(check(TpSlMode.price, true, 90), isNotNull);
    expect(check(TpSlMode.price, false, 90), isNull);
    expect(check(TpSlMode.price, false, 110), isNotNull);
    expect(check(TpSlMode.price, true, 90, long: false), isNull);
    expect(check(TpSlMode.price, true, 110, long: false), isNotNull);
    expect(check(TpSlMode.price, false, 110, long: false), isNull);
    expect(check(TpSlMode.price, false, 90, long: false), isNotNull);
  });
}
