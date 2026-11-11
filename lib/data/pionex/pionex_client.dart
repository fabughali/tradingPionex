import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../core/core_api.dart';
import '../../core/core_constants.dart';
import '../models/balance.dart';
import '../technique/trending.dart';

/// Signed REST client for https://api.pionex.com — ported 1:1 from
/// lib/pionex.js, including its exact (non-obvious) endpoint paths and
/// signing scheme. Do not "fix" the endpoint paths to look more RESTful —
/// these are the real, live-verified ones (e.g. checkParams/create/cancel
/// all live under `/api/v1/bot/orders/futuresGrid/...`, and `cancel` is a
/// POST, not a DELETE, despite being a cancellation).
class PionexClient {
  PionexClient({
    required String apiKey,
    required String apiSecret,
    CoreApi? api,
    void Function(String message)? onLog,
  }) : _apiKey = apiKey,
       _apiSecret = apiSecret,
       _api = api ?? CoreApi(),
       _onLog = onLog ?? ((_) {});

  static const _base = 'https://api.pionex.com';

  final String _apiKey;
  final String _apiSecret;
  final CoreApi _api;

  /// Per the user (2026-09-10): every Pionex call must be traceable - how
  /// long it took and whether it succeeded, so a slow/flaky connection or a
  /// Pionex-side rejection can be told apart from "the app just isn't
  /// trying." No-op by default so GUI-side callers that don't care don't
  /// have to pass one; [EngineService] wires this to its own [AppLogger].
  final void Function(String message) _onLog;

  bool get available => _apiKey.isNotEmpty && _apiSecret.isNotEmpty;

  /// Circuit breaker (2026-09-11, per the user, live account - a real,
  /// ~15+ minute self-sustaining rate-limit outage that made real position
  /// closes start failing: "GRID CLOSE FAILED AAVEUSDT/ETHUSDT/NEARUSDT:
  /// RateLimitException"). Confirmed against Pionex's own docs: exceeding
  /// their limit (10 req/s per IP AND per account) gives a 60s ban, and
  /// critically "every request sent while still banned adds another 10
  /// seconds to the ban." Every call in this file used to go straight to
  /// the network regardless of how recently it had ALREADY been
  /// rate-limited - dozens of call sites (auto-checkup, grid close, risk
  /// checks, the GUI's own status poll) each kept independently retrying on
  /// their own schedules, each extending the same real ban further, so it
  /// could never actually clear. This is the one chokepoint every signed
  /// call already goes through ([_request]) - once ANY call gets a real
  /// 429, every further call for the next [_cooldown] is rejected LOCALLY,
  /// instantly, with zero network traffic - so the real ban is never
  /// extended and gets a genuine chance to expire. Backs off harder (30s,
  /// 60s, 120s, 240s, capping at 480s) each time a fresh attempt, after
  /// waiting out the previous cooldown, still comes back rate-limited.
  DateTime? _bannedUntil;
  int _consecutiveRateLimitHits = 0;

  Duration get _cooldown {
    final steps = (_consecutiveRateLimitHits - 1).clamp(0, 4);
    final seconds = 30 * (1 << steps);
    return Duration(seconds: seconds.clamp(30, 480));
  }

  /// Throws (synchronously, no network call) if still inside a cooldown
  /// from a previous real rate-limit hit.
  void _checkNotBanned() {
    final until = _bannedUntil;
    if (until != null && DateTime.now().isBefore(until)) {
      throw RateLimitException(until.difference(DateTime.now()));
    }
  }

  void _recordSuccess() {
    _consecutiveRateLimitHits = 0;
    _bannedUntil = null;
  }

  void _recordRateLimitHit() {
    _consecutiveRateLimitHits++;
    _bannedUntil = DateTime.now().add(_cooldown);
    _onLog(
      'PIONEX rate-limit circuit breaker: tripped (hit #$_consecutiveRateLimitHits) - '
      'rejecting every call locally for ${_cooldown.inSeconds}s instead of adding to the real ban.',
    );
  }

  String _sign(
    String method,
    String path,
    Map<String, String> query,
    String? bodyJson,
  ) {
    final sortedKeys = query.keys.toList()..sort();
    final qs = sortedKeys.map((k) => '$k=${query[k]}').join('&');
    var preimage = '$method$path?$qs';
    if (bodyJson != null && (method == 'POST' || method == 'DELETE')) {
      preimage += bodyJson;
    }
    final digest = Hmac(
      sha256,
      utf8.encode(_apiSecret),
    ).convert(utf8.encode(preimage));
    return digest.toString();
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, String> params = const {},
    Map<String, dynamic>? body,
    void Function(int statusCode, Map<String, String> headers)? onRawResponse,
  }) async {
    _checkNotBanned();
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final query = {...params, 'timestamp': timestamp};
    final bodyJson = body != null ? jsonEncode(body) : null;
    final signature = _sign(method, path, query, bodyJson);

    final encodedQuery = query.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    final uri = Uri.parse('$_base$path?$encodedQuery');
    final headers = {
      'PIONEX-KEY': _apiKey,
      'PIONEX-SIGNATURE': signature,
      'Content-Type': 'application/json',
    };

    // Diagnostic only (2026-09-14, per an external review of the
    // BOT_INTERNAL_ERROR investigation) - captures the raw HTTP
    // status/headers Pionex sent back, even on a `result:false` body (which
    // is HTTP 200), and hands them to the caller (currently only
    // createFuturesGrid passes onRawResponse) - without changing what every
    // other call site gets back.
    int? capturedStatus;
    Map<String, String>? capturedHeaders;
    void captureRaw(http.Response response) {
      capturedStatus = response.statusCode;
      capturedHeaders = response.headers;
    }

    final sw = Stopwatch()..start();
    Map<String, dynamic> data;
    try {
      data = method == 'GET'
          ? await _api.getJson(
              uri,
              headers: headers,
              timeout: CoreConstants.pionexRequestTimeout,
              onResponse: captureRaw,
            )
          : await _api.sendJson(
              method,
              uri,
              headers: headers,
              body: bodyJson,
              timeout: CoreConstants.pionexRequestTimeout,
              onResponse: captureRaw,
            );
    } catch (e) {
      sw.stop();
      _onLog(
        'PIONEX API $method $path: FAILED after ${sw.elapsedMilliseconds}ms - $e',
      );
      if (e is RateLimitException) _recordRateLimitHit();
      rethrow;
    }
    sw.stop();
    if (capturedStatus != null && capturedHeaders != null) {
      onRawResponse?.call(capturedStatus!, capturedHeaders!);
    }

    if (data['result'] != true) {
      // Pionex signals rate limiting through this same result:false body
      // (HTTP 200) rather than an actual 429 status in some cases - treat
      // either the same way so a caller doing several calls in a row (grid
      // count probing) can abort the whole sequence instead of continuing
      // to hammer the same limit.
      final message = '${data['code'] ?? ''} ${data['message'] ?? ''}'
          .toLowerCase();
      _onLog(
        'PIONEX API $method $path: responded in ${sw.elapsedMilliseconds}ms with error - $message',
      );
      if (message.contains('too many') ||
          message.contains('rate limit') ||
          message.contains('frequent')) {
        _recordRateLimitHit();
        throw RateLimitException(null);
      }
      throw ApiException(
        'Pionex API error: ${data['code'] ?? ''} ${data['message'] ?? ''}',
        statusCode: capturedStatus,
        rawBody: jsonEncode(data),
      );
    }
    _recordSuccess();
    _onLog('PIONEX API $method $path: ok in ${sw.elapsedMilliseconds}ms');
    // Per the user (2026-09-06): the cancel endpoint's `data` field came
    // back live as a bare String (not the nested Map every other endpoint
    // returns) - the old blind cast crashed instead of falling back, right
    // after Pionex had already confirmed result:true, which stopped the
    // engine from ever recording the close it had already told Pionex to do.
    final inner = data['data'];
    if (inner is Map<String, dynamic>) return inner;
    return data;
  }

  /// Public, unauthenticated ticker endpoint — verified live
  /// (`GET /api/v1/market/tickers?symbol=BASE_QUOTE_PERP`, `close` = last
  /// traded price). Used only for display (current price on the dashboard);
  /// never part of any trading decision, so it deliberately bypasses signing.
  Future<double?> getTickerPrice(String symbolUnderscorePerp) async {
    // Shares [_request]'s circuit breaker (2026-09-11) - this bypasses
    // signing/[_request] entirely (public endpoint) but still counts
    // against Pionex's per-IP limit like every other call, and was one more
    // source keeping a real ban alive during the incident documented on
    // [_bannedUntil].
    try {
      _checkNotBanned();
    } catch (_) {
      return null;
    }
    final uri = Uri.parse(
      '$_base/api/v1/market/tickers',
    ).replace(queryParameters: {'symbol': symbolUnderscorePerp});
    final sw = Stopwatch()..start();
    Map<String, dynamic> data;
    try {
      data = await _api.getJson(uri, timeout: CoreConstants.pionexRequestTimeout);
    } catch (e) {
      sw.stop();
      _onLog(
        'PIONEX API GET /api/v1/market/tickers ($symbolUnderscorePerp): FAILED after ${sw.elapsedMilliseconds}ms - $e',
      );
      if (e is RateLimitException) _recordRateLimitHit();
      return null;
    }
    sw.stop();
    _onLog(
      'PIONEX API GET /api/v1/market/tickers ($symbolUnderscorePerp): ok in ${sw.elapsedMilliseconds}ms',
    );
    if (data['result'] != true) return null;
    _recordSuccess();
    final tickers = ((data['data']?['tickers'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    if (tickers.isEmpty) return null;
    return _num(tickers.first['close']);
  }

  /// Every perpetual's 24h numbers (`GET /api/v1/market/tickers?type=PERP`,
  /// public, unsigned) - backs Check Now's trending list. Empty on failure.
  Future<List<PerpTicker>> getPerpTickers({bool log = true}) async {
    try {
      _checkNotBanned();
    } catch (_) {
      return const [];
    }
    final uri = Uri.parse(
      '$_base/api/v1/market/tickers',
    ).replace(queryParameters: {'type': 'PERP'});
    final sw = Stopwatch()..start();
    Map<String, dynamic> data;
    try {
      data = await _api.getJson(uri, timeout: CoreConstants.pionexRequestTimeout);
    } catch (e) {
      _onLog(
        'PIONEX API GET /api/v1/market/tickers (PERP): FAILED after ${sw.elapsedMilliseconds}ms - $e',
      );
      if (e is RateLimitException) _recordRateLimitHit();
      return const [];
    }
    if (log) {
      _onLog(
        'PIONEX API GET /api/v1/market/tickers (PERP): ok in ${sw.elapsedMilliseconds}ms',
      );
    }
    if (data['result'] != true) return const [];
    _recordSuccess();
    return [
      for (final j in ((data['data']?['tickers'] as List?) ?? const [])
          .cast<Map<String, dynamic>>())
        ?PerpTicker.fromJson(j),
    ];
  }

  Future<List<Map<String, dynamic>>> getBalances() async {
    final data = await _request('GET', '/api/v1/account/balances');
    return ((data['balances'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
  }

  Future<Balance> getBalance(String coin) async {
    final balances = await getBalances();
    final found = balances.cast<Map<String, dynamic>?>().firstWhere(
      (b) => b?['symbol'] == coin || b?['coin'] == coin,
      orElse: () => null,
    );
    if (found == null) return Balance.zero;
    return Balance(
      free: _num(found['available'] ?? found['free'] ?? found['amount']) ?? 0,
      // Pionex sends free + frozen (no total field).
      total:
          _num(found['total'] ?? found['balance']) ??
          ((_num(found['free']) ?? 0) + (_num(found['frozen']) ?? 0)),
    );
  }

  Future<List<Map<String, dynamic>>> getSymbols() async {
    final data = await _request('GET', '/api/v1/common/symbols');
    return ((data['symbols'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
  }

  /// Verified live (2026-09-06): `/api/v1/common/symbols` returns SPOT
  /// entries by default - futures/perpetual pairs only come back with
  /// `type=PERP` (there is no `FUTURES` type value at all, despite this
  /// method's name). Each entry's `symbol` is `BASE_QUOTE_PERP`.
  Future<List<Map<String, dynamic>>> getFuturesSymbols() async {
    final data = await _request(
      'GET',
      '/api/v1/common/symbols',
      params: {'type': 'PERP'},
    );
    return ((data['symbols'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
  }

  /// Base tickers (e.g. "ETH" from "ETH_USDT_PERP") Pionex currently offers
  /// as a tradeable perpetual futures grid, i.e. `status == 'TRADING'`.
  /// Used to tag Red List pairs that exist on TradingView but can never
  /// actually be opened as a Pionex grid.
  Future<Set<String>> getFuturesBaseTickers() async {
    final syms = await getFuturesSymbols();
    return syms
        .where((s) => s['status'] == 'TRADING')
        .map((s) => '${s['symbol']}'.split('_').first.toUpperCase())
        .toSet();
  }

  Future<List<Map<String, dynamic>>> getRiskTable(String symbol) async {
    final data = await _request('GET', '/api/v1/common/riskTable');
    final entries = ((data['symbols'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final match = entries.cast<Map<String, dynamic>?>().firstWhere(
      (s) => s?['symbol'] == symbol,
      orElse: () => null,
    );
    return match == null
        ? const []
        : ((match['rows'] as List?) ?? const []).cast<Map<String, dynamic>>();
  }

  /// Risk table uses BASE_QUOTE_PERP (underscore); accepts a `.PERP` or
  /// `_USDT_PERP` suffixed base too. Returns null when nothing is found.
  Future<double?> getMaxLeverage(String symbol, {String quote = 'USDT'}) async {
    final base = symbol
        .replaceAll(RegExp(r'\.PERP$', caseSensitive: false), '')
        .replaceAll(RegExp(r'_' + quote + r'_PERP$', caseSensitive: false), '');
    final riskSymbol = '${base}_${quote}_PERP';
    final rows = await getRiskTable(riskSymbol);
    if (rows.isEmpty) return null;
    return rows
        .map((r) => _num(r['maxLeverage']) ?? 0)
        .reduce((a, b) => a > b ? a : b);
  }

  Future<Map<String, dynamic>> checkFuturesGrid({
    required String base,
    required String quote,
    required Map<String, dynamic> buOrderData,
  }) => _request(
    'POST',
    '/api/v1/bot/orders/futuresGrid/checkParams',
    body: {'base': base, 'quote': quote, 'buOrderData': buOrderData},
  );

  /// [onRawResponse] is diagnostic-only (2026-09-14, per an external
  /// review of the BOT_INTERNAL_ERROR investigation) - lets the caller log
  /// the exact HTTP status code and response headers Pionex sent back for
  /// this specific create attempt, success or failure, to compare against
  /// the one confirmed success (DOGEUSDT, 2026-09-14) once another lands.
  Future<Map<String, dynamic>> createFuturesGrid({
    required String base,
    required String quote,
    required Map<String, dynamic> buOrderData,
    void Function(int statusCode, Map<String, String> headers)? onRawResponse,
  }) => _request(
    'POST',
    '/api/v1/bot/orders/futuresGrid/create',
    body: {'base': base, 'quote': quote, 'buOrderData': buOrderData},
    onRawResponse: onRawResponse,
  );

  /// Take-profit/stop-loss/margin (2026-09-18, per the user - gear-icon
  /// bot-actions menu): every real running grid bot already carries
  /// `profitStop`/`profitStopType`/`lossStop`/`lossStopType` plus
  /// `stopProfitEnabled`/`stopLossEnabled` in its own stored state
  /// (confirmed live via `getActiveGrids` on 6 real running bots - e.g. DOT
  /// carries `profitStop: "0.05"`, `profitStopType: "profit_ratio"`,
  /// `stopProfitEnabled: false`), so these are genuinely mutable per-bot
  /// settings, not create-time-only despite `adjustParams`'s own API docs
  /// page not listing them in its field table. Margin add/reduce
  /// (`extraMarginAmount`, signed) confirmed the same way via a real
  /// dry-run (`adjustParamsCheck`) against a live bot - both a positive and
  /// a negative value returned `checkResult: true`.
  ///
  /// `type: 'adjust_params'`, `top`/`bottom`/`row` are the bot's OWN
  /// current values (required by Pionex even when unchanged - this call
  /// never resizes the grid, only touches whichever of TP/SL/margin fields
  /// are passed). `isReinvest: false, keepInvestment: true` are REQUIRED -
  /// confirmed live (every combination tried without them failed with
  /// `BOT_INVALID_ARGUMENT PROFIT_LESS_THAN_ZERO`, on multiple different
  /// bots, regardless of which other fields were set - only adding these
  /// two fixed the request). `extraMargin` (the boolean request flag, NOT
  /// the bot's own stored dollar amount - same dual meaning
  /// `createFuturesGrid`'s body already has) is left `false` here since
  /// none of these actions add fresh investment.
  Map<String, dynamic> _adjustParamsBody({
    required String buOrderId,
    required double openPrice,
    required String top,
    required String bottom,
    required int row,
    String? profitStopType,
    String? profitStop,
    bool? stopProfitEnabled,
    String? lossStopType,
    String? lossStop,
    bool? stopLossEnabled,
    double? extraMarginAmount,
  }) => {
    'buOrderId': buOrderId,
    'type': 'adjust_params',
    'extraMargin': false,
    'openPrice': openPrice,
    'top': top,
    'bottom': bottom,
    'row': row,
    'isReinvest': false,
    'keepInvestment': true,
    if (profitStopType != null) 'profitStopType': profitStopType,
    if (profitStop != null) 'profitStop': profitStop,
    if (stopProfitEnabled != null) 'stopProfitEnabled': stopProfitEnabled,
    if (lossStopType != null) 'lossStopType': lossStopType,
    if (lossStop != null) 'lossStop': lossStop,
    if (stopLossEnabled != null) 'stopLossEnabled': stopLossEnabled,
    if (extraMarginAmount != null) 'extraMarginAmount': extraMarginAmount,
  };

  /// Dry-run - validates and returns estimated data (including projected
  /// liquidation prices) without executing anything real (per Pionex's own
  /// docs). Always call this before [adjustFuturesGridParams] so a
  /// rejected value surfaces as a clear refusal instead of a live API
  /// error - e.g. Pionex's own app refuses a stop-loss that isn't strictly
  /// worse than the bot's current P/L, though this endpoint itself did NOT
  /// enforce that in live testing (accepted every sign/magnitude tried) -
  /// that rule is replicated client-side in the TP/SL screens to match
  /// Pionex's own UI behavior.
  Future<Map<String, dynamic>> checkAdjustFuturesGridParams({
    required String buOrderId,
    required double openPrice,
    required String top,
    required String bottom,
    required int row,
    String? profitStopType,
    String? profitStop,
    bool? stopProfitEnabled,
    String? lossStopType,
    String? lossStop,
    bool? stopLossEnabled,
    double? extraMarginAmount,
  }) => _request(
    'POST',
    '/api/v1/bot/orders/futuresGrid/adjustParamsCheck',
    body: _adjustParamsBody(
      buOrderId: buOrderId,
      openPrice: openPrice,
      top: top,
      bottom: bottom,
      row: row,
      profitStopType: profitStopType,
      profitStop: profitStop,
      stopProfitEnabled: stopProfitEnabled,
      lossStopType: lossStopType,
      lossStop: lossStop,
      stopLossEnabled: stopLossEnabled,
      extraMarginAmount: extraMarginAmount,
    ),
  );

  Future<Map<String, dynamic>> adjustFuturesGridParams({
    required String buOrderId,
    required double openPrice,
    required String top,
    required String bottom,
    required int row,
    String? profitStopType,
    String? profitStop,
    bool? stopProfitEnabled,
    String? lossStopType,
    String? lossStop,
    bool? stopLossEnabled,
    double? extraMarginAmount,
  }) => _request(
    'POST',
    '/api/v1/bot/orders/futuresGrid/adjustParams',
    body: _adjustParamsBody(
      buOrderId: buOrderId,
      openPrice: openPrice,
      top: top,
      bottom: bottom,
      row: row,
      profitStopType: profitStopType,
      profitStop: profitStop,
      stopProfitEnabled: stopProfitEnabled,
      lossStopType: lossStopType,
      lossStop: lossStop,
      stopLossEnabled: stopLossEnabled,
      extraMarginAmount: extraMarginAmount,
    ),
  );

  /// CONFIRMED live (2026-09-23) - the real, dedicated margin-transfer
  /// endpoints. Pionex moved margin add/reduce out of `adjustParams`/
  /// `extraMarginAmount` at some point after 2026-09-18 (that old path now
  /// silently no-ops - reports success, changes nothing - confirmed dead on
  /// multiple real bots) into these 4 separate routes instead. Verified
  /// live, both directions, on two different real running bots: `extraMargin`
  /// moved by the exact requested amount every time, and the account's free
  /// USDT balance moved by the exact inverse amount in lockstep -
  /// `reduceMargin` withdraws INTO free balance, `addMargin` deposits FROM
  /// it. `amount` is always a positive magnitude in both directions - the
  /// endpoint itself determines the transfer direction, unlike the old
  /// `extraMarginAmount`'s sign convention.
  Future<Map<String, dynamic>> checkAddMargin({
    required String buOrderId,
    required double amount,
  }) => _request(
    'POST',
    '/api/v1/bot/orders/futuresGrid/addMarginCheck',
    body: {'buOrderId': buOrderId, 'amount': amount},
  );

  Future<Map<String, dynamic>> addMargin({
    required String buOrderId,
    required double amount,
    String coin = 'USDT',
  }) => _request(
    'POST',
    '/api/v1/bot/orders/futuresGrid/addMargin',
    body: {'buOrderId': buOrderId, 'coin': coin, 'amount': amount},
  );

  Future<Map<String, dynamic>> checkReduceMargin({
    required String buOrderId,
    required double amount,
  }) => _request(
    'POST',
    '/api/v1/bot/orders/futuresGrid/reduceMarginCheck',
    body: {'buOrderId': buOrderId, 'amount': amount},
  );

  Future<Map<String, dynamic>> reduceMargin({
    required String buOrderId,
    required double amount,
    String coin = 'USDT',
  }) => _request(
    'POST',
    '/api/v1/bot/orders/futuresGrid/reduceMargin',
    body: {'buOrderId': buOrderId, 'coin': coin, 'amount': amount},
  );

  /// Add investment (2026-09-18) - confirmed live: `type: 'invest_in'` with
  /// a POSITIVE `quoteInvestment` only. A negative value is explicitly
  /// rejected server-side (`quote_investment should greater than 0 when
  /// invest_in`) - Pionex's own "Reduce investment" screen has no
  /// confirmed public-API equivalent (every plausible `type` value tried
  /// - `invest_out`, `reduce_invest`, `withdraw_invest`, etc. - was
  /// rejected as an invalid type), so that action is intentionally not
  /// implemented here.
  Map<String, dynamic> _investInBody({
    required String buOrderId,
    required double openPrice,
    required double quoteInvestment,
  }) => {
    'buOrderId': buOrderId,
    'type': 'invest_in',
    'extraMargin': false,
    'openPrice': openPrice,
    'quoteInvestment': quoteInvestment,
  };

  Future<Map<String, dynamic>> checkInvestInFuturesGrid({
    required String buOrderId,
    required double openPrice,
    required double quoteInvestment,
  }) => _request(
    'POST',
    '/api/v1/bot/orders/futuresGrid/adjustParamsCheck',
    body: _investInBody(
      buOrderId: buOrderId,
      openPrice: openPrice,
      quoteInvestment: quoteInvestment,
    ),
  );

  Future<Map<String, dynamic>> investInFuturesGrid({
    required String buOrderId,
    required double openPrice,
    required double quoteInvestment,
  }) => _request(
    'POST',
    '/api/v1/bot/orders/futuresGrid/adjustParams',
    body: _investInBody(
      buOrderId: buOrderId,
      openPrice: openPrice,
      quoteInvestment: quoteInvestment,
    ),
  );

  /// Reduce position size (2026-09-18) - a genuinely SEPARATE endpoint from
  /// `adjustParams`/`invest_in` (not a `type` value), found via ChatGPT's
  /// own read of Pionex's docs after ours converged independently: neither
  /// of us found a working "reduce investment" path inside `adjustParams`
  /// because it was never there - `reduce` is its own route. `reduceNum`'s
  /// unit is "order precision * reduceNum" per Pionex's own docs (not
  /// further defined there) - not yet empirically pinned down to a real
  /// USDT-equivalent amount; callers should treat it as a base-asset-unit
  /// reduction, not a direct USDT figure, until confirmed live.
  Future<Map<String, dynamic>> checkReduceFuturesGrid({
    required String buOrderId,
    required double openPrice,
    required double reduceNum,
    String? condition,
    String? conditionDirection,
  }) => _request(
    'POST',
    '/api/v1/bot/orders/futuresGrid/reduceCheck',
    body: {
      'buOrderId': buOrderId,
      'openPrice': openPrice,
      'reduceNum': reduceNum,
      if (condition != null) 'condition': condition,
      if (conditionDirection != null) 'conditionDirection': conditionDirection,
    },
  );

  Future<Map<String, dynamic>> reduceFuturesGrid({
    required String buOrderId,
    required double openPrice,
    required double reduceNum,
    String? condition,
    String? conditionDirection,
  }) => _request(
    'POST',
    '/api/v1/bot/orders/futuresGrid/reduce',
    body: {
      'buOrderId': buOrderId,
      'openPrice': openPrice,
      'reduceNum': reduceNum,
      if (condition != null) 'condition': condition,
      if (conditionDirection != null) 'conditionDirection': conditionDirection,
    },
  );

  /// Real, confirmed-live (2026-09-18) endpoint for arming/adjusting TP/SL
  /// on an ALREADY-RUNNING bot — genuinely separate from `adjustParams`,
  /// which silently accepts these same field names but never persists them
  /// (see [checkAdjustFuturesGridParams]'s doc comment). Confirmed via real
  /// submit+reread on a live bot: `stopType: 'profit_ratio'` (e.g. "0.20" =
  /// +20%) and `stopType: 'price'` (a literal price level) both genuinely
  /// persist for `stop_profit`; `stop_loss` accepts a value of either sign
  /// (negative = a real drawdown stop, positive = a locked-in profit
  /// floor) — all confirmed live. `stopProfitEnabled`/`stopLossEnabled` in
  /// Pionex's raw bot data never flip to true through this endpoint (tried
  /// every plausible field name), but the value change is confirmed visible
  /// as active in Pionex's own app regardless, so that raw flag appears
  /// stale/unused rather than a real gate — do not chase it further.
  /// Passing an empty string as a value genuinely clears that side back to
  /// unset (confirmed live).
  ///
  /// Always sends `stopDelay: 0` on every list item (2026-09-18, per the
  /// user, after seeing Pionex's own app expose a "Stop loss delay" toggle
  /// with a 5-30s countdown before a triggered stop actually executes) —
  /// this app's own TP/SL never wants that countdown window, so it is
  /// pinned to instant on every call rather than left to whatever Pionex's
  /// side would otherwise default to.
  Future<Map<String, dynamic>> updateTriggerProfitLoss({
    required String buOrderId,
    String? profitStopType,
    String? profitStopValue,
    String? lossStopType,
    String? lossStopValue,
  }) {
    final list = <Map<String, dynamic>>[
      if (profitStopType != null && profitStopValue != null)
        {
          'type': 'stop_profit',
          'stopType': profitStopType,
          'value': profitStopValue,
          'stopDelay': 0,
        },
      if (lossStopType != null && lossStopValue != null)
        {
          'type': 'stop_loss',
          'stopType': lossStopType,
          'value': lossStopValue,
          'stopDelay': 0,
        },
    ];
    if (list.isEmpty) {
      throw ArgumentError(
        'updateTriggerProfitLoss REFUSED: nothing to update',
      );
    }
    return _request(
      'POST',
      '/api/v1/bot/orders/futuresGrid/updateTriggerProfitLoss',
      body: {'buOrderId': buOrderId, 'list': list},
    );
  }

  /// Refuses to run without a concrete buOrderId — every grid action must
  /// target a specific, known bot id (PRD §10 rule 3).
  Future<Map<String, dynamic>> cancelFuturesGrid({required String buOrderId}) {
    if (buOrderId.trim().isEmpty) {
      throw ArgumentError('cancelFuturesGrid REFUSED: no buOrderId provided');
    }
    return _request(
      'POST',
      '/api/v1/bot/orders/futuresGrid/cancel',
      body: {'buOrderId': buOrderId},
    );
  }

  /// Pionex paginates this endpoint at 10 results per page (confirmed live —
  /// not documented), returning a `nextPageToken` when more exist. Stopping
  /// at page one silently hides any bot past the 10th, which is not just a
  /// display bug: the engine uses this list to decide whether a pair already
  /// has a running grid before opening a new one, so a hidden 11th+ bot could
  /// cause a duplicate open. Loops until `nextPageToken` comes back null.
  Future<List<Map<String, dynamic>>> listBotOrders({
    String status = 'running',
    String? base,
    String? quote,
    String? buOrderTypes,
  }) async {
    final all = <Map<String, dynamic>>[];
    String? pageToken;
    while (true) {
      final params = {
        'status': status,
        if (base != null) 'base': base,
        if (quote != null) 'quote': quote,
        if (buOrderTypes != null) 'buOrderTypes': buOrderTypes,
        if (pageToken != null) 'pageToken': pageToken,
      };
      final data = await _request('GET', '/api/v1/bot/orders', params: params);
      // A well-formed response always carries `results`, even as `[]`/`null`
      // for a genuinely empty account - only its ABSENCE signals a
      // malformed/degraded response. Treating a missing key silently as
      // "zero orders" would wipe the engine's whole picture of which grids
      // are actually running, which is exactly what lets it open a
      // duplicate real grid on a pair that already has one live.
      if (!data.containsKey('results')) {
        throw ApiException(
          'Pionex bot/orders response has no "results" key - treating this '
          'as a malformed response rather than "zero orders", to avoid the '
          'engine losing track of real running grids.',
        );
      }
      final results = data['results'];
      if (results == null) {
        // Confirmed live: Pionex represents "nothing matches this
        // status/filter" as `results: null` (not `[]`) when the account
        // genuinely has zero orders in that state - only an ABSENT key or
        // a present-but-wrong-type value (below) signals a malformed
        // response.
        break;
      }
      if (results is! List) {
        throw ApiException(
          'Pionex bot/orders "results" was ${results.runtimeType}, not a list.',
        );
      }
      all.addAll(results.cast<Map<String, dynamic>>());
      pageToken = data['nextPageToken'] as String?;
      if (pageToken == null || pageToken.isEmpty) break;
    }
    return all;
  }

  Future<List<Map<String, dynamic>>> getActiveGrids() =>
      listBotOrders(status: 'running', buOrderTypes: 'futures_grid');

  /// Pionex exposes closed futures-grid records under `status='finished'`
  /// (NOT `'closed'`) — using the wrong token here silently returns the
  /// running set instead, which was a real, live bug in the original engine.
  Future<List<Map<String, dynamic>>> getClosedGrids({int? sinceTs}) async {
    final list = await listBotOrders(
      status: 'finished',
      buOrderTypes: 'futures_grid',
    );
    if (sinceTs == null) return list;
    return list.where((o) {
      final data =
          (o['buOrderData'] as Map?)?.cast<String, dynamic>() ?? const {};
      final close =
          o['closeTime'] ??
          o['autoExpiredTime'] ??
          data['closeTime'] ??
          data['autoExpiredTime'];
      final ts = close ?? o['createTime'] ?? data['createTime'];
      final tsNum = _num(ts);
      return tsNum != null && tsNum >= sinceTs;
    }).toList();
  }

  /// Searches both 'running' and 'finished' — a freshly-closed grid moves to
  /// 'finished', matching getClosedGrids(). Returns null if not found.
  Future<Map<String, dynamic>?> getBotOrderByBuOrderId(String buOrderId) async {
    if (buOrderId.trim().isEmpty) {
      throw ArgumentError(
        'getBotOrderByBuOrderId REFUSED: no buOrderId provided',
      );
    }
    final pool = <Map<String, dynamic>>[];
    for (final status in ['running', 'finished']) {
      final orders = await listBotOrders(
        status: status,
        buOrderTypes: 'futures_grid',
      );
      pool.addAll(orders);
    }
    for (final o in pool) {
      final data =
          (o['buOrderData'] as Map?)?.cast<String, dynamic>() ?? const {};
      if (o['buOrderId']?.toString() == buOrderId ||
          data['buOrderId']?.toString() == buOrderId)
        return o;
    }
    return null;
  }

  /// Prefers `totalRealizedProfit`, then `gridProfit`, then `profitWithdrawn`,
  /// plus `totalFee` (2026-09-12, live, per the user: "the recent closed
  /// dotusdt p&l in pionex is -0.0258 ... while in app is 0??? ... it is
  /// -0.0258 ... 100% sure"): confirmed directly against Pionex's own
  /// bot-order record for that exact buOrderId - `totalRealizedProfit`
  /// alone read `-0.0192`, but Pionex's own displayed P&L is `-0.0258`,
  /// which is exactly `totalRealizedProfit + totalFee` (`-0.0192 +
  /// -0.0065632 = -0.0257632`, rounding to `-0.0258`). `totalFee` was
  /// never included at all before this fix - every closed bot's recorded
  /// P&L was silently missing its own trading fees, understating every
  /// loss (and overstating every profit) by the fee amount, not just
  /// this one bot. `totalFee` already carries its own sign (negative =
  /// a cost), so it's added directly, never subtracted.
  /// Returns null when the order can't be found or carries no numeric P/L.
  Future<double?> getGridPnl(String buOrderId) async {
    final rec = await getBotOrderByBuOrderId(buOrderId);
    if (rec == null) return null;
    final o = (rec['buOrderData'] as Map?)?.cast<String, dynamic>() ?? rec;
    final base =
        _num(o['totalRealizedProfit']) ??
        _num(o['gridProfit']) ??
        _num(o['profitWithdrawn']);
    if (base == null) return null;
    return base + (_num(o['totalFee']) ?? 0);
  }

  /// Polls for Pionex's real SETTLED P&L instead of a single immediate
  /// read (2026-09-19, per the user's own real-data audit: two manually
  /// stopped bots, `5743a3ea...` and `c8c898b9...`, were both recorded as
  /// LOSSES at stop time but were actually real PROFITS once Pionex
  /// finished settling - `totalRealizedProfit` updates asynchronously, so
  /// a read taken right at close/stop time can be stale). Shared by both
  /// the engine (recycle math - see `EngineService._getSettledGridPnl`'s
  /// original doc for the first real example this fixed, an ADA bot) and
  /// the GUI's own explicit-Stop flow, which is a separate process with
  /// its own `PionexClient` instance and can't reach the engine's private
  /// method. Treats two consecutive identical reads as settled; if it
  /// never stabilizes within [budget] it returns the LAST read rather than
  /// blocking the caller indefinitely.
  Future<double?> getSettledGridPnl(
    String buOrderId, {
    Duration budget = const Duration(seconds: 25),
    Duration pollEvery = const Duration(seconds: 5),
  }) async {
    double? previous;
    final deadline = DateTime.now().add(budget);
    while (true) {
      double? current;
      try {
        current = await getGridPnl(buOrderId);
      } catch (_) {
        // Swallowed here - callers already wrap their own P&L reads in
        // try/catch with their own logging; this just keeps polling on a
        // transient failure rather than aborting the whole settle-wait.
      }
      if (current != null &&
          previous != null &&
          (current - previous).abs() < 0.0000001) {
        return current;
      }
      if (DateTime.now().isAfter(deadline)) {
        return current ?? previous;
      }
      previous = current ?? previous;
      await Future<void>.delayed(pollEvery);
    }
  }

  double? _num(Object? v) {
    if (v == null || v == '') return null;
    if (v is num) return v.toDouble();
    final cleaned = v.toString().replaceAll(RegExp(r'[^\d.\-]'), '');
    return double.tryParse(cleaned);
  }

  void close() => _api.close();
}
