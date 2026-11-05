import 'dart:convert';

import 'cdp_client.dart';

/// The user's two custom Pine scripts — the ONLY signal sources. Never read
/// data from anything else. Ported 1:1 from lib/chart-state.js.
class CustomScript {
  const CustomScript({
    required this.key,
    required this.scriptIdPart,
    required this.legendTitle,
    required this.dataTitle,
  });
  final String key;
  final String scriptIdPart;
  final String legendTitle;
  final String dataTitle;
}

const customScripts = [
  // Worm10 Hybrid Decision technique (2026-10-25, per the user): worm_9_26
  // and its whole decision model are retired entirely - replaced by
  // worm_10_26, a genuinely different saved script (confirmed live via
  // CDP: a different scriptIdPart hash, not a rename). Carries the same
  // HH/LL swing plots worm_9_26 had, plus the zigzag BUY/SELL and discrete
  // Supertrend Buy/Sell pairs the new technique needs - see
  // `readWorm10Signals` in signals_reader.dart.
  CustomScript(
    key: 'MSB',
    scriptIdPart: 'USER;125eec083a7d45479dac940b5af76dc7',
    legendTitle: 'worm_10_26',
    dataTitle: 'worm_10_26',
  ),
  // Per the user (2026-09-16): "instead of using combined indicator, i
  // want you to use spy_9_26, it is there in my script" - same pattern as
  // the worm_8_26 -> worm_9_26 switch above: a different saved script,
  // not a rename. Real scriptIdPart confirmed live 2026-09-16 via the
  // "CUSTOM SCRIPT SOURCES" diagnostic dump (name "RSI & Vol & Stochastic
  // RSI & VAPI", the SAME dataTitle as before - only the underlying
  // script changed, not its display title). CRITICAL follow-up fix, same
  // day: the earlier interim fix (title-fallback in verifyCustomScripts,
  // 'spy_9_26' searchTitle in enforce.dart) only stopped the chart being
  // stripped - it did NOT fix `readSwingOscillatorSignals`, which matches
  // scripts ONLY by this exact scriptIdPart with no fallback. With the
  // stale hash still here, that function could never find the real RSI
  // source, so EVERY signal read failed regardless of wait budget -
  // confirmed live (all 5 tracked pairs stuck, some past 65 consecutive
  // failures, even a fresh 30s budget still failing post-restart). Fixed
  // now with the real hash.
  CustomScript(
    key: 'RSI',
    scriptIdPart: 'USER;f40c0a529f954b648be8f2b530d43d3f',
    legendTitle: 'spy_9_26',
    dataTitle: 'RSI & Vol & Stochastic RSI & VAPI',
  ),
];

class ChartState {
  const ChartState({this.symbol, this.resolution, this.error});
  final String? symbol;
  final String? resolution;
  final String? error;

  factory ChartState.fromJson(Map<String, dynamic>? json) => ChartState(
    symbol: json?['symbol'] as String?,
    resolution: json?['resolution'] as String?,
    error: json?['error'] as String?,
  );
}

const _chartStateExpr = '''(function() {
  try {
    var wv = window.TradingViewApi && window.TradingViewApi._activeChartWidgetWV;
    if (!wv) return { error: 'TradingViewApi not found' };
    var chart = wv.value();
    if (!chart) return { error: 'chart widget not found' };
    var symbol = chart.symbol ? chart.symbol() : '';
    var resolution = chart.resolution ? chart.resolution() : '';
    return { symbol: symbol, resolution: resolution, url: location.href };
  } catch (e) {
    return { error: String(e && e.message || e) };
  }
})()''';

Future<ChartState> getChartState(CdpClient cdp) async {
  final result = await cdp.evaluate(_chartStateExpr);
  return ChartState.fromJson(result as Map<String, dynamic>?);
}

class VerifyResult {
  const VerifyResult({
    required this.ok,
    this.error,
    this.msbPresent = false,
    this.rsiPresent = false,
    this.rawSources = const [],
  });
  final bool ok;
  final String? error;
  final bool msbPresent;
  final bool rsiPresent;
  // Temporary (2026-09-16, per the user - "instead of using combined
  // indicator, i want you to use spy_9_26"): every loaded script's real
  // scriptIdPart + name, so the caller can log it once to find spy_9_26's
  // actual hash - same live-discovery step the worm_8_26 -> worm_9_26
  // switch needed on 2026-09-13. Remove once that hash is confirmed and
  // hardcoded into `customScripts` below.
  final List<Map<String, dynamic>> rawSources;
}

const _verifyScriptsExpr = '''(function() {
  var wv = window.TradingViewApi && window.TradingViewApi._activeChartWidgetWV;
  if (!wv) return { error: 'TradingViewApi not found' };
  var chart = wv.value();
  if (!chart) return { error: 'chart widget not found' };
  var legend = [];
  var items = document.querySelectorAll('[data-qa-id=legend-source-item]');
  for (var i = 0; i < items.length; i++) {
    var el = items[i];
    var t = el.querySelector('.title-quatTGAC');
    legend.push({ entity: el.getAttribute('data-entity-id'), title: t ? t.textContent.trim() : '' });
  }
  var sources = [];
  try {
    var all = chart._chartWidget.model().model().dataSources();
    for (var j = 0; j < all.length; j++) {
      var s = all[j];
      var part = '';
      var name = '';
      try { var m = s.metaInfo(); part = m ? (m.scriptIdPart || '') : ''; name = m ? (m.description || m.shortDescription || '') : ''; } catch (e) {}
      sources.push({ scriptIdPart: part, name: name });
    }
  } catch (e) {}
  return { legend: legend, sources: sources };
})()''';

/// Checks both custom scripts are present via legend + dataSources. MSB
/// counts present only via its real loaded title/scriptIdPart, NEVER the
/// stuck-stub title ("EMA & HLOTT & MSB/OB").
Future<VerifyResult> verifyCustomScripts(CdpClient cdp) async {
  final state = await cdp.evaluate(_verifyScriptsExpr) as Map<String, dynamic>?;
  if (state?['error'] != null)
    return VerifyResult(ok: false, error: state!['error'] as String);

  final legend = ((state?['legend'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  final sources = ((state?['sources'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  final titles = legend.map((l) => (l['title'] ?? '').toString()).toList();
  final sourceIds = sources
      .map((s) => (s['scriptIdPart'] ?? '').toString())
      .toList();
  final sourceNames = sources.map((s) => (s['name'] ?? '').toString()).toList();

  final msb =
      sourceIds.contains(customScripts[0].scriptIdPart) ||
      sourceNames.any((n) => n.contains('worm_10_26')) ||
      titles.any((t) => t.contains('worm_10_26'));
  final rsi =
      sourceIds.contains(customScripts[1].scriptIdPart) ||
      titles.any((t) => t.contains('spy_9_26')) ||
      sourceNames.any((n) => n.contains('spy_9_26'));

  return VerifyResult(
    ok: msb && rsi,
    msbPresent: msb,
    rsiPresent: rsi,
    rawSources: sources,
  );
}

class SetChartViewResult {
  const SetChartViewResult({
    required this.ok,
    this.error,
    this.state,
    this.switched = false,
  });
  final bool ok;
  final String? error;
  final ChartState? state;

  /// True only when a real `setSymbol`/`setResolution` call fired this time,
  /// so callers know the indicator scripts' own plot data may still be
  /// catching up with the chart's label.
  final bool switched;
}

/// Letter resolutions ('D','W','M') land internally as '1D'/'1W'/'1M' —
/// normalize both sides before comparing, or a same-value switch is falsely
/// treated as "changed" (or vice versa) and either spuriously reloads or
/// never confirms.
String _normalizeResolution(String r) {
  final upper = r.toUpperCase();
  final match = RegExp(r'^1?([DWM])$').firstMatch(upper);
  return match != null ? match.group(1)! : upper;
}

/// Strips exchange prefix ("BINANCE:"), quote suffix ("USDT"), and any
/// ".PERP"/"_" segment - same convention as engine_service.dart's
/// `_baseOf` - so a bare request ("ETHUSDT") correctly matches the chart's
/// own fully-resolved report ("BINANCE:ETHUSDT") instead of only ever
/// matching an exact string that was never going to come back that way.
String _tickerBase(String s) {
  var v = s.trim().toUpperCase();
  if (v.contains(':')) v = v.split(':').last;
  if (v.contains('/')) v = v.split('/').first;
  if (v.contains('_')) v = v.split('_').first;
  return v.replaceAll('USDT', '').replaceAll('.PERP', '');
}

bool _sameBase(String a, String b) => _tickerBase(a) == _tickerBase(b);

/// Bar length in seconds for a chart resolution ('60' -> 3600, 'D' ->
/// 86400, 'W' -> 604800); null for anything not checked ('M', seconds).
int? resolutionSeconds(String resolution) {
  final r = _normalizeResolution(resolution);
  if (r == 'D') return 86400;
  if (r == 'W') return 604800;
  final minutes = int.tryParse(r);
  return minutes == null ? null : minutes * 60;
}

/// Whether the chart's BAR DATA really is [expectedSymbol] at [resolution] -
/// null when it is, otherwise the reason it isn't. A chart's label can switch
/// while its series stays mid-load, still holding the previous pair's bars, so
/// reading it would attribute one pair's signals to another. This checks the
/// data itself: series loaded, its own symbol info names the requested pair,
/// and the bars are spaced at the requested resolution.
String? chartDataMismatchReason({
  required bool? loading,
  required String? symbolInfoName,
  required String expectedSymbol,
  required List<int> recentBarTimes,
  String? resolution,
}) {
  if (loading == true) return 'series still loading';
  if (symbolInfoName == null || symbolInfoName.isEmpty) {
    return 'series has no symbol info';
  }
  if (!_sameBase(symbolInfoName, expectedSymbol)) {
    return 'series data is for $symbolInfoName, not $expectedSymbol';
  }
  final expected = resolution == null ? null : resolutionSeconds(resolution);
  if (expected != null) {
    final times = [...recentBarTimes]..sort();
    if (times.length < 2) return 'too few bars loaded';
    var minGap = times[1] - times[0];
    for (var i = 2; i < times.length; i++) {
      final gap = times[i] - times[i - 1];
      if (gap < minGap) minGap = gap;
    }
    if (minGap != expected) {
      return 'bars are ${minGap}s apart, expected ${expected}s for $resolution';
    }
  }
  return null;
}

const _chartDataExpr = '''(function() {
  try {
    var ms = window.TradingViewApi._activeChartWidgetWV.value()._chartWidget.model().mainSeries();
    var loading = typeof ms.isLoading === 'function' ? ms.isLoading() : null;
    var si = typeof ms.symbolInfo === 'function' ? ms.symbolInfo() : null;
    var times = [];
    var bars = ms.bars();
    if (bars && !bars.isEmpty()) {
      var last = bars.lastIndex();
      for (var i = last; i >= bars.firstIndex() && times.length < 6; i--) {
        var v = bars.valueAt(i);
        if (v && typeof v[0] === 'number') times.push(v[0]);
      }
    }
    return { loading: loading, name: si ? (si.name || si.ticker || null) : null, times: times };
  } catch (e) {
    return { error: String(e && e.message || e) };
  }
})()''';

/// Polls the main series until its data is [expectedSymbol] at [resolution] or
/// [timeout] passes; returns the last mismatch reason, or null once verified.
Future<String?> _waitForChartData(
  CdpClient cdp,
  String expectedSymbol,
  String? resolution,
  Duration timeout,
) async {
  final deadline = DateTime.now().add(timeout);
  String? reason;
  while (true) {
    try {
      final res = await cdp.evaluate(_chartDataExpr) as Map<String, dynamic>?;
      reason = res == null
          ? 'no reply from chart'
          : res['error'] != null
          ? 'chart data read failed: ${res['error']}'
          : chartDataMismatchReason(
              loading: res['loading'] as bool?,
              symbolInfoName: res['name'] as String?,
              expectedSymbol: expectedSymbol,
              recentBarTimes: ((res['times'] as List?) ?? const [])
                  .map((t) => (t as num).toInt())
                  .toList(),
              resolution: resolution,
            );
    } catch (e) {
      reason = 'chart data read failed: $e';
    }
    if (reason == null || !DateTime.now().isBefore(deadline)) return reason;
    await Future<void>.delayed(const Duration(milliseconds: 1500));
  }
}

/// Requests more backward history for the active chart, for the retroactive
/// audit when no OPEN1 event exists in the loaded window. `requestMoreData`
/// only takes effect with the viewport at the left edge of the loaded bars, so
/// each round scrolls there first, and rounds chain until one adds nothing -
/// that's the feed's real maximum. The extended window is temporary (the next
/// symbol switch resets it), so callers must re-read immediately.
Future<bool> requestMoreChartHistory(
  CdpClient cdp, {
  int barsToRequest = 5000,
  Duration roundTimeout = const Duration(seconds: 20),
  int maxRounds = 6,
}) async {
  const exprState =
      '''(function() {
    var chart = window.TradingViewApi._activeChartWidgetWV.value()._chartWidget;
    var series = chart.model().mainSeries();
    var bars = series.bars();
    return {
      size: bars.size(),
      firstIndex: bars.size() > 0 ? bars.firstIndex() : null,
      isLoading: series.isLoading ? series.isLoading() : false,
    };
  })()''';

  var grewAtLeastOnce = false;
  for (var round = 0; round < maxRounds; round++) {
    Map<String, dynamic>? before;
    try {
      before = await cdp.evaluate(exprState) as Map<String, dynamic>?;
    } catch (_) {
      break;
    }
    final beforeSize = before?['size'] as int? ?? 0;
    final firstIndex = before?['firstIndex'] as int?;
    if (firstIndex == null) break;

    final exprAct =
        '''(function() {
      var chart = window.TradingViewApi._activeChartWidgetWV.value()._chartWidget;
      var model = chart.model();
      var series = model.mainSeries();
      try { model.timeScale().scrollToBarIndex($firstIndex); } catch (e) {}
      try { series.requestMoreData($barsToRequest); return { ok: true }; }
      catch (e) { return { ok: false, error: String(e && e.message || e) }; }
    })()''';
    try {
      final res = await cdp.evaluate(exprAct) as Map<String, dynamic>?;
      if (res?['ok'] != true) break;
    } catch (_) {
      break;
    }

    var grewThisRound = false;
    final deadline = DateTime.now().add(roundTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      Map<String, dynamic>? state;
      try {
        state = await cdp.evaluate(exprState) as Map<String, dynamic>?;
      } catch (_) {
        continue;
      }
      if (state?['isLoading'] == true) continue;
      final size = state?['size'] as int? ?? 0;
      if (size > beforeSize) {
        grewThisRound = true;
        grewAtLeastOnce = true;
        break;
      }
    }
    if (!grewThisRound) break;
  }
  return grewAtLeastOnce;
}

/// Switches the chart to [symbol]/[resolution] via the widget API, then waits
/// until the chart actually reports the requested values. Only calls
/// setSymbol/setResolution for values that actually changed — a redundant
/// setResolution call triggers a spurious reload that never reports back.
/// Ported 1:1 from lib/chart-state.js `setChartView`.
Future<SetChartViewResult> setChartView(
  CdpClient cdp,
  String? symbol,
  String? resolution, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  ChartState? current;
  try {
    current = await getChartState(cdp);
  } catch (_) {}

  final expr =
      '''(function() {
    var wv = window.TradingViewApi && window.TradingViewApi._activeChartWidgetWV;
    if (!wv) return { error: 'TradingViewApi not found' };
    var chart = wv.value();
    if (!chart) return { error: 'chart widget not found' };
    var out = {};
    var curSym = ${jsonEncode(current?.symbol)};
    var curRes = ${jsonEncode(current?.resolution)};
    var wantSym = ${jsonEncode(symbol)};
    var wantRes = ${jsonEncode(resolution)};
    var symSame = curSym && wantSym && String(curSym) === String(wantSym);
    var resSame = curRes && wantRes && String(curRes).toUpperCase() === String(wantRes).toUpperCase();
    if (!wantSym) symSame = true;
    if (!wantRes) resSame = true;
    if (!symSame && typeof chart.setSymbol === 'function') {
      try { chart.setSymbol(wantSym); out.symbolSet = true; } catch (e) { out.symbolErr = String(e && e.message || e); }
    }
    if (!resSame && typeof chart.setResolution === 'function') {
      try { chart.setResolution(wantRes); out.resolutionSet = true; } catch (e) { out.resolutionErr = String(e && e.message || e); }
    }
    return out;
  })()''';
  final res = await cdp.evaluate(expr) as Map<String, dynamic>?;
  if (res?['error'] != null)
    return SetChartViewResult(ok: false, error: res!['error'] as String);
  final changedAnything =
      res?['symbolSet'] == true ||
      res?['resolutionSet'] == true ||
      res?['symbolErr'] != null ||
      res?['resolutionErr'] != null;
  if (!changedAnything) {
    // Label already matches - still verify the data underneath it.
    final expected = symbol ?? current?.symbol;
    if (expected != null) {
      final reason = await _waitForChartData(
        cdp,
        expected,
        resolution,
        const Duration(seconds: 15),
      );
      if (reason != null) {
        return SetChartViewResult(
          ok: false,
          error: 'chart data not loaded for $expected $resolution: $reason',
          state: current,
        );
      }
    }
    return SetChartViewResult(ok: true, state: current);
  }

  final deadline = DateTime.now().add(timeout);
  ChartState? state;
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    try {
      state = await getChartState(cdp);
    } catch (_) {
      state = null;
    }
    if (state?.symbol == null) continue;
    // Per the user (2026-09-06): a request sent without an exchange
    // prefix (e.g. "ETHUSDT") is deliberately left that way so
    // TradingView's own chart.setSymbol() resolves the exchange itself,
    // exactly like typing it into TradingView's search box - confirmed
    // live via CDP that this genuinely works. But the CHART then reports
    // back the fully-resolved symbol (e.g. "BINANCE:ETHUSDT"), which
    // never equals the bare string that was requested - comparing base
    // tickers instead of exact strings is what lets that resolution
    // still count as success instead of timing out for 45s and failing.
    final symOk = symbol == null || _sameBase(state!.symbol!, symbol);
    final resOk =
        resolution == null ||
        _normalizeResolution(state!.resolution ?? '') ==
            _normalizeResolution(resolution);
    if (symOk && resOk) {
      // The label switching is not enough - wait (within the same overall
      // timeout) for the series itself to load this pair's bars.
      final remaining = deadline.difference(DateTime.now());
      final reason = await _waitForChartData(
        cdp,
        symbol ?? state!.symbol!,
        resolution,
        remaining.isNegative ? Duration.zero : remaining,
      );
      if (reason != null) {
        return SetChartViewResult(
          ok: false,
          error:
              'chart data not loaded for ${symbol ?? state!.symbol} $resolution: $reason',
          state: state,
        );
      }
      return SetChartViewResult(ok: true, state: state, switched: true);
    }
  }
  return SetChartViewResult(
    ok: false,
    error: 'timeout waiting for $symbol $resolution',
    state: state,
  );
}

/// TradingView's internal chart-style numeric codes - `1` is regular
/// Candles (the default this app has always used), `8` is Heikin Ashi.
/// Confirmed live via CDP, 2026-10-25, against the real chart (set then
/// read back `mainSeries().properties().childs().style`, matches
/// TradingView's own public Charting Library API). Needed for the Worm10
/// Hybrid Decision technique's 1H signal chart - every other chart/read
/// in this app (the Daily/Weekly range read, the old worm_9_26 technique)
/// never touches this and stays on regular Candles.
const int chartStyleCandles = 1;
const int chartStyleHeikinAshi = 8;

/// Reads the main series' current chart style (candle/bar type) - see
/// [chartStyleCandles]/[chartStyleHeikinAshi].
Future<int?> getChartStyle(CdpClient cdp) async {
  const expr = r'''(function() {
    try {
      var wv = window.TradingViewApi._activeChartWidgetWV;
      var chart = wv.value()._chartWidget;
      return chart.model().model().mainSeries().properties().childs().style.value();
    } catch (e) { return null; }
  })()''';
  final result = await cdp.evaluate(expr);
  return (result as num?)?.toInt();
}

/// Sets the main series' chart style directly via the properties setter -
/// confirmed live (2026-10-25) this is a real property write, not a UI
/// click, so none of the dialog/button fragility this file's other
/// automation has to work around applies here. No-ops if already at
/// [style]. Returns the style actually read back after the set, for the
/// caller to verify rather than trust blindly.
Future<int?> setChartStyle(CdpClient cdp, int style) async {
  final current = await getChartStyle(cdp);
  if (current == style) return current;
  final expr =
      '''(function() {
    try {
      var wv = window.TradingViewApi._activeChartWidgetWV;
      var chart = wv.value()._chartWidget;
      chart.model().model().mainSeries().properties().childs().style.setValue($style);
      return chart.model().model().mainSeries().properties().childs().style.value();
    } catch (e) { return null; }
  })()''';
  final result = await cdp.evaluate(expr);
  return (result as num?)?.toInt();
}

/// Lists every TradingView page target currently visible to CDP (not just
/// the first match) — a diagnostic helper, distinct from getChartTarget()
/// which is used on the hot path and only needs the one chart page.
Future<List<CdpTarget>> getActiveCharts(String host, int port) =>
    listTradingViewTargets(host, port);
