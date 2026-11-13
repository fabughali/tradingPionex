import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_pionex/data/tradingview/tv_sync.dart';

void main() {
  late Directory dir;
  var now = DateTime(2026, 11, 13, 12);
  TvSync sync(String app) => TvSync(app: app, dir: dir.path, clock: () => now);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tvsync_');
    now = DateTime(2026, 11, 13, 12);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('each app sees the other heartbeat until it goes stale', () {
    sync(TvSync.mt5).writeHeartbeat(
      power: true,
      tab: 'claimed',
      busy: false,
      tvHealthy: true,
    );
    final peer = sync(TvSync.pionex).peer(TvSync.mt5);
    expect(peer?.power, isTrue);
    expect(peer?.tab, 'claimed');
    now = now.add(const Duration(seconds: 21));
    expect(sync(TvSync.pionex).peer(TvSync.mt5), isNull);
  });

  test('only one app holds the TradingView lock; it expires', () {
    final p = sync(TvSync.pionex);
    final m = sync(TvSync.mt5);
    expect(m.tryLock('restart_tradingview'), isTrue);
    expect(p.tryLock('reload_own_tab'), isFalse);
    expect(p.peerRestartingTradingView(), isTrue);
    now = now.add(const Duration(minutes: 3)); // expired
    expect(p.peerRestartingTradingView(), isFalse);
    expect(p.tryLock('reload_own_tab'), isTrue);
    expect(m.tryLock('restart_tradingview'), isFalse);
    p.releaseLock();
    expect(m.tryLock('restart_tradingview'), isTrue);
  });

  test('a request reaches only its addressee, once', () {
    sync(TvSync.pionex).sendRequest(
      to: TvSync.mt5,
      type: 'restart_tradingview',
      reason: 'stuck',
    );
    expect(
      sync(TvSync.pionex).hasPendingRequest(
        to: TvSync.mt5,
        type: 'restart_tradingview',
      ),
      isTrue,
    );
    expect(sync(TvSync.pionex).takeRequests(), isEmpty);
    final got = sync(TvSync.mt5).takeRequests();
    expect(got.single['type'], 'restart_tradingview');
    expect(got.single['from'], TvSync.pionex);
    expect(sync(TvSync.mt5).takeRequests(), isEmpty);
  });
}
