import 'dart:convert';

import 'cdp_client.dart';

/// Reads the "Red list" watchlist from the TradingView right-side panel via
/// CDP DOM scraping — ported 1:1 from lib/watchlist.js. The watchlist API
/// object is a Proxy that hides its methods, and the panel is NOT
/// virtualized (every row, even off-screen, is in the DOM), so the DOM is the
/// only reliable, always-fresh source. Never cache the result — the user can
/// add/remove pairs at any time.

/// Maps a bare "XXUSDT" to the full symbol string setChartView() expects.
String qualifySymbol(String bare) {
  final s = bare.toUpperCase();
  if (s.startsWith('BINANCE:') ||
      s.startsWith('_PERP') ||
      RegExp(r'\.PERP$').hasMatch(s))
    return s;
  if (RegExp(r'^(.*)USDT$').hasMatch(s)) return 'BINANCE:$s';
  return s;
}

class WatchlistReading {
  const WatchlistReading({
    required this.found,
    this.error,
    this.name,
    this.activeTabName,
    this.symbols = const [],
  });
  final bool found;
  final String? error;
  final String? name;

  /// The watchlist tab that actually looks selected right now, determined
  /// via `aria-selected`/`aria-current`/an "active"-ish class name - a tab
  /// literally labeled "Red list" always exists in the panel regardless of
  /// which tab is selected, so [name] alone never proved the returned
  /// [symbols] came from the Red List specifically rather than whichever
  /// tab a stray click left active. Null when the active-tab heuristic
  /// itself couldn't identify anything (an uncertain result, not a "no"
  /// answer) - callers should only treat a CONFIDENT mismatch as a reason
  /// to distrust the read, never treat null as one.
  final String? activeTabName;
  final List<String> symbols;
}

const _redListExpr = '''(function(wantName) {
  var wl = document.querySelector('.widgetbar-widget-watchlist');
  if (!wl) return { found: false, error: 'watchlist panel not found' };

  var name = null;
  var all = wl.querySelectorAll('*');
  for (var i = 0; i < all.length; i++) {
    var el = all[i];
    if (el.children.length) continue;
    var t = (el.textContent || '').trim();
    if (t === 'Red list' || t === wantName) {
      if (t === wantName) name = t;
      else if (t === 'Red list') name = t;
    }
  }

  // Which tab is actually SELECTED right now - a tab button labeled
  // "Red list" exists among the panel's tabs regardless of which one is
  // active, so this is the only thing that can confirm the rows below
  // actually belong to it. Heuristic (aria-selected/aria-current/an
  // "active"-ish class) since TradingView's own class names are hashed and
  // undocumented - `activeTabName` stays null (uncertain, not "no") if none
  // of these match anything.
  var activeTabName = null;
  var tabCandidates = wl.querySelectorAll('button, [role="tab"]');
  for (var ti = 0; ti < tabCandidates.length; ti++) {
    var tab = tabCandidates[ti];
    var cls = tab.getAttribute('class') || '';
    var selected = tab.getAttribute('aria-selected') === 'true' ||
                   tab.getAttribute('aria-current') === 'true' ||
                   /active|selected|current/i.test(cls);
    if (!selected) continue;
    var txt = (tab.textContent || tab.getAttribute('aria-label') || '').trim();
    if (txt) { activeTabName = txt; break; }
  }

  var rows = [];
  for (var j = 0; j < all.length; j++) {
    var e = all[j];
    if (e.children.length) continue;
    if (e.offsetParent === null) continue;
    var txt = (e.textContent || '').trim();
    if (!/^(?=.*[A-Z])[A-Z0-9]{2,10}\$/.test(txt)) continue;
    var r = e.getBoundingClientRect();
    rows.push({ t: txt, y: r.y, x: r.x });
  }
  rows.sort(function (a, b) { return (a.y - b.y) || (a.x - b.x); });

  var symbols = rows.map(function (r) { return r.t; });
  return { found: true, name: name, activeTabName: activeTabName, count: symbols.length, symbols: symbols };
})(%s)''';

/// Reads the currently active watchlist panel and, if [wantName] is given,
/// verifies the header title matches it. Returns bare symbols in DOM order.
Future<WatchlistReading> readWatchlist(
  CdpClient cdp, {
  String? wantName,
}) async {
  final raw =
      await cdp.evaluate(_redListExpr.replaceFirst('%s', jsonEncode(wantName)))
          as Map<String, dynamic>?;
  if (raw?['found'] != true)
    return WatchlistReading(found: false, error: raw?['error'] as String?);
  return WatchlistReading(
    found: true,
    name: raw?['name'] as String?,
    activeTabName: raw?['activeTabName'] as String?,
    symbols: ((raw?['symbols'] as List?) ?? const []).cast<String>(),
  );
}
