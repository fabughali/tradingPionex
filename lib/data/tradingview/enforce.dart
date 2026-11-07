import 'dart:convert';

import 'cdp_client.dart';

/// Keeps exactly the two custom scripts attached and dialogs dismissed —
/// ported 1:1 from lib/enforce.js. This automation is the hard-won result of
/// real live debugging (see PRD §4.4 "Critical gotchas"): the legend row's
/// bounding box spans almost the full chart pane (mostly blank canvas), so a
/// naive hover-and-click on it never arms anything; the trash button is
/// ALWAYS present in the DOM (TradingView fades it via opacity/pointer-events,
/// not display:none) so `offsetParent` alone is a false positive. The fix:
/// dispatch a REAL mouse event onto the indicator NAME text specifically,
/// wait for React to arm the trash button, re-query it, gate on computed
/// opacity>0 and pointer-events!=='none', confirm via elementFromPoint that
/// nothing covers it, then click for real. NEVER call `s.destroy()` on a
/// study dataSource — it corrupts metaInfo until a full TradingView restart.

class EnforceScript {
  const EnforceScript({
    required this.key,
    required this.searchTitle,
    required this.scriptIdPart,
  });
  final String key;
  final String searchTitle;
  final String scriptIdPart;
}

const _enforceScripts = [
  // URGENT fix 2026-09-16, per the user ("instead of using combined
  // indicator, i want you to use spy_9_26" then, live: "hangup and not
  // doing anything in trading view"): searching "My Scripts" by the OLD
  // long title found nothing (the script saved under that name is gone),
  // so every enforcement pass stripped the chart bare and then failed to
  // re-add anything, forever. Switched to searching by the short name
  // directly, same as worm_10_26 below already does.
  EnforceScript(
    key: 'RSI',
    searchTitle: 'spy_9_26',
    scriptIdPart: 'USER;f40c0a529f954b648be8f2b530d43d3f',
  ),
  // Worm10 Hybrid Decision technique (2026-10-25, per the user): worm_9_26
  // and its whole decision model are retired entirely, not kept alongside
  // this - replaced by worm_10_26, a genuinely different saved script
  // (confirmed live via CDP: different scriptIdPart, not a rename).
  // Carries the same HH/LL swing plots worm_9_26 had, plus the zigzag
  // BUY/SELL and discrete Supertrend Buy/Sell pairs the new technique
  // needs - see `readWorm10Signals` in signals_reader.dart.
  EnforceScript(
    key: 'MSB',
    searchTitle: 'worm_10_26',
    scriptIdPart: 'USER;125eec083a7d45479dac940b5af76dc7',
  ),
];

Future<bool> waitForChartApiReady(
  CdpClient cdp, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  const probeExpr = '''(function() {
    try {
      var wv = window.TradingViewApi && window.TradingViewApi._activeChartWidgetWV;
      var widget = wv && wv.value && wv.value();
      return !!(widget && widget._chartWidget && widget._chartWidget.model && widget._chartWidget.model());
    } catch (e) { return false; }
  })()''';
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    bool ready = false;
    try {
      ready =
          await cdp
                  .evaluate(probeExpr)
                  .timeout(const Duration(seconds: 3), onTimeout: () => false)
              as bool? ??
          false;
    } catch (_) {}
    if (ready) return true;
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  return false;
}

class _EnforceChartState {
  const _EnforceChartState({
    required this.sourceScriptIdParts,
    required this.legendTitles,
  });
  final List<String> sourceScriptIdParts;
  final List<String> legendTitles;
}

const _getEnforceStateExpr = '''(function() {
  var wv = window.TradingViewApi._activeChartWidgetWV;
  var widget = wv.value();
  var out = { sources: [], legend: [] };
  var sources = widget._chartWidget.model().model().dataSources();
  for (var i = 0; i < sources.length; i++) {
    var s = sources[i];
    var info = { scriptIdPart: '' };
    try { var m = s.metaInfo(); info.scriptIdPart = m ? (m.scriptIdPart || '') : ''; } catch(e) {}
    out.sources.push(info);
  }
  var items = document.querySelectorAll('[data-qa-id=legend-source-item]');
  for (var j = 0; j < items.length; j++) {
    var el = items[j];
    var t = el.querySelector('.title-quatTGAC');
    out.legend.push({ entity: el.getAttribute('data-entity-id'), title: t ? t.textContent.trim() : '' });
  }
  return out;
})()''';

Future<_EnforceChartState> _getEnforceState(CdpClient cdp) async {
  final raw = await cdp.evaluate(_getEnforceStateExpr) as Map<String, dynamic>?;
  final sources = ((raw?['sources'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  final legend = ((raw?['legend'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  return _EnforceChartState(
    sourceScriptIdParts: sources
        .map((s) => (s['scriptIdPart'] ?? '').toString())
        .toList(),
    legendTitles: legend.map((l) => (l['title'] ?? '').toString()).toList(),
  );
}

class _BothOpen {
  const _BothOpen(this.msb, this.rsi);
  final bool msb;
  final bool rsi;
}

_BothOpen _bothOpen(_EnforceChartState state) {
  final all =
      '${state.sourceScriptIdParts.join(' ')} ${state.legendTitles.join(' ')}';
  final msb =
      all.contains('USER;125eec083a7d45479dac940b5af76dc7') ||
      RegExp('worm_10_26', caseSensitive: false).hasMatch(all);
  final rsi =
      all.contains('USER;f40c0a529f954b648be8f2b530d43d3f') ||
      RegExp(
        'RSI|Stochastic|VAPI|Combined_Indicators|spy_9_26',
        caseSensitive: false,
      ).hasMatch(all);
  return _BothOpen(msb, rsi);
}

Future<void> _dispatchMouseMove(CdpClient cdp, double x, double y) => cdp.send(
  'Input.dispatchMouseEvent',
  {'type': 'mouseMoved', 'x': x, 'y': y, 'button': 'none'},
);

Future<void> _dispatchMouseClick(CdpClient cdp, double x, double y) async {
  await cdp.send('Input.dispatchMouseEvent', {
    'type': 'mouseMoved',
    'x': x,
    'y': y,
    'button': 'none',
  });
  await Future<void>.delayed(const Duration(milliseconds: 60));
  await cdp.send('Input.dispatchMouseEvent', {
    'type': 'mousePressed',
    'x': x,
    'y': y,
    'button': 'left',
    'clickCount': 1,
  });
  await Future<void>.delayed(const Duration(milliseconds: 60));
  await cdp.send('Input.dispatchMouseEvent', {
    'type': 'mouseReleased',
    'x': x,
    'y': y,
    'button': 'left',
    'clickCount': 1,
  });
}

class _Point {
  const _Point(this.x, this.y);
  final double x;
  final double y;
}

class _LegendItemInfo {
  const _LegendItemInfo({
    required this.entity,
    required this.title,
    this.titlePos,
    this.trash,
  });
  final String? entity;
  final String title;
  final _Point? titlePos;
  final _Point? trash;
}

const _legendItemsExpr = '''(function() {
  function rectOf(el) {
    if (!el || el.offsetParent === null) return null;
    var r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) return null;
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  }
  function interactableRectOf(el) {
    if (!el || el.offsetParent === null) return null;
    var cs = getComputedStyle(el);
    if (parseFloat(cs.opacity) === 0) return null;
    if (cs.pointerEvents === 'none') return null;
    var r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) return null;
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  }
  var out = [];
  var items = document.querySelectorAll('[data-qa-id=legend-source-item]');
  for (var i = 0; i < items.length; i++) {
    var el = items[i];
    var t = el.querySelector('.title-quatTGAC');
    var title = t ? t.textContent.trim() : '';
    var trash = el.querySelector('[data-qa-id=legend-delete-action]');
    out.push({
      entity: el.getAttribute('data-entity-id'),
      title: title,
      titlePos: rectOf(t),
      trash: interactableRectOf(trash),
    });
  }
  return out;
})()''';

Future<List<_LegendItemInfo>> _getLegendItemsInfo(CdpClient cdp) async {
  final raw = (await cdp.evaluate(_legendItemsExpr) as List?) ?? const [];
  return raw.cast<Map<String, dynamic>>().map((item) {
    Map<String, dynamic>? p(String key) =>
        (item[key] as Map?)?.cast<String, dynamic>();
    final titlePos = p('titlePos');
    final trash = p('trash');
    return _LegendItemInfo(
      entity: item['entity'] as String?,
      title: (item['title'] ?? '').toString(),
      titlePos: titlePos == null
          ? null
          : _Point(
              (titlePos['x'] as num).toDouble(),
              (titlePos['y'] as num).toDouble(),
            ),
      trash: trash == null
          ? null
          : _Point(
              (trash['x'] as num).toDouble(),
              (trash['y'] as num).toDouble(),
            ),
    );
  }).toList();
}

Future<bool> _elementAtPointMatches(
  CdpClient cdp,
  double x,
  double y,
  String qaId,
) async {
  final expr =
      '''(function() {
    var el = document.elementFromPoint($x, $y);
    while (el) {
      if (el.getAttribute && el.getAttribute('data-qa-id') === ${jsonEncode(qaId)}) return true;
      el = el.parentElement;
    }
    return false;
  })()''';
  return await cdp.evaluate(expr) as bool? ?? false;
}

class RemovedSourceResult {
  const RemovedSourceResult({
    required this.entity,
    required this.title,
    required this.ok,
    this.reason,
  });
  final String? entity;
  final String title;
  final bool ok;
  final String? reason;
}

/// Replicates the user's manual action: hover the indicator NAME, then click
/// the trash icon — using real CDP mouse events. Runs up to 3 rounds to mop
/// up anything a promo dialog blocked mid-way.
Future<List<RemovedSourceResult>> removeAllSources(CdpClient cdp) async {
  final removed = <RemovedSourceResult>[];
  for (var round = 0; round < 3; round++) {
    final items = await _getLegendItemsInfo(cdp);
    if (items.isEmpty) break;

    for (final item in items) {
      final blocking = await findDismissTarget(cdp);
      if (blocking != null) await dismissUpgradeDialog(cdp);

      if (item.titlePos == null) {
        removed.add(
          RemovedSourceResult(
            entity: item.entity,
            title: item.title,
            ok: false,
            reason: 'title not visible',
          ),
        );
        continue;
      }

      await _dispatchMouseMove(cdp, item.titlePos!.x, item.titlePos!.y);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final refreshed = await _getLegendItemsInfo(cdp);
      final match = refreshed.cast<_LegendItemInfo?>().firstWhere(
        (r) => r?.entity == item.entity,
        orElse: () => null,
      );
      if (match?.trash == null) {
        removed.add(
          RemovedSourceResult(
            entity: item.entity,
            title: item.title,
            ok: false,
            reason: 'trash not interactable after hover',
          ),
        );
        continue;
      }

      await _dispatchMouseMove(cdp, match!.trash!.x, match.trash!.y);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final onTarget = await _elementAtPointMatches(
        cdp,
        match.trash!.x,
        match.trash!.y,
        'legend-delete-action',
      );
      if (!onTarget) {
        removed.add(
          RemovedSourceResult(
            entity: item.entity,
            title: item.title,
            ok: false,
            reason: 'covered at click point',
          ),
        );
        continue;
      }

      await _dispatchMouseClick(cdp, match.trash!.x, match.trash!.y);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      removed.add(
        RemovedSourceResult(entity: item.entity, title: item.title, ok: true),
      );
    }

    final after = await _getLegendItemsInfo(cdp);
    if (after.isEmpty) break;
  }
  return removed;
}

Future<void> _closeAllDialogs(CdpClient cdp) async {
  await cdp.evaluate('''(function() {
    var btns = document.querySelectorAll('[role=dialog] button');
    for (var i = 0; i < btns.length; i++) {
      if (btns[i].offsetParent !== null && (btns[i].getAttribute('data-qa-id') === 'close' || (btns[i].textContent||'').indexOf('Close') !== -1)) btns[i].click();
    }
  })()''');
  await Future<void>.delayed(const Duration(seconds: 1));
}

class DismissTarget {
  const DismissTarget({required this.via, required this.x, required this.y});
  final String via;
  final double x;
  final double y;
}

const _findDismissTargetExpr = '''(function() {
  function visible(el) { return !!el && el.offsetParent !== null; }
  function rectOf(el) {
    var r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) return null;
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  }

  var known = document.querySelector('[data-qa-id=promo-dialog-close-button]');
  if (visible(known)) {
    var r0 = rectOf(known);
    if (r0) return { via: 'promo-dialog-close-button', rect: r0 };
  }

  var dialogs = document.querySelectorAll('[role=dialog]');
  for (var i = 0; i < dialogs.length; i++) {
    var d = dialogs[i];
    if (!visible(d)) continue;
    var text = (d.textContent || '').replace(/\\s+/g, ' ').toLowerCase();
    if (text.indexOf('indicators, metrics, and strategies') !== -1) continue;
    var btns = d.querySelectorAll('button, [class*=close], [aria-label]');
    for (var j = 0; j < btns.length; j++) {
      var b = btns[j];
      if (!visible(b)) continue;
      var label = (b.getAttribute('aria-label') || b.getAttribute('title') || b.textContent || '').trim().toLowerCase();
      if (b.getAttribute('data-qa-id') === 'promo-dialog-close-button' || b.getAttribute('data-qa-id') === 'close' || label === 'close' || /^x\$/.test(label)) {
        var r1 = rectOf(b);
        if (r1) return { via: 'dialog close btn', rect: r1 };
      }
    }
    var dismissBtns = d.querySelectorAll('button');
    for (var k = 0; k < dismissBtns.length; k++) {
      var db = dismissBtns[k];
      if (!visible(db)) continue;
      var dt = (db.textContent || '').trim().toLowerCase();
      if (/not now|maybe later|later|no thanks|keep using the free|continue free|dismiss|got it/i.test(dt)) {
        var r2 = rectOf(db);
        if (r2) return { via: dt.slice(0, 40), rect: r2 };
      }
    }
  }

  var all = document.querySelectorAll('body *');
  for (var m = 0; m < all.length; m++) {
    var el = all[m];
    if (!visible(el) || el.children.length === 0) continue;
    var rr = el.getBoundingClientRect();
    if (rr.width < window.innerWidth * 0.5 || rr.height < window.innerHeight * 0.5) continue;
    var t = (el.textContent || '').replace(/\\s+/g, ' ').toLowerCase();
    if (!/upgrade|go pro|free plan|start trial|subscribe|unlock|offer|maximum available on your plan/i.test(t)) continue;
    var cbs = el.querySelectorAll('button, [aria-label], [class*=close]');
    for (var n = 0; n < cbs.length; n++) {
      var cb = cbs[n];
      if (!visible(cb)) continue;
      var label2 = (cb.getAttribute('aria-label') || cb.getAttribute('title') || cb.textContent || '').trim().toLowerCase();
      if (cb.getAttribute('data-qa-id') === 'promo-dialog-close-button' || label2 === 'close' || /^x\$/.test(label2) || /not now|maybe later|later|no thanks|keep using the free|continue free|dismiss|got it/i.test(label2)) {
        var r3 = rectOf(cb);
        if (r3) return { via: 'overlay ' + label2.slice(0, 30), rect: r3 };
      }
    }
  }
  return null;
})()''';

Future<DismissTarget?> findDismissTarget(CdpClient cdp) async {
  final raw =
      await cdp.evaluate(_findDismissTargetExpr) as Map<String, dynamic>?;
  if (raw == null) return null;
  final rect = (raw['rect'] as Map).cast<String, dynamic>();
  return DismissTarget(
    via: raw['via'] as String,
    x: (rect['x'] as num).toDouble(),
    y: (rect['y'] as num).toDouble(),
  );
}

class DismissResult {
  const DismissResult({required this.closed, this.via});
  final bool closed;
  final String? via;
}

/// Free TradingView accounts sometimes show an upgrade/offer dialog
/// (typically triggered by opening ~3 indicators at once). Must be dismissed
/// BEFORE opening any script — it blocks the Indicators dialog from
/// rendering, and can reappear mid-removal too.
Future<DismissResult> dismissUpgradeDialog(CdpClient cdp) async {
  for (var attempt = 0; attempt < 3; attempt++) {
    final target = await findDismissTarget(cdp);
    if (target == null) return const DismissResult(closed: false);

    await _dispatchMouseMove(cdp, target.x, target.y);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await _dispatchMouseClick(cdp, target.x, target.y);
    await Future<void>.delayed(const Duration(milliseconds: 700));

    final stillThere = await findDismissTarget(cdp);
    if (stillThere == null) return DismissResult(closed: true, via: target.via);
  }
  return const DismissResult(closed: false, via: 'gave up after 3 attempts');
}

/// Real-mouse-event click at [x]/[y] - move, settle 150ms, then press+
/// release via [_dispatchMouseClick]. Fixed 2026-10-25, per the user, after
/// confirmed-live flakiness: a synthetic `el.click()` on the "open
/// indicators dialog" button, the "My Scripts" tab, and a script row in
/// that list is silently ignored by TradingView often enough to matter -
/// confirmed by repeated live failures adding worm_10_26 this exact way,
/// immediately fixed by switching to a real dispatched event. Matches the
/// same real-click approach [dismissUpgradeDialog] already used.
Future<void> _realClickAt(CdpClient cdp, double x, double y) async {
  await _dispatchMouseMove(cdp, x, y);
  await Future<void>.delayed(const Duration(milliseconds: 150));
  await _dispatchMouseClick(cdp, x, y);
}

/// Center point of the element matching [selector] that is genuinely on
/// top at its own center point, or null. [selector] can match more than
/// one element at once (confirmed live, 2026-10-25: TradingView Desktop
/// kept 3 stale copies of the toolbar, one per open chart tab, all
/// reporting `offsetParent !== null` - the first match `querySelector`
/// would pick wasn't necessarily the one actually on top) - checking
/// `offsetParent` alone is not enough, same lesson this file's own top
/// doc comment already drew for the legend row/trash button. Confirms via
/// `elementFromPoint` that each candidate is really clickable at its own
/// center before trusting its rect, same safeguard [_elementAtPointMatches]
/// already applies elsewhere in this file.
Future<_Point?> _rectOfSelector(CdpClient cdp, String selector) async {
  final expr =
      '''(function() {
    var all = document.querySelectorAll(${jsonEncode(selector)});
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (!el || el.offsetParent === null) continue;
      var r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) continue;
      var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
      var atPoint = document.elementFromPoint(cx, cy);
      if (atPoint !== el && !(atPoint && el.contains && el.contains(atPoint))) continue;
      return { x: cx, y: cy };
    }
    return null;
  })()''';
  final raw = await cdp.evaluate(expr) as Map<String, dynamic>?;
  if (raw == null) return null;
  return _Point((raw['x'] as num).toDouble(), (raw['y'] as num).toDouble());
}

/// Center point of the "My Scripts" row whose text contains [needle], or
/// null if not currently visible. The row only stays rendered for ~2
/// seconds before TradingView's list view clears itself (confirmed live,
/// repeatedly) - callers must click the returned rect immediately, not
/// search again first.
Future<_Point?> _findMyScriptsRowRect(CdpClient cdp, String needle) async {
  final expr =
      '''(function() {
    var needle = ${jsonEncode(needle)};
    var all = document.querySelectorAll('.contentWrapper-uumrt5rh *');
    for (var j = 0; j < all.length; j++) {
      var el = all[j];
      if (el.children.length > 0 || el.offsetParent === null) continue;
      var t = (el.textContent || '').trim();
      if (t.indexOf(needle) !== -1) {
        var rowEl = el.closest('[role=button], [class*=item], .main-cDWXFIqV, [class*=main-]') || el.parentElement;
        if (rowEl) {
          var r = rowEl.getBoundingClientRect();
          if (r.width > 0 && r.height > 0) {
            return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
          }
        }
      }
    }
    return null;
  })()''';
  final raw = await cdp.evaluate(expr) as Map<String, dynamic>?;
  if (raw == null) return null;
  return _Point((raw['x'] as num).toDouble(), (raw['y'] as num).toDouble());
}

Future<bool> _addOneViaMyScripts(CdpClient cdp, EnforceScript script) async {
  await _closeAllDialogs(cdp);
  await dismissUpgradeDialog(cdp);
  await Future<void>.delayed(const Duration(seconds: 1));

  final openRect = await _rectOfSelector(
    cdp,
    'button[data-name=open-indicators-dialog]',
  );
  if (openRect == null) return false;
  await _realClickAt(cdp, openRect.x, openRect.y);
  await Future<void>.delayed(const Duration(seconds: 3));

  final tabRect = await _rectOfSelector(
    cdp,
    '[data-qa-id="indicator-sidebar-item-my-scripts"]',
  );
  if (tabRect == null) return false;
  await _realClickAt(cdp, tabRect.x, tabRect.y);
  await Future<void>.delayed(const Duration(milliseconds: 1500));

  _Point? rowRect;
  for (var i = 0; i < 10; i++) {
    rowRect = await _findMyScriptsRowRect(cdp, script.searchTitle);
    if (rowRect != null) break;
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  if (rowRect == null) {
    await _closeAllDialogs(cdp);
    return false;
  }

  await _realClickAt(cdp, rowRect.x, rowRect.y);
  await Future<void>.delayed(const Duration(seconds: 2));

  await _closeAllDialogs(cdp);
  await Future<void>.delayed(const Duration(seconds: 2));
  return true;
}

class EnforceResult {
  const EnforceResult({
    required this.status,
    this.error,
    this.removed = const [],
    this.addedOk = const {},
    this.finalMsb = false,
    this.finalRsi = false,
  });
  final String status;
  final String? error;
  final List<RemovedSourceResult> removed;
  final Map<String, bool> addedOk;
  final bool finalMsb;
  final bool finalRsi;
}

/// Removes every study except the two custom scripts, through the chart API
/// (`removeEntity`, never `destroy()`), and returns how many were removed.
/// Works on a background tab, where the legend and its trash buttons are
/// never drawn.
Future<int> _removeOtherStudiesViaApi(CdpClient cdp) async {
  final n = await cdp.evaluate('''(function() {
    var keepParts = ${jsonEncode(_enforceScripts.map((s) => s.scriptIdPart).toList())};
    var keepNames = ${jsonEncode(_enforceScriptNames)};
    var ac = window.TradingViewApi.activeChart();
    var removed = 0;
    ac.getAllStudies().forEach(function (s) {
      var part = '';
      try { part = ac.getStudyById(s.id).getStudyId(); } catch (e) {}
      var kept = keepParts.some(function (k) { return String(part).indexOf(k) !== -1; }) ||
        keepNames.some(function (k) { return String(s.name).indexOf(k) !== -1; });
      if (kept) return;
      try { ac.removeEntity(s.id); removed++; } catch (e) {}
    });
    return removed;
  })()''');
  return (n as num?)?.toInt() ?? 0;
}

/// Names TradingView reports for the two scripts once loaded (their Pine
/// titles, not the short saved names).
const _enforceScriptNames = [
  'spy_9_26',
  'worm_10_26',
  'RSI & Vol & Stochastic RSI & VAPI',
  'Footprint/VFAS/EMA/HLOTT/MSB/OB/AlphaTrend/ZigZag++/SuperTrend',
];

/// The insert-API path of [enforceCustomScripts]: null when it could not get
/// both scripts on, so the caller falls back to the click path.
Future<EnforceResult?> _enforceViaApi(CdpClient cdp) async {
  try {
    await _closeAllDialogs(cdp);
    await _removeOtherStudiesViaApi(cdp);
    final addedOk = <String, bool>{};
    var state = _bothOpen(await _getEnforceState(cdp));
    for (final script in _enforceScripts) {
      final present = script.key == 'MSB' ? state.msb : state.rsi;
      addedOk[script.key] = present || await _addViaInsertApi(cdp, script);
    }
    for (var i = 0; i < 20; i++) {
      state = _bothOpen(await _getEnforceState(cdp));
      if (state.msb && state.rsi) break;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    if (!state.msb || !state.rsi) return null;
    return EnforceResult(
      status: 'ok',
      addedOk: addedOk,
      finalMsb: true,
      finalRsi: true,
    );
  } catch (_) {
    return null;
  }
}

/// Adds one saved Pine script through TradingView's own insert service, the
/// same call its "My scripts" list makes - no dialog and no clicks. Found
/// live 2026-11-07: with two apps sharing one TradingView, this app's tab is
/// usually the background tab, which is never drawn (0 frames a second), so
/// the Indicators dialog's script list never renders and the click path can
/// never find the row. This call works whether the tab is in front or not.
Future<bool> _addViaInsertApi(CdpClient cdp, EnforceScript script) async {
  try {
    final result = await cdp.evaluate('''(async function() {
      var svc = window.TradingViewApi._studyMarket._insertStudyService;
      var mi = await Promise.race([
        svc.insertStudy({descriptor: {type: "pine", pineId: ${jsonEncode(script.scriptIdPart)},
          pineVersion: "last"}, insertionInfo: {}}),
        new Promise(function (r) { setTimeout(function () { r(null); }, 30000); })]);
      return mi ? String(mi.id || '') : '';
    })()''');
    return (result as String? ?? '').contains(script.scriptIdPart);
  } catch (_) {
    return false;
  }
}

/// End-to-end: keep only the two custom scripts and add whichever is
/// missing, then verify. Adds through TradingView's insert API first (works
/// on a background tab), falling back to the original remove-all + "My
/// scripts" click path (lib/enforce.js) only if that fails. Idempotent.
Future<EnforceResult> enforceCustomScripts(String host, int port) async {
  final cdp = await connectToChart(host, port);
  try {
    final apiReady = await waitForChartApiReady(cdp);
    if (!apiReady) {
      return const EnforceResult(
        status: 'blocked',
        error: 'TradingView chart API did not become ready in time',
      );
    }

    final viaApi = await _enforceViaApi(cdp);
    if (viaApi != null) return viaApi;

    // Step 1: close ALL currently open indicators (free-account 2-indicator
    // limit; TradingView restores last-open indicators on every launch) and
    // any dialog sitting on top - a subscription/upgrade prompt or any
    // other open dialog would otherwise block removeAllSources' clicks.
    await _closeAllDialogs(cdp);
    await dismissUpgradeDialog(cdp);
    final removed = await removeAllSources(cdp);
    await Future<void>.delayed(const Duration(seconds: 2));

    final afterRemoval = await _getEnforceState(cdp);
    if (afterRemoval.legendTitles.isNotEmpty) {
      return EnforceResult(
        status: 'blocked',
        removed: removed,
        finalMsb: false,
        finalRsi: false,
      );
    }

    final addedOk = <String, bool>{};
    for (final script in _enforceScripts) {
      addedOk[script.key] = await _addOneViaMyScripts(cdp, script);
    }

    // Wait for loading stubs to resolve. Per the user (2026-09-05): a
    // subscription/limit dialog can pop up right as the second custom
    // indicator is added (a common free-tier prompt) and silently block it
    // from ever finishing loading - previously nothing here dismissed it,
    // so the indicator sat stuck on its generic stub title for the full
    // wait and enforcement gave up, leaving a broken/duplicate chart state
    // on the next attempt. Dismiss on every iteration, not just at the
    // start of Step 1.
    var check = const _BothOpen(false, false);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      await dismissUpgradeDialog(cdp);
      check = _bothOpen(await _getEnforceState(cdp));
      if (check.msb && check.rsi) break;
    }

    // Cleanup: remove any leftover legend stubs so exactly the two custom
    // scripts remain (free account limit is 2). Protects both by
    // scriptIdPart AND by title, since a still-loading stub carries an empty
    // scriptIdPart.
    await cdp.evaluate('''(function() {
      var wv = window.TradingViewApi._activeChartWidgetWV;
      var widget = wv.value();
      var appModel = widget._chartWidget.model().model();
      var keptParts = ['USER;125eec083a7d45479dac940b5af76dc7', 'USER;f40c0a529f954b648be8f2b530d43d3f'];
      var scriptTitles = ['worm_10_26', 'spy_9_26'];
      var items = document.querySelectorAll('[data-qa-id=legend-source-item]');
      var legend = [];
      for (var j = 0; j < items.length; j++) {
        var el = items[j];
        var t = el.querySelector('.title-quatTGAC');
        legend.push({ entity: el.getAttribute('data-entity-id'), title: t ? t.textContent.trim() : '' });
      }
      var sources = appModel.dataSources();
      var byEntity = {};
      for (var i = 0; i < sources.length; i++) {
        var s = sources[i];
        var part = '';
        var eid = null;
        try { var m = s.metaInfo(); part = m ? (m.scriptIdPart || '') : ''; } catch(e) {}
        try { eid = s.entityId ? s.entityId() : null; } catch(e) {}
        if (eid) byEntity[eid] = part;
      }
      for (var k = 0; k < legend.length; k++) {
        var item = legend[k];
        var part = byEntity[item.entity] || '';
        var titleIsScript = scriptTitles.some(function (st) { return item.title.indexOf(st) !== -1; });
        if (keptParts.indexOf(part) !== -1 || titleIsScript) continue;
        try { widget.removeEntity(item.entity); } catch(e) {}
      }
    })()''');

    final finalState = await _getEnforceState(cdp);
    final finalCheck = _bothOpen(finalState);
    return EnforceResult(
      status: addedOk.values.every((v) => v) ? 'ok' : 'partial',
      removed: removed,
      addedOk: addedOk,
      finalMsb: finalCheck.msb,
      finalRsi: finalCheck.rsi,
    );
  } finally {
    cdp.close();
  }
}
