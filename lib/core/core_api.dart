import 'dart:convert';

import 'package:http/http.dart' as http;

/// Thin, timeout-bound HTTP helper shared by every REST client in the app
/// (Pionex, CoinMarketCap). Every original Node fetch() call was wrapped in
/// `AbortSignal.timeout(...)` after an unbounded request once stalled the
/// whole mainLoop cycle forever — this mirrors that guard so no HTTP call in
/// the new engine can hang indefinitely either.
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.rawBody});

  final String message;
  final int? statusCode;
  final String? rawBody;

  @override
  String toString() => 'ApiException(status: $statusCode): $message';
}

/// Thrown specifically for HTTP 429 — distinguished from a generic
/// [ApiException] so a caller doing a multi-call sequence (e.g. the
/// grid-count probe's ~8 checkParams calls) can abort the WHOLE sequence
/// immediately instead of treating "rate limited" as "this one row is
/// invalid" and firing off several more calls into the same rate limit.
class RateLimitException implements Exception {
  RateLimitException(this.retryAfter);

  /// Server-suggested backoff, parsed from a `Retry-After` header when
  /// present (seconds). Null if the server didn't say.
  final Duration? retryAfter;

  @override
  String toString() => 'RateLimitException(retryAfter: $retryAfter)';
}

class CoreApi {
  CoreApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<Map<String, dynamic>> getJson(
    Uri uri, {
    Map<String, String>? headers,
    required Duration timeout,
    void Function(http.Response response)? onResponse,
  }) async {
    final response = await _client.get(uri, headers: headers).timeout(timeout);
    onResponse?.call(response);
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> sendJson(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    String? body,
    required Duration timeout,
    void Function(http.Response response)? onResponse,
  }) async {
    final http.Response response;
    switch (method) {
      case 'POST':
        response = await _client
            .post(uri, headers: headers, body: body)
            .timeout(timeout);
      case 'DELETE':
        response = await _client
            .delete(uri, headers: headers, body: body)
            .timeout(timeout);
      default:
        throw ArgumentError('unsupported method $method');
    }
    onResponse?.call(response);
    return _decodeObject(response);
  }

  Map<String, dynamic> _decodeObject(http.Response response) {
    if (response.statusCode == 429) {
      final retryAfterHeader = response.headers['retry-after'];
      final retryAfterSec = retryAfterHeader == null
          ? null
          : int.tryParse(retryAfterHeader);
      throw RateLimitException(
        retryAfterSec == null ? null : Duration(seconds: retryAfterSec),
      );
    }
    late final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (e) {
      throw ApiException(
        'non-JSON response: $e',
        statusCode: response.statusCode,
        rawBody: response.body,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw ApiException(
        'expected a JSON object response',
        statusCode: response.statusCode,
        rawBody: response.body,
      );
    }
    return decoded;
  }

  void close() => _client.close();
}
