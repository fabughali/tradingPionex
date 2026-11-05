import 'dart:convert';

import '../models/range_result.dart';
import '../technique/worm10_decision.dart';
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

/// Result of [readWorm10Bars] - raw bars only, no derivation. Callers run
/// `deriveWorm10Events` (worm10_decision.dart) on [bars] themselves.
class Worm10Check {
  const Worm10Check({
    required this.symbol,
    required this.bars,
    required this.latestBarTime,
  });
  final String symbol;
  final List<Worm10Bar> bars;

  /// The newest bar's open time - the candle-gate anchor, same convention
  /// as [BuySellCheck.latestBarTime].
  final int? latestBarTime;
}

/// Worm10 Hybrid Decision technique (2026-10-25, per the user: "and remove
/// any old technique from code and from prd") - replaces
/// [readWormSignals]/the worm_9_26 technique entirely, not alongside it.
/// Reads worm_10_26's six plots (HH, LL, zigzag BUY/SELL, discrete
/// Supertrend Buy/Sell - all confirmed live via CDP against the real
/// chart, including the case-sensitive distinction between `BUY`/`SELL`
/// and `Buy`/`Sell`, and that the *continuous* `SuperTrend Buy`/
/// `SuperTrend Sell` lines are genuinely separate plots, never read here)
/// plus spy_9_26's five RSI zones, aligned by bar time, into raw
/// [Worm10Bar]s - see `worm10_decision.dart`'s `deriveWorm10Events` for
/// the pure derivation logic this feeds (event confluence, swing dedup,
/// the decision table) - this function does no derivation itself, purely
/// mechanical extraction.
Future<Worm10Check> readWorm10Bars(
  CdpClient cdp,
  String symbol,
  String wormScriptPart,
  String rsiScriptPart, {
  void Function(String message)? onDebugError,
}) async {
  final expr =
      '''(function() {
    try {
      var chart = window.TradingViewApi._activeChartWidgetWV.value()._chartWidget;
      var sources = chart.model().model().dataSources();
      var wormSrc = null, rsiSrc = null;
      for (var si = 0; si < sources.length; si++) {
        var s = sources[si];
        if (!s.metaInfo) continue;
        var part = '';
        try { part = s.metaInfo().scriptIdPart || ''; } catch (e) {}
        if (part === ${jsonEncode(wormScriptPart)}) wormSrc = s;
        else if (part === ${jsonEncode(rsiScriptPart)}) rsiSrc = s;
      }
      if (!wormSrc || !rsiSrc) return { found: false, error: 'one or both scripts not found' };

      // Never read plots from a series that hasn't loaded THIS symbol: a
      // stuck feed keeps the previous pair's bars under the new pair's label
      // (see chartDataMismatchReason).
      var mainSeries = chart.model().mainSeries();
      if (typeof mainSeries.isLoading === 'function' && mainSeries.isLoading()) {
        return { found: false, error: 'main series still loading - refusing to read' };
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
        return { found: false, error: 'main series holds ' + (loadedName || 'nothing') + ', not ' + ${jsonEncode(symbol)} + ' - refusing to read' };
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
      function findColByColor(src, color) {
        var meta = src.metaInfo();
        var styles = meta.styles || {};
        for (var sk in styles) {
          var se = styles[sk];
          if (se && se.title && se.title.indexOf('(' + color + ')') !== -1) return colOf(sk);
        }
        return null;
      }

      var hhCol = findCol(wormSrc, 'New Higher High');
      var llCol = findCol(wormSrc, 'New Lower Low');
      var zbCol = findCol(wormSrc, 'BUY');
      var zsCol = findCol(wormSrc, 'SELL');
      var stBuyCol = findCol(wormSrc, 'Buy');
      var stSellCol = findCol(wormSrc, 'Sell');
      var yellowCol = findColByColor(rsiSrc, 'Yellow');
      var greenCol = findColByColor(rsiSrc, 'Green');
      var whiteCol = findColByColor(rsiSrc, 'White');
      var purpleCol = findColByColor(rsiSrc, 'Purple');
      var blueCol = findColByColor(rsiSrc, 'Blue');
      if (hhCol == null || llCol == null || zbCol == null || zsCol == null ||
          stBuyCol == null || stSellCol == null || yellowCol == null ||
          greenCol == null || whiteCol == null || purpleCol == null || blueCol == null) {
        var wormTitles = [], rsiTitles = [];
        try {
          var ws = wormSrc.metaInfo().styles || {};
          for (var wk in ws) { wormTitles.push(ws[wk] && ws[wk].title); }
        } catch (e) {}
        try {
          var rs = rsiSrc.metaInfo().styles || {};
          for (var rk in rs) { rsiTitles.push(rs[rk] && rs[rk].title); }
        } catch (e) {}
        return { found: true, error: 'plot columns not found - worm_10_26 titles: ' + JSON.stringify(wormTitles) + ' - spy_9_26 titles: ' + JSON.stringify(rsiTitles) };
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
      // Each zone title is a "line" plot carrying the same raw RSI value
      // whichever zone is active, paired with an untitled "colorer" plot right
      // after it: null when that zone is inactive, a small index when active
      // (0 is a genuine active value). So the zone is read from the indicator's
      // own colorer at lineCol + 1, never worked out from the line value.
      var isActiveColorer = function (v) { return typeof v === 'number' && !isNaN(v); };
      var zoneByTime = {};
      var rsiRows = rowsOf(rsiSrc);
      for (var i = 0; i < rsiRows.length; i++) {
        var row = rsiRows[i];
        var t = row[0];
        if (typeof t !== 'number') continue;
        if (isActiveColorer(row[blueCol + 1])) zoneByTime[t] = 'blue';
        else if (isActiveColorer(row[purpleCol + 1])) zoneByTime[t] = 'purple';
        else if (isActiveColorer(row[whiteCol + 1])) zoneByTime[t] = 'white';
        else if (isActiveColorer(row[greenCol + 1])) zoneByTime[t] = 'green';
        else if (isActiveColorer(row[yellowCol + 1])) zoneByTime[t] = 'yellow';
      }

      var latestBarTime = 0;
      var bars = [];
      var wormRows = rowsOf(wormSrc);
      for (var r2 = 0; r2 < wormRows.length; r2++) {
        var row2 = wormRows[r2];
        var t2 = row2[0];
        if (typeof t2 !== 'number') continue;
        if (t2 > latestBarTime) latestBarTime = t2;
        bars.push({
          time: t2,
          hh: isNum(row2[hhCol]),
          ll: isNum(row2[llCol]),
          zigzagBuy: isNum(row2[zbCol]),
          zigzagSell: isNum(row2[zsCol]),
          stBuy: isNum(row2[stBuyCol]),
          stSell: isNum(row2[stSellCol]),
          rsiZone: zoneByTime[t2] || null
        });
      }
      bars.sort(function (a, b) { return a.time - b.time; });
      return { found: true, bars: bars, latestBarTime: latestBarTime || null };
    } catch (e) {
      return { found: false, error: String(e && e.message || e) };
    }
  })()''';
  final raw = await cdp.evaluate(expr) as Map<String, dynamic>?;
  if (raw?['error'] != null) {
    onDebugError?.call(raw!['error'].toString());
  }
  final bars = ((raw?['bars'] as List?) ?? const [])
      .cast<Map<String, dynamic>>()
      .map(
        (b) => Worm10Bar(
          time: (b['time'] as num).toInt(),
          hh: b['hh'] as bool,
          ll: b['ll'] as bool,
          zigzagBuy: b['zigzagBuy'] as bool,
          zigzagSell: b['zigzagSell'] as bool,
          stBuy: b['stBuy'] as bool,
          stSell: b['stSell'] as bool,
          rsiZone: b['rsiZone'] as String?,
        ),
      )
      .toList();
  return Worm10Check(
    symbol: symbol,
    bars: bars,
    latestBarTime: (raw?['latestBarTime'] as num?)?.toInt(),
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
