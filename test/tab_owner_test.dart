import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_pionex/data/tradingview/cdp_client.dart';

void main() {
  group('decideOwnTab', () {
    const me = pionexTabOwner;

    test('uses the one tab already tagged as ours, wherever it is', () {
      final d = decideOwnTab(['tradingmt5', me], me);
      expect(d.use, 1);
      expect(d.error, isNull);
    });

    test('two tabs tagged as ours: uses none', () {
      final d = decideOwnTab([me, me], me);
      expect(d.use, isNull);
      expect(d.claimOrder, isEmpty);
      expect(d.error, isNotNull);
    });

    test('claims only untagged tabs, never one tagged by another app', () {
      final d = decideOwnTab(['tradingmt5', null], me);
      expect(d.use, isNull);
      expect(d.claimOrder, [1]);
    });

    test('a tab that does not answer blocks claiming (it may be ours, stuck)', () {
      final d = decideOwnTab(['tradingmt5', tabNoAnswer, null], me);
      expect(d.claimOrder, isEmpty);
      expect(d.error, isNotNull);
    });

    test('a non-answering tab does not matter once ours is found', () {
      expect(decideOwnTab([tabNoAnswer, me], me).use, 1);
    });

    test('nothing free, or no tabs at all: error, nothing to claim', () {
      expect(decideOwnTab(['tradingmt5'], me).error, isNotNull);
      expect(decideOwnTab([], me).error, isNotNull);
    });
  });

  test('claim script matches the shared rule exactly', () {
    expect(
      tabOwnerClaimScript(pionexTabOwner),
      '(function(){var k="tvTabOwner",v=sessionStorage.getItem(k);'
      'if(v==="tradingpionex")return "mine";if(v)return "taken:"+v;'
      'sessionStorage.setItem(k,"tradingpionex");return "claimed";})()',
    );
  });

  test('no code closes, navigates or kills tabs or TradingView; one tab-open path (real clicks)', () {
    // TradingView is shared with another app's live tab. Opening a tab can
    // push the free plan past its 2 chart connections and close the other
    // app's; navigating or closing would take it over; killing by name would
    // take down both.
    final banned = <String, RegExp>{
      'Target.createTarget': RegExp(r'Target\.createTarget'),
      'Target.closeTarget': RegExp(r'Target\.closeTarget'),
      'Target.activateTarget': RegExp(r'Target\.activateTarget'),
      'window.open': RegExp(r'window\.open\s*\('),
      'Page.navigate': RegExp(r'Page\.navigate'),
      'location assignment': RegExp(
        r'location\.(assign|replace)\s*\(|location\.href\s*=[^=]|location\s*=[^=]',
      ),
      '/json/new': RegExp(r'/json/new'),
      '/json/close': RegExp(r'/json/close'),
      '/json/activate': RegExp(r'/json/activate'),
      // Killing by image name would take TradingView (or anything else
      // sharing a name) down; the only kill allowed is our own engine by PID.
      'taskkill /IM': RegExp(r'''['"]/IM['"]|/IM\s''', caseSensitive: false),
      'pkill': RegExp(r'''['"]pkill['"]'''),
      'killall': RegExp(r'''['"]killall['"]'''),
    };
    final hits = <String>[];
    var pageReloads = 0;
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final text = f.readAsStringSync();
      banned.forEach((name, re) {
        if (re.hasMatch(text)) hits.add('$name in ${f.path}');
      });
      pageReloads += RegExp(r"'Page\.reload'").allMatches(text).length;
    }
    expect(hits, isEmpty);
    expect(pageReloads, 1, reason: 'Page.reload only inside reloadOwnTab');

    // The one real taskkill call: our own engine, by PID, nothing else.
    final taskkillCalls = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      for (final m in RegExp(r"Process\.run\(\s*'taskkill'[^)]*\)")
          .allMatches(f.readAsStringSync())) {
        taskkillCalls.add(m.group(0)!.replaceAll(RegExp(r'\s+'), ' '));
      }
    }
    expect(taskkillCalls, ["Process.run('taskkill', ['/F', '/PID', '\$pid'])"]);

    // The one way this app opens a tab (per the user, 2026-11-13): real
    // clicks on TradingView's own New tab and layout card. Only cdp_client.dart
    // may touch TradingView's window-frame and new-tab pages.
    final clicks = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final text = f.readAsStringSync();
      if (text.contains('/app/window/index.html') ||
          text.contains('/app/new-tab/index.html')) {
        clicks.add(f.path.replaceAll('\\', '/'));
      }
    }
    expect(clicks, ['lib/data/tradingview/cdp_client.dart']);
  });
}
