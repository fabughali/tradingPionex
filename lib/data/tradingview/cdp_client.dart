import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/core_constants.dart';

/// Raw Chrome DevTools Protocol client over a plain WebSocket — ported 1:1
/// from lib/cdp.js. This is NOT a browser-automation framework: CDP is just
/// JSON-RPC over a WebSocket, and `evaluate()` runs a JavaScript expression
/// string inside the target page (TradingView Desktop's own renderer) and
/// returns its value. The JS strings themselves are ported verbatim in
/// signals_reader.dart / chart_state.dart / enforce.dart / watchlist_reader.dart —
/// this file only owns the transport.
class CdpException implements Exception {
  CdpException(this.message);
  final String message;
  @override
  String toString() => 'CdpException: $message';
}

class _PendingRequest {
  _PendingRequest(this.completer, this.timer);
  final Completer<Map<String, dynamic>?> completer;
  final Timer timer;
}

class CdpClient {
  CdpClient(this._socket, {Duration timeout = CoreConstants.cdpRequestTimeout})
    : _timeout = timeout {
    _subscription = _socket.listen(
      _onMessage,
      onDone: () => _fail('websocket closed'),
      onError: (_) => _fail('websocket error'),
    );
  }

  final WebSocket _socket;
  final Duration _timeout;
  final Map<int, _PendingRequest> _pending = {};
  late final StreamSubscription _subscription;
  int _id = 0;

  /// Mirrors the original's `cdp.dead` flag — set once the socket is known
  /// unusable, so callers reconnect with a fresh client instead of reusing a
  /// broken one (the core self-recovery guard: a lost CDP target must reject
  /// in-flight awaits instead of hanging the engine's mainLoop forever).
  bool dead = false;

  void _onMessage(dynamic raw) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final id = msg['id'] as int?;
    if (id == null) return;
    final pending = _pending.remove(id);
    if (pending == null) return;
    pending.timer.cancel();
    final error = msg['error'] as Map<String, dynamic>?;
    if (error != null) {
      pending.completer.completeError(
        CdpException(error['message']?.toString() ?? 'CDP error'),
      );
    } else {
      pending.completer.complete(msg['result'] as Map<String, dynamic>?);
    }
  }

  void _fail(String reason) {
    dead = true;
    final entries = _pending.entries.toList();
    _pending.clear();
    for (final entry in entries) {
      entry.value.timer.cancel();
      entry.value.completer.completeError(
        CdpException('CDP $reason: pending request #${entry.key} rejected'),
      );
    }
  }

  Future<Map<String, dynamic>?> send(
    String method, [
    Map<String, dynamic> params = const {},
  ]) {
    if (dead || _socket.readyState != WebSocket.open) {
      return Future.error(
        CdpException('CDP send aborted (dead=$dead) for $method'),
      );
    }
    final id = ++_id;
    final completer = Completer<Map<String, dynamic>?>();
    final timer = Timer(_timeout, () {
      _pending.remove(id);
      dead = true;
      try {
        _socket.close();
      } catch (_) {}
      completer.completeError(
        CdpException(
          'CDP request timed out after ${_timeout.inMilliseconds}ms for $method (req #$id)',
        ),
      );
    });
    _pending[id] = _PendingRequest(completer, timer);
    try {
      _socket.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    } catch (e) {
      timer.cancel();
      _pending.remove(id);
      completer.completeError(CdpException('CDP send failed for $method: $e'));
    }
    return completer.future;
  }

  /// Evaluates a JavaScript expression inside the page and returns its value
  /// (via `Runtime.evaluate` with `returnByValue`+`awaitPromise`).
  Future<dynamic> evaluate(String expression) async {
    final result = await send('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': true,
    });
    final exceptionDetails =
        result?['exceptionDetails'] as Map<String, dynamic>?;
    if (exceptionDetails != null) {
      final exception = exceptionDetails['exception'] as Map<String, dynamic>?;
      throw CdpException(
        (exception?['description'] ??
                exceptionDetails['text'] ??
                'JS evaluation error')
            .toString(),
      );
    }
    return (result?['result'] as Map<String, dynamic>?)?['value'];
  }

  void close() {
    try {
      _socket.close();
    } catch (_) {}
    _subscription.cancel();
  }
}

class CdpTarget {
  const CdpTarget({
    required this.type,
    required this.url,
    required this.webSocketDebuggerUrl,
  });
  final String type;
  final String url;
  final String webSocketDebuggerUrl;
}

Future<List<Map<String, dynamic>>> _fetchJsonList(String host, int port) async {
  final client = HttpClient();
  try {
    final request = await client
        .getUrl(Uri.parse('http://$host:$port/json/list'))
        .timeout(CoreConstants.cdpJsonListTimeout);
    final response = await request.close().timeout(
      CoreConstants.cdpJsonListTimeout,
    );
    if (response.statusCode != 200) {
      throw CdpException('CDP /json/list returned HTTP ${response.statusCode}');
    }
    final body = await response.transform(utf8.decoder).join();
    return (jsonDecode(body) as List).cast<Map<String, dynamic>>();
  } finally {
    client.close(force: true);
  }
}

CdpTarget _toTarget(Map<String, dynamic> t) => CdpTarget(
  type: t['type'] as String,
  url: t['url'] as String,
  webSocketDebuggerUrl: t['webSocketDebuggerUrl'] as String,
);

/// The shared "tab owner" rule (2026-11-04, agreed between this app and
/// another app sharing the same TradingView). One TradingView account allows
/// one live session, so both apps use ONE TradingView with one chart tab each.
/// On the free plan both tabs hold the same saved layout, so the URL can't
/// tell them apart. Instead each app tags its own tab in that tab's own
/// sessionStorage, which survives a page reload but not a TradingView restart.
const String tabOwnerKey = 'tvTabOwner';

/// This app's tag value.
const String pionexTabOwner = 'tradingpionex';

/// Reads a tab's tag without changing anything.
String tabOwnerReadScript() =>
    '(function(){return sessionStorage.getItem("$tabOwnerKey");})()';

/// Claims a tab for [owner] only if it is untagged, in ONE evaluate so two
/// apps can never take the same tab. Returns "mine", "claimed" or
/// "taken:<other owner>". The exact shared script - don't change its shape
/// without the other app.
String tabOwnerClaimScript(String owner) =>
    '(function(){var k="$tabOwnerKey",v=sessionStorage.getItem(k);'
    'if(v==="$owner")return "mine";if(v)return "taken:"+v;'
    'sessionStorage.setItem(k,"$owner");return "claimed";})()';

/// A chart tab's tag as read: null = untagged, [tabNoAnswer] = the tab didn't
/// answer the read (it may be this app's own tab, hung).
const String tabNoAnswer = '\u0000no-answer';

/// What to do with the chart tabs, given each one's tag in [tags]: use the
/// one at [use], try claiming the untagged ones at [claimOrder] in order, or
/// stop with [error]. Pure, so the rule itself is unit tested.
({int? use, List<int> claimOrder, String? error}) decideOwnTab(
  List<String?> tags,
  String owner,
) {
  final mine = [
    for (var i = 0; i < tags.length; i++)
      if (tags[i] == owner) i,
  ];
  if (mine.length > 1) {
    return (
      use: null,
      claimOrder: const [],
      error: '${mine.length} chart tabs are tagged "$owner" - using none',
    );
  }
  if (mine.length == 1) return (use: mine.single, claimOrder: const [], error: null);
  if (tags.contains(tabNoAnswer)) {
    return (
      use: null,
      claimOrder: const [],
      error: 'a chart tab did not answer the tag read and none is tagged '
          '"$owner" - it may be this app\'s own tab, stuck; not claiming',
    );
  }
  final free = [
    for (var i = 0; i < tags.length; i++)
      if (tags[i] == null) i,
  ];
  if (free.isEmpty) {
    return (
      use: null,
      claimOrder: const [],
      error: tags.isEmpty
          ? 'no TradingView chart tab is open'
          : 'no untagged chart tab is free to claim',
    );
  }
  return (use: null, claimOrder: free, error: null);
}

/// Every TradingView chart page target (`tradingview.com/chart`), in
/// `/json/list` order.
Future<List<CdpTarget>> _chartTargets(String host, int port) async {
  final targets = await _fetchJsonList(host, port);
  return targets
      .where(
        (t) =>
            t['type'] == 'page' &&
            RegExp(
              'tradingview\\.com/chart',
              caseSensitive: false,
            ).hasMatch((t['url'] ?? '').toString()),
      )
      .map(_toTarget)
      .toList();
}

Future<CdpClient> _openClient(CdpTarget target) async {
  // 2026-09-26, real-money bug found live: neither call below had a timeout -
  // when TradingView's CDP server accepted the target lookup but stalled on
  // the actual WebSocket handshake (renderer briefly unresponsive),
  // `WebSocket.connect` hung forever with no exception ever thrown, which
  // stalled the whole retry loop indefinitely. Bounding both calls lets a
  // stuck attempt actually fail and move on to the next retry/backoff.
  final socket = await WebSocket.connect(
    target.webSocketDebuggerUrl,
  ).timeout(CoreConstants.cdpConnectTimeout);
  return CdpClient(socket);
}

/// Free plan: at most this many chart tabs; a third would close the oldest.
const int maxChartTabs = 2;

/// One new tab per engine run at most (same rule as tradingMT5, per the user
/// 2026-11-13: "if tradingview tab is closed, app need to check if the tab
/// is open or not, if not, it should open new tab and select unnamed
/// layout"). A failed attempt does not count; it is retried every 2 minutes.
bool _openedChartTabThisProcess = false;
DateTime? _lastChartTabOpenFailAt;
const Duration _chartTabRetryEvery = Duration(minutes: 2);

const String _chartReadyProbe = '''(function() {
  try {
    var wv = window.TradingViewApi && window.TradingViewApi._activeChartWidgetWV;
    var widget = wv && wv.value && wv.value();
    return !!(widget && widget._chartWidget && widget._chartWidget.model && widget._chartWidget.model());
  } catch (e) { return false; }
})()''';

/// The only place this app opens anything in TradingView (per the user,
/// 2026-11-13; tested live the same day). TradingView Desktop refuses the CDP
/// "new page" call (HTTP 500 - tradingMT5's log shows the same) and ignores a
/// scripted click, so this does what a user does, with two real mouse clicks:
/// 1. "New tab" (+) in TradingView's own tab bar (its window-frame page);
/// 2. the saved layout's card ([layoutName], e.g. "Unnamed") on the start
///    page that opens.
/// Then it waits up to 60 s for the new chart tab to load and returns it.
/// At most once per engine run (a failed attempt is retried every 2 min).
/// Never closes, navigates or touches another app's tab.
Future<CdpTarget?> _openOneChartTab(
  String host,
  int port,
  String layoutName,
) async {
  if (_openedChartTabThisProcess || layoutName.isEmpty) return null;
  final lastFail = _lastChartTabOpenFailAt;
  if (lastFail != null &&
      DateTime.now().difference(lastFail) < _chartTabRetryEvery) {
    return null;
  }
  Future<CdpTarget?> fail() async {
    _lastChartTabOpenFailAt = DateTime.now();
    return null;
  }

  final before = {
    for (final t in await _fetchJsonList(host, port))
      if ('${t['url']}'.contains('tradingview.com/chart')) '${t['id']}',
  };
  // 1. "New tab" in TradingView's own tab bar.
  final frame = await _findPage(host, port, '/app/window/index.html');
  if (frame == null || !await _realClickOn(frame, _byLabel('New tab'))) {
    return fail();
  }
  // 2. The saved layout's card on the new tab's start page.
  CdpTarget? startPage;
  for (var i = 0; i < 15 && startPage == null; i++) {
    await Future<void>.delayed(const Duration(seconds: 1));
    startPage = await _findPage(host, port, '/app/new-tab/index.html');
  }
  if (startPage == null) return fail();
  var picked = false;
  for (var i = 0; i < 10 && !picked; i++) {
    picked = await _realClickOn(startPage, _byExactText(layoutName));
    if (!picked) await Future<void>.delayed(const Duration(seconds: 1));
  }
  if (!picked) return fail();
  _openedChartTabThisProcess = true;
  _lastChartTabOpenFailAt = null;
  // 3. The new chart tab, once its chart has loaded.
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(seconds: 2));
    for (final t in await _fetchJsonList(host, port)) {
      if (t['type'] != 'page' ||
          !'${t['url']}'.contains('tradingview.com/chart') ||
          before.contains('${t['id']}')) {
        continue;
      }
      final target = _toTarget(t);
      CdpClient? probe;
      try {
        probe = await _openClient(target);
        if (await probe.evaluate(_chartReadyProbe).timeout(
              CoreConstants.cdpConnectTimeout,
            ) ==
            true) {
          return target;
        }
      } catch (_) {
      } finally {
        probe?.close();
      }
    }
  }
  return null;
}

/// The first page target whose URL contains [urlPart], or null.
Future<CdpTarget?> _findPage(String host, int port, String urlPart) async {
  for (final t in await _fetchJsonList(host, port)) {
    if (t['type'] == 'page' && '${t['url']}'.contains(urlPart)) return _toTarget(t);
  }
  return null;
}

/// JS returning the centre of the one button labelled [label], or null.
String _byLabel(String label) =>
    '''(function(){var n=${jsonEncode(label)};var b=[...document.querySelectorAll('button')].filter(function(x){return (x.getAttribute('aria-label')||x.getAttribute('title')||x.textContent||'').trim()===n;});
if(b.length!==1)return null;var r=b[0].getBoundingClientRect();return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2});})()''';

/// JS returning the centre of the one visible element whose own text is
/// exactly [text], or null.
String _byExactText(String text) =>
    '''(function(){var n=${jsonEncode(text)};var hits=[];document.querySelectorAll('*').forEach(function(el){if(el.children.length===0&&(el.textContent||'').trim()===n){var r=el.getBoundingClientRect();if(r.width>0&&r.height>0)hits.push({x:r.left+r.width/2,y:r.top+r.height/2});}});
return hits.length===1?JSON.stringify(hits[0]):null;})()''';

/// Finds the element [locate] points at on [page] and gives it one real
/// mouse click (pressed + released). False if it was not found.
Future<bool> _realClickOn(CdpTarget page, String locate) async {
  CdpClient? client;
  try {
    client = await _openClient(page);
    final found = await client.evaluate(locate).timeout(CoreConstants.cdpConnectTimeout);
    if (found == null) return false;
    final p = jsonDecode('$found') as Map<String, dynamic>;
    for (final type in ['mouseMoved', 'mousePressed', 'mouseReleased']) {
      await client
          .send('Input.dispatchMouseEvent', {
            'type': type,
            'x': p['x'],
            'y': p['y'],
            if (type != 'mouseMoved') 'button': 'left',
            if (type != 'mouseMoved') 'clickCount': 1,
          })
          .timeout(CoreConstants.cdpConnectTimeout);
    }
    return true;
  } catch (_) {
    return false;
  } finally {
    client?.close();
  }
}
/// Finds or claims this app's own chart tab under the shared tab-owner rule,/// and returns a client on it. Every other tab is only ever READ (its tag),
/// never switched, reloaded, closed or navigated; and no tab is ever opened.
Future<CdpClient> _connectToOwnTab(
  String host,
  int port,
  String owner, {
  String layoutName = 'Unnamed',
  bool Function()? beforeOpenTab,
  void Function()? afterOpenTab,
}) async {
  final targets = await _chartTargets(host, port);
  final clients = <CdpClient?>[];
  final tags = <String?>[];
  try {
    for (final target in targets) {
      CdpClient? client;
      String? tag;
      try {
        client = await _openClient(target);
        tag =
            await client
                    .evaluate(tabOwnerReadScript())
                    .timeout(CoreConstants.cdpConnectTimeout)
                as String?;
      } catch (_) {
        client?.close();
        client = null;
        tag = tabNoAnswer;
      }
      clients.add(client);
      tags.add(tag);
    }

    final decision = decideOwnTab(tags, owner);
    // Our tab is gone and none is free: open one on the saved layout, as
    // tradingMT5 does - only when fewer than [maxChartTabs] are open.
    final noFreeTab = decision.use == null &&
        decision.claimOrder.isEmpty &&
        !tags.contains(tabNoAnswer) &&
        !tags.contains(owner);
    if (noFreeTab && targets.length < maxChartTabs) {
      final layout = layoutName;
      // The TradingView sync lock (tv_sync.dart): never open a tab while the
      // other app is mid-action on TradingView.
      if (beforeOpenTab != null && !beforeOpenTab()) {
        throw CdpException(decision.error ?? 'waiting for the other app to finish with TradingView');
      }
      final CdpTarget? opened;
      try {
        opened = await _openOneChartTab(host, port, layout);
      } finally {
        afterOpenTab?.call();
      }
      if (opened != null) {
        final client = await _openClient(opened);
        try {
          final claim = await client
              .evaluate(tabOwnerClaimScript(owner))
              .timeout(CoreConstants.cdpConnectTimeout);
          if (claim == 'claimed' || claim == 'mine') {
            await client.send('Runtime.enable').timeout(CoreConstants.cdpConnectTimeout);
            // A freshly opened layout first gets every indicator closed (per
            // the user, 2026-11-13); the engine then adds its two scripts.
            try {
              await client
                  .evaluate('(function(){try{window.TradingViewApi.activeChart().removeAllStudies();return 1;}catch(e){return 0;}})()')
                  .timeout(CoreConstants.cdpConnectTimeout);
            } catch (_) {}
            return client;
          }
        } catch (_) {}
        client.close();
      }
    }
    if (decision.error != null) throw CdpException(decision.error!);
    var chosen = decision.use;
    for (final i in decision.claimOrder) {
      final result = await clients[i]!
          .evaluate(tabOwnerClaimScript(owner))
          .timeout(CoreConstants.cdpConnectTimeout);
      if (result == 'claimed' || result == 'mine') {
        chosen = i;
        break;
      }
    }
    if (chosen == null) {
      throw CdpException('every untagged chart tab was taken while claiming');
    }
    final client = clients[chosen]!;
    clients[chosen] = null;
    await client.send('Runtime.enable').timeout(CoreConstants.cdpConnectTimeout);
    return client;
  } finally {
    for (final c in clients) {
      c?.close();
    }
  }
}

/// Whether [client]'s tab still carries this app's tag - re-checked every
/// cycle, since a TradingView restart wipes the tags and the tab a stale
/// client points at could end up anyone's.
Future<bool> isOwnTab(CdpClient client, {String owner = pionexTabOwner}) async {
  try {
    return await client
            .evaluate(tabOwnerReadScript())
            .timeout(CoreConstants.cdpConnectTimeout) ==
        owner;
  } catch (_) {
    return false;
  }
}

/// Reloads this app's own tab, the first recovery step for a stuck chart -
/// far less disruptive than restarting TradingView, which would also take
/// down the other app's tab. [client] must come from [connectToChart].
Future<void> reloadOwnTab(CdpClient client) async {
  if (!await isOwnTab(client)) {
    throw CdpException('refusing to reload a tab that is not this app\'s own');
  }
  await client.send('Page.reload').timeout(CoreConstants.cdpConnectTimeout);
}

/// Lists every visible TradingView page target (not just the first match).
Future<List<CdpTarget>> listTradingViewTargets(String host, int port) async {
  final targets = await _fetchJsonList(host, port);
  return targets
      .where(
        (t) =>
            t['type'] == 'page' &&
            RegExp(
              'tradingview',
              caseSensitive: false,
            ).hasMatch((t['url'] ?? '').toString()),
      )
      .map(_toTarget)
      .toList();
}

/// Connects to THIS app's own chart tab (see [_connectToOwnTab]), retrying
/// with exponential backoff — ported from lib/cdp.js `connectToChart`, which
/// took the first chart tab it found.
Future<CdpClient> connectToChart(
  String host,
  int port, {
  int maxRetries = 5,
  String layoutName = 'Unnamed',
  bool Function()? beforeOpenTab,
  void Function()? afterOpenTab,
}) async {
  const baseDelay = Duration(milliseconds: 500);
  Object? lastError;
  for (var attempt = 0; attempt < maxRetries; attempt++) {
    try {
      return await _connectToOwnTab(
        host,
        port,
        pionexTabOwner,
        layoutName: layoutName,
        beforeOpenTab: beforeOpenTab,
        afterOpenTab: afterOpenTab,
      );
    } catch (e) {
      lastError = e;
      final delayMs = (baseDelay.inMilliseconds * (1 << attempt)).clamp(
        0,
        30000,
      );
      await Future<void>.delayed(Duration(milliseconds: delayMs));
    }
  }
  throw CdpException(
    'CDP connection failed after $maxRetries attempts: $lastError',
  );
}
