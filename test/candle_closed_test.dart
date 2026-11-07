import 'package:flutter_test/flutter_test.dart';
import 'package:trading_pionex/data/technique/candle_closed.dart';

DateTime utc(int h, int m, [int s = 0]) => DateTime.utc(2026, 10, 20, h, m, s);
int epoch(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

void main() {
  const hour = Duration(hours: 1);

  test('the real BTC case: 17:00Z bar, checked at 17:02:14Z - still forming', () {
    // ZIGZAG_BUY@1792515600 (= 2026-10-20 17:00 UTC), flipped at 17:02:14Z.
    expect(epoch(utc(17, 0)), 1792515600);
    expect(isCandleClosed(1792515600, hour, utc(17, 2, 14)), isFalse);
  });

  test('the SELL_OPEN1 that opened the short (14:00Z bar) was long closed', () {
    expect(isCandleClosed(1792504800, hour, utc(17, 2, 14)), isTrue);
  });

  test('exactly at the close boundary counts as closed; one second before does not', () {
    final bar = epoch(utc(16, 0));
    expect(isCandleClosed(bar, hour, utc(17, 0)), isTrue);
    expect(isCandleClosed(bar, hour, utc(16, 59, 59)), isFalse);
  });

  test('a local-time DateTime is compared in UTC, not by wall clock', () {
    final bar = epoch(utc(16, 0));
    expect(isCandleClosed(bar, hour, utc(16, 30).toLocal()), isFalse);
    expect(isCandleClosed(bar, hour, utc(17, 30).toLocal()), isTrue);
  });
}
