import 'dart:convert';

import '../models/range_result.dart';
import '../models/signal.dart';
import 'cdp_client.dart';
import 'chart_state.dart' show customScripts;

/// Strict, scriptIdPart-filtered reads from only the two custom scripts —
/// ported 1:1 from lib/signals.js. Every reader here evaluates a JS
/// expression that walks TradingView's internal chart model
/// (`dataSources()` -> `_graphics._primitivesCollection`) directly, exactly
/// as the original did; only the transport (CdpClient.evaluate) changed.

double? _round(num? v) => v == null ? null : (v * 1e8).round() / 1e8;

String _buildSourceReaderExpr(String scriptPart, List<String> collections) {
  final keys = jsonEncode(collections);
  return '''(function() {
    var chart = window.TradingViewApi._activeChartWidgetWV.value()._chartWidget;
    var sources = chart.model().model().dataSources();
    var result = { found: false, meta: null, collections: {} };
    var wantKeys = $keys;
    for (var si = 0; si < sources.length; si++) {
      var s = sources[si];
      if (!s.metaInfo) continue;
      var part = '';
      var name = '';
      try {
        var m = s.metaInfo();
        part = m.scriptIdPart || '';
        name = m.description || m.shortDescription || '';
      } catch (e) {}
      if (part !== ${jsonEncode(scriptPart)}) continue;
      result.found = true;
      result.meta = { name: name, scriptIdPart: part };
      var g = s._graphics;
      if (!g || !g._primitivesCollection) continue;
      var pc = g._primitivesCollection;
      for (var ci = 0; ci < wantKeys.length; ci++) {
        var ck = wantKeys[ci];
        var items = [];
        try {
          var outer = pc[ck];
          if (outer && typeof outer.forEach === 'function') {
            outer.forEach(function(mapVal, mapKey) {
              if (!mapVal) return;
              if (mapVal._primitivesDataById && mapVal._primitivesDataById.size > 0) {
                mapVal._primitivesDataById.forEach(function(v, id) { items.push({ mapKey: mapKey, id: id, raw: v }); });
              } else if (typeof mapVal.get === 'function') {
                try {
                  var inner = mapVal.get(false);
                  if (inner && inner._primitivesDataById) {
                    inner._primitivesDataById.forEach(function(v, id) { items.push({ mapKey: mapKey, id: id, raw: v }); });
                  }
                } catch (e) {}
              }
            });
          }
        } catch (e) {}
        result.collections[ck] = items;
      }
    }
    return result;
  })()''';
}

class LabelReading {
  const LabelReading({required this.text, required this.price});
  final String text;
  final double? price;
}

Future<List<LabelReading>> readLabels(CdpClient cdp, String scriptPart) async {
  final raw =
      await cdp.evaluate(_buildSourceReaderExpr(scriptPart, ['dwglabels']))
          as Map<String, dynamic>?;
  if (raw?['found'] != true) return const [];
  final items = ((raw?['collections']?['dwglabels'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  return items
      .map((it) {
        final v = (it['raw'] as Map?)?.cast<String, dynamic>() ?? const {};
        return LabelReading(
          text: (v['t'] ?? '').toString(),
          price: _round(v['y'] as num?),
        );
      })
      .where((l) => l.text.isNotEmpty || l.price != null)
      .toList();
}

class BoxReading {
  const BoxReading({required this.high, required this.low});
  final double high;
  final double low;
}

Future<List<BoxReading>> readBoxes(CdpClient cdp, String scriptPart) async {
  final raw =
      await cdp.evaluate(_buildSourceReaderExpr(scriptPart, ['dwgboxes']))
          as Map<String, dynamic>?;
  if (raw?['found'] != true) return const [];
  final items = ((raw?['collections']?['dwgboxes'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  final out = <BoxReading>[];
  for (final it in items) {
    final v = (it['raw'] as Map?)?.cast<String, dynamic>() ?? const {};
    final y1 = v['y1'] as num?, y2 = v['y2'] as num?;
    if (y1 == null || y2 == null) continue;
    out.add(
      BoxReading(
        high: _round(y1 > y2 ? y1 : y2)!,
        low: _round(y1 < y2 ? y1 : y2)!,
      ),
    );
  }
  return out;
}

Future<List<ZigzagSegment>> readLines(CdpClient cdp, String scriptPart) async {
  final raw =
      await cdp.evaluate(_buildSourceReaderExpr(scriptPart, ['dwglines']))
          as Map<String, dynamic>?;
  if (raw?['found'] != true) return const [];
  final items = ((raw?['collections']?['dwglines'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  final out = <ZigzagSegment>[];
  for (final it in items) {
    final v = (it['raw'] as Map?)?.cast<String, dynamic>() ?? const {};
    final y1 = v['y1'] as num?;
    if (y1 == null) continue;
    final y2 = (v['y2'] as num?) ?? y1;
    out.add(
      ZigzagSegment(
        x1: (v['x1'] as num?)?.toDouble() ?? 0,
        y1: y1.toDouble(),
        x2: (v['x2'] as num?)?.toDouble() ?? 0,
        y2: y2.toDouble(),
        horizontal: y1 == y2,
      ),
    );
  }
  return out;
}

class ParsedTable {
  const ParsedTable({required this.tableId, required this.rows});
  final int tableId;
  final List<String> rows;
}

Future<List<ParsedTable>> readTables(CdpClient cdp, String scriptPart) async {
  final raw =
      await cdp.evaluate(_buildSourceReaderExpr(scriptPart, ['dwgtablecells']))
          as Map<String, dynamic>?;
  if (raw?['found'] != true) return const [];
  final cells = ((raw?['collections']?['dwgtablecells'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  final tables = <int, Map<int, Map<int, String>>>{};
  for (final it in cells) {
    final v = (it['raw'] as Map?)?.cast<String, dynamic>() ?? const {};
    final tid = (v['tid'] as num?)?.toInt() ?? 0;
    final row = (v['row'] as num?)?.toInt() ?? 0;
    final col = (v['col'] as num?)?.toInt() ?? 0;
    (tables[tid] ??= {})[row] ??= {};
    tables[tid]![row]![col] = (v['t'] ?? '').toString();
  }
  final out = <ParsedTable>[];
  for (final entry in tables.entries) {
    final rowNums = entry.value.keys.toList()..sort();
    final lines = <String>[];
    for (final rn in rowNums) {
      final cols = entry.value[rn]!;
      final colNums = cols.keys.toList()..sort();
      final line = colNums
          .map((cn) => cols[cn]!)
          .where((s) => s.isNotEmpty)
          .join(' | ');
      if (line.isNotEmpty) lines.add(line);
    }
    out.add(ParsedTable(tableId: entry.key, rows: lines));
  }
  return out;
}

Future<Map<String, String>> readStudyValues(
  CdpClient cdp,
  String scriptPart,
) async {
  final expr =
      '''(function() {
    var chart = window.TradingViewApi._activeChartWidgetWV.value()._chartWidget;
    var sources = chart.model().model().dataSources();
    for (var si = 0; si < sources.length; si++) {
      var s = sources[si];
      if (!s.metaInfo) continue;
      var part = '';
      try { var m = s.metaInfo(); part = m.scriptIdPart || ''; } catch (e) {}
      if (part !== ${jsonEncode(scriptPart)}) continue;
      var values = {};
      try {
        var dwv = s.dataWindowView();
        if (dwv) {
          var items = dwv.items();
          if (items) {
            for (var i = 0; i < items.length; i++) {
              var item = items[i];
              if (item._value && item._value !== '∅' && item._title) values[item._title] = item._value;
            }
          }
        }
      } catch (e) {}
      return { found: true, values: values };
    }
    return { found: false, values: {} };
  })()''';
  final raw = await cdp.evaluate(expr) as Map<String, dynamic>?;
  return ((raw?['values'] as Map?) ?? const {}).map(
    (k, v) => MapEntry(k.toString(), v.toString()),
  );
}

/// worm_10_26 + spy_9_26 combined read, for the third decision technique
/// (2026-10-14). ONE evaluate() call across both scripts, same
/// single-round-trip discipline as every other reader here. Confirmed
/// directly with the user, after an initial wrong guess (continuous
/// "SuperTrend Buy"/"SuperTrend Sell" trend-state flags), exactly which
/// plot each spec case maps to:
///
/// - `New Higher High`/`New Lower Low` -> [Worm10Check.zigzag]'s hh/ll tags.
/// - `BUY`/`SELL` (all-caps, worm_9_26 heritage) -> [Worm10Check.zigzag]'s
///   buy/sell tags - drives the CLOSE-signal "case 3" only ("if you view
///   the buy/sell signals in technique 1 ... case 3 are the buy/sell
///   zigzag signals, not buy/sell supertrend signals").
/// - `Buy`/`Sell` (mixed case, discrete Supertrend entry, same plots
///   [readSupertrendSignals] already reads) -> [Worm10Check.supertrend] -
///   drives the OPEN-signal "case 1" confluence's "supertrend need to be
///   X" leg only ("worm 10 has two buy signals and two sell signals ...
///   one (buy/sell) for super trend ... those signals are for case 1
///   open signals").
/// - The continuous `SuperTrend Buy`/`SuperTrend Sell` trend-state flags
///   are NOT read at all, same reasoning as [readSupertrendSignals].
/// - spy_9_26's five RSI zone plots -> [Worm10Check.rsiZones].
Future<Worm10Check> readWorm10Signals(
  CdpClient cdp,
  String symbol,
  String worm10ScriptIdPart,
  String rsiScriptIdPart, {
  void Function(String message)? onDebugError,
}) async {
  final expr =
      '''(function() {
    try {
      var chart = window.TradingViewApi._activeChartWidgetWV.value()._chartWidget;
      var sources = chart.model().model().dataSources();
      var worm10Src = null, rsiSrc = null;
      for (var si = 0; si < sources.length; si++) {
        var s = sources[si];
        var part = '';
        try { part = s.metaInfo().scriptIdPart || ''; } catch (e) {}
        if (part === ${jsonEncode(worm10ScriptIdPart)}) worm10Src = s;
        if (part === ${jsonEncode(rsiScriptIdPart)}) rsiSrc = s;
      }
      if (!worm10Src) return { error: 'worm_10_26 not found' };
      if (!rsiSrc) return { error: 'spy_9_26 not found' };
      // 2026-10-25 - never read plots from a series that hasn't loaded
      // THIS symbol (a stuck feed kept LTCUSDT's daily bars under every
      // other pair's label, see chartDataMismatchReason).
      var mainSeries = chart.model().mainSeries();
      if (typeof mainSeries.isLoading === 'function' && mainSeries.isLoading()) {
        return { error: 'main series still loading - refusing to read' };
      }
      var loadedInfo = typeof mainSeries.symbolInfo === 'function' ? mainSeries.symbolInfo() : null;
      function tickerBase(s) {
        var v = String(s || '').trim().toUpperCase();
        if (v.indexOf(':') !== -1) v = v.split(':').pop();
        if (v.indexOf('/') !== -1) v = v.split('/')[0];
        if (v.indexOf('_') !== -1) v = v.split('_')[0];
        return v.replace(/USDT/g, '').replace(/\\.PERP/g, '');
      }
      var loadedName = loadedInfo ? (loadedInfo.name || loadedInfo.ticker || '') : '';
      if (!loadedName || tickerBase(loadedName) !== tickerBase(${jsonEncode(symbol)})) {
        return { error: 'main series holds ' + (loadedName || 'nothing') + ', not ' + ${jsonEncode(symbol)} + ' - refusing to read' };
      }

      function colOf(plotId) {
        var num = parseInt((String(plotId).match(/(\\d+)\$/) || [])[1], 10);
        return num + 1;
      }
      function findCol(src, title) {
        var meta = src.metaInfo();
        var styles = meta.styles || {};
        for (var sk in styles) {
          var se = styles[sk];
          if (se && se.title === title) return colOf(sk);
        }
        return null;
      }
      function rowsOf(s) {
        var items = (s._data && s._data._items) ? s._data._items : null;
        var out = [];
        if (!items) return out;
        var total = items.length !== undefined ? items.length : Object.keys(items).length;
        for (var r = 0; r < total; r++) {
          var item = items[r];
          if (!item) continue;
          out.push(item.value || item);
        }
        return out;
      }
      var isNum = function (v) { return typeof v === 'number' && !isNaN(v) && v !== 0; };

      var hhCol = findCol(worm10Src, 'New Higher High');
      var llCol = findCol(worm10Src, 'New Lower Low');
      var zBuyCol = findCol(worm10Src, 'BUY');
      var zSellCol = findCol(worm10Src, 'SELL');
      var stBuyCol = findCol(worm10Src, 'Buy');
      var stSellCol = findCol(worm10Src, 'Sell');
      if (hhCol == null || llCol == null || zBuyCol == null || zSellCol == null ||
          stBuyCol == null || stSellCol == null) {
        return { error: 'worm_10_26 plot columns not found (hh=' + hhCol + ' ll=' + llCol +
          ' zBuy=' + zBuyCol + ' zSell=' + zSellCol + ' stBuy=' + stBuyCol + ' stSell=' + stSellCol + ')' };
      }

      var rsiBlueCol = findCol(rsiSrc, 'RSI &lt;= 20% (Blue)');
      var rsiPurpleCol = findCol(rsiSrc, 'RSI 20-35% (Purple)');
      var rsiWhiteCol = findCol(rsiSrc, 'RSI 35-65% (White)');
      var rsiGreenCol = findCol(rsiSrc, 'RSI 65-80% (Green)');
      var rsiYellowCol = findCol(rsiSrc, 'RSI &gt;= 80% (Yellow)');
      if (rsiBlueCol == null || rsiPurpleCol == null || rsiWhiteCol == null ||
          rsiGreenCol == null || rsiYellowCol == null) {
        return { error: 'spy_9_26 RSI zone columns not found (blue=' + rsiBlueCol +
          ' purple=' + rsiPurpleCol + ' white=' + rsiWhiteCol + ' green=' + rsiGreenCol +
          ' yellow=' + rsiYellowCol + ')' };
      }

      var zigzagSignals = [];
      var supertrendSignals = [];
      var latestBarTime = 0;
      var worm10Rows = rowsOf(worm10Src);
      var sortedRows = [];
      for (var r = 0; r < worm10Rows.length; r++) {
        var row = worm10Rows[r];
        var t = row[0];
        if (typeof t !== 'number') continue;
        sortedRows.push(row);
      }
      sortedRows.sort(function (a, b) { return a[0] - b[0]; });
      // 2026-10-17 - "New Higher High"/"New Lower Low" print on EVERY bar
      // that's a fresh local extreme within an ongoing swing, not just
      // the one bar the real zigzag pivot/label finally settles on - a
      // sustained decline can print several separate HH/LL occurrences
      // before the swing reverses. An earlier attempt to de-duplicate
      // these HERE (by raw tag, before classification) was wrong: two LL
      // prints a few hours apart can resolve to DIFFERENT, both-
      // meaningful event kinds (buyOpen1 vs. the weaker sellClose1)
      // depending on Supertrend's state at each one - collapsing by raw
      // tag could silently discard a real close signal in favor of a
      // later, unrelated open signal (confirmed live: a real SHORT's true
      // close signal at Oct 13 00:00 got discarded this way). Every raw
      // occurrence is emitted here, unfiltered - [deriveWorm10Events]
      // does the de-duplication AFTER classification, where it can tell
      // the two apart.
      var wasZBuy = false, wasZSell = false;
      for (var r = 0; r < sortedRows.length; r++) {
        var row = sortedRows[r];
        var t = row[0];
        if (t > latestBarTime) latestBarTime = t;
        if (isNum(row[hhCol])) zigzagSignals.push({ time: t, tag: 'HH' });
        if (isNum(row[llCol])) zigzagSignals.push({ time: t, tag: 'LL' });
        var isZBuy = isNum(row[zBuyCol]);
        var isZSell = isNum(row[zSellCol]);
        if (isZBuy && !wasZBuy) zigzagSignals.push({ time: t, tag: 'BUY' });
        if (isZSell && !wasZSell) zigzagSignals.push({ time: t, tag: 'SELL' });
        wasZBuy = isZBuy; wasZSell = isZSell;
        if (isNum(row[stBuyCol])) supertrendSignals.push({ time: t, tag: 'BUY' });
        if (isNum(row[stSellCol])) supertrendSignals.push({ time: t, tag: 'SELL' });
      }
      zigzagSignals.sort(function (a, b) { return (a.time || 0) - (b.time || 0); });
      supertrendSignals.sort(function (a, b) { return (a.time || 0) - (b.time || 0); });

      // Each RSI zone title resolves to a shared "line" plot that always
      // carries the SAME raw RSI value regardless of which zone is active
      // (TradingView's own conditional-coloring construct: one value plot
      // paired with a separate, untitled "colorer" plot immediately after
      // it in the plot list - confirmed live, 2026-10-14, via
      // metaInfo().plots: plot_0 "line" (Yellow) + plot_1 "colorer", plot_2
      // "line" (Green) + plot_3 "colorer", etc.). The colorer is `null`
      // when that zone is NOT active for the bar and a small zone-index
      // number (0 for Yellow, seen live) when it IS - so the zone check
      // must read `lineCol + 1`, not the line column itself, and must NOT
      // exclude 0 (unlike [isNum] above, since 0 is a genuine "active"
      // value here) - reading the line column directly, as before,
      // silently misclassified every single bar as "blue" (checked first)
      // since that raw value is virtually never exactly zero.
      function isActiveColorer(v) {
        return typeof v === 'number' && !isNaN(v);
      }

      var rsiZones = [];
      var rsiRows = rowsOf(rsiSrc);
      for (var rr = 0; rr < rsiRows.length; rr++) {
        var rrow = rsiRows[rr];
        var rt = rrow[0];
        if (typeof rt !== 'number') continue;
        if (isActiveColorer(rrow[rsiBlueCol + 1])) rsiZones.push({ time: rt, zone: 'blue' });
        else if (isActiveColorer(rrow[rsiPurpleCol + 1])) rsiZones.push({ time: rt, zone: 'purple' });
        else if (isActiveColorer(rrow[rsiWhiteCol + 1])) rsiZones.push({ time: rt, zone: 'white' });
        else if (isActiveColorer(rrow[rsiGreenCol + 1])) rsiZones.push({ time: rt, zone: 'green' });
        else if (isActiveColorer(rrow[rsiYellowCol + 1])) rsiZones.push({ time: rt, zone: 'yellow' });
      }
      rsiZones.sort(function (a, b) { return (a.time || 0) - (b.time || 0); });

      return {
        zigzagSignals: zigzagSignals,
        supertrendSignals: supertrendSignals,
        rsiZones: rsiZones,
        latestBarTime: latestBarTime || null
      };
    } catch (e) {
      return { error: String(e && e.message || e) };
    }
  })()''';
  final raw = await cdp.evaluate(expr) as Map<String, dynamic>?;
  if (raw?['error'] != null) {
    onDebugError?.call(raw!['error'].toString());
  }
  final zigzagSignals = ((raw?['zigzagSignals'] as List?) ?? const [])
      .cast<Map<String, dynamic>>()
      .map(Signal.fromJson)
      .toList();
  final supertrendSignals = ((raw?['supertrendSignals'] as List?) ?? const [])
      .cast<Map<String, dynamic>>()
      .map(Signal.fromJson)
      .toList();
  final latestBarTime = (raw?['latestBarTime'] as num?)?.toInt();
  final rsiZoneMap = {
    'blue': RsiZone.blue,
    'purple': RsiZone.purple,
    'white': RsiZone.white,
    'green': RsiZone.green,
    'yellow': RsiZone.yellow,
  };
  final rsiZones = ((raw?['rsiZones'] as List?) ?? const [])
      .cast<Map<String, dynamic>>()
      .map(
        (m) => RsiZoneSample(
          zone: rsiZoneMap[m['zone'] as String]!,
          time: (m['time'] as num).toInt(),
        ),
      )
      .toList();
  return Worm10Check(
    symbol: symbol,
    zigzag: BuySellCheck(symbol: symbol, signals: zigzagSignals, latestBarTime: latestBarTime),
    supertrend: BuySellCheck(symbol: symbol, signals: supertrendSignals, latestBarTime: latestBarTime),
    rsiZones: rsiZones,
    latestBarTime: latestBarTime,
  );
}

class MsbReading {
  const MsbReading({
    required this.labels,
    required this.boxes,
    required this.lines,
    required this.tables,
  });
  final List<LabelReading> labels;
  final List<BoxReading> boxes;
  final List<ZigzagSegment> lines;
  final List<ParsedTable> tables;
}

class RsiReading {
  const RsiReading({required this.values});
  final Map<String, String> values;
}

class CustomSignalsReading {
  const CustomSignalsReading({required this.msb, required this.rsi});
  final MsbReading msb;
  final RsiReading rsi;
}

/// Reads ALL signal data from ONLY the two custom scripts.
Future<CustomSignalsReading> readCustomSignals(CdpClient cdp) async {
  final msbPart = customScripts[0].scriptIdPart;
  final rsiPart = customScripts[1].scriptIdPart;
  final msb = MsbReading(
    labels: await readLabels(cdp, msbPart),
    boxes: await readBoxes(cdp, msbPart),
    lines: await readLines(cdp, msbPart),
    tables: await readTables(cdp, msbPart),
  );
  final rsi = RsiReading(values: await readStudyValues(cdp, rsiPart));
  return CustomSignalsReading(msb: msb, rsi: rsi);
}
