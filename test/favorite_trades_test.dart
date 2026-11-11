import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_pionex/core/core_storage.dart';
import 'package:trading_pionex/data/identity/favorite_trades_store.dart';

void main() {
  late Directory dir;
  late CoreStorage storage;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fav_');
    storage = CoreStorage.forRoot(dir.path);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('favoriteCandidates', () {
    final scores = {
      'AKE_USDT_PERP': 9.0,
      'BTC_USDT_PERP': 5.0,
      'SOL_USDT_PERP': 1.0,
      'UAI_USDT_PERP': -7.0,
      'ETH_USDT_PERP': -3.0,
      'USDT_BTC_PERP': 20.0, // COIN-M - never a candidate
      'ETH_BTC_PERP': -20.0, // coin futures - never a candidate
    };

    test('filled star (rise) -> short, empty star (drop) -> long, alternating', () {
      final c = favoriteCandidates(scores, wantShorts: true, wantLongs: true, depth: 2);
      expect(c, [
        (symbol: 'AKEUSDT', short: true),
        (symbol: 'UAIUSDT', short: false),
        (symbol: 'BTCUSDT', short: true),
        (symbol: 'ETHUSDT', short: false),
      ]);
    });

    test('only lists with quota left, and excluded bases are skipped', () {
      final c = favoriteCandidates(
        scores,
        wantShorts: false,
        wantLongs: true,
        exclude: {'UAI'},
        depth: 2,
      );
      expect(c, [
        (symbol: 'ETHUSDT', short: false),
        (symbol: 'SOLUSDT', short: false),
      ]);
    });
  });

  test('nextCandleCheck is one minute after the next UTC hour', () {
    expect(
      nextCandleCheck(DateTime.utc(2026, 11, 11, 13, 25)),
      DateTime.utc(2026, 11, 11, 14, 1),
    );
  });

  group('FavoriteTradesStore', () {
    test('3 shorts and 2 longs per UTC day, then nothing until the next day', () {
      final s = FavoriteTradesStore(storage);
      var now = DateTime.utc(2026, 11, 11, 1);
      for (var i = 0; i < 3; i++) {
        expect(s.canShort(now), isTrue);
        s.recordOpened('S$i', short: true, now: now);
        now = now.add(const Duration(hours: 2));
      }
      expect(s.canShort(now), isFalse);
      s.recordOpened('L0', short: false, now: now);
      now = now.add(const Duration(hours: 2));
      s.recordOpened('L1', short: false, now: now);
      now = now.add(const Duration(hours: 2));
      expect(s.canLong(now), isFalse);
      expect(s.isDue(now), isFalse);
      // A new UTC day starts fresh - nothing carried over.
      final tomorrow = DateTime.utc(2026, 11, 12, 0, 5);
      expect(s.openedToday(tomorrow), 0);
      expect(s.canShort(tomorrow) && s.canLong(tomorrow), isTrue);
    });

    test('2 hours after an open; next candle after an empty check', () {
      final s = FavoriteTradesStore(storage);
      final t = DateTime.utc(2026, 11, 11, 10, 20);
      expect(s.isDue(t), isTrue);
      s.recordOpened('AKE', short: true, now: t);
      expect(s.isDue(t.add(const Duration(hours: 1, minutes: 59))), isFalse);
      expect(s.isDue(t.add(const Duration(hours: 2))), isTrue);
      s.recordNothing(t.add(const Duration(hours: 2)));
      expect(s.nextCheckAt, DateTime.utc(2026, 11, 11, 13, 1));
    });

    test('a restart keeps the day', () {
      final now = DateTime.utc(2026, 11, 11, 9);
      FavoriteTradesStore(storage).recordOpened('AKE', short: true, now: now);
      final again = FavoriteTradesStore(storage);
      expect(again.openedToday(now), 1);
      expect(again.basesToday(now), {'AKE'});
    });
  });
}
