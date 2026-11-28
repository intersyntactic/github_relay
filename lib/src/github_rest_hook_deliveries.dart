/// [ListsAndRedeliversHookDeliveries] over GitHub's REST API.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checked_json/checked_json.dart';

import 'redelivery_sweep.dart';

/// A token that may read and redeliver the swept hooks' deliveries
/// (`admin:repo_hook`, or a fine-grained token's "Webhooks: read and
/// write"). Never empty.
final class GitHubToken {
  const GitHubToken._(this._value);

  /// [s] as a token, or null when it is empty or would break a header.
  static GitHubToken? parse(String s) {
    final t = s.trim();
    return t.isEmpty || t.contains(RegExp(r'[\s\x00-\x1f]'))
        ? null
        : GitHubToken._(t);
  }

  final String _value;

  @override
  String toString() => 'GitHubToken(…)';
}

/// GitHub answered a call with something other than what it documents.
final class GitHubApiException implements Exception {
  const GitHubApiException(this.message);
  final String message;

  @override
  String toString() => 'GitHubApiException: $message';
}

final class GitHubRestHookDeliveries
    implements ListsAndRedeliversHookDeliveries {
  /// [api] is the REST API's root. The token is sent only to [api]'s origin:
  /// a `Link` header naming any other is not followed.
  GitHubRestHookDeliveries({
    required this._token,
    Uri? api,
    HttpClient? client,
    this.timeout = const Duration(seconds: 30),
    this.maxPages = 50,
    this.log = _stderr,
  }) : api = api ?? Uri.parse('https://api.github.com'),
       _client = client ?? HttpClient();

  final Uri api;

  /// The longest any one call may take, from connecting to the last byte.
  final Duration timeout;

  /// The most pages of 100 read per listing.
  final int maxPages;

  /// Says when a listing was cut short.
  final void Function(String line) log;

  static void _stderr(String line) => stderr.writeln(line);

  final GitHubToken _token;
  final HttpClient _client;

  @override
  Future<List<HookDeliveryAttempt>> attemptsSince(
    GitHubHook hook,
    DateTime since,
  ) async {
    final attempts = <HookDeliveryAttempt>[];
    Uri? next = api.replace(
      path: '${api.path}${hook.deliveriesPath}',
      queryParameters: {'per_page': '100'},
    );
    for (var page = 0; next != null && page < maxPages; page++) {
      final (status, body, link) = await _call('GET', next);
      if (status != 200) {
        throw GitHubApiException('listing $hook answered $status');
      }
      for (final a in _attempts(body)) {
        // Newest first: the first one older than [since] ends the listing.
        if (a.deliveredAt.isBefore(since)) return attempts;
        attempts.add(a);
      }
      next = _sameOrigin(_nextPage(link));
    }
    if (next != null) {
      log(
        'listing $hook: stopped at $maxPages pages; '
        'older attempts are not swept this pass',
      );
    }
    return attempts;
  }

  @override
  Future<void> redeliver(GitHubHook hook, int attemptId) async {
    final url = api.replace(
      path: '${api.path}${hook.deliveriesPath}/$attemptId/attempts',
    );
    final (status, _, _) = await _call('POST', url);
    // 202: GitHub has queued it.
    if (status < 200 || status >= 300) {
      throw GitHubApiException('redelivering $attemptId answered $status');
    }
  }

  /// [body], a page of the listing.
  static List<HookDeliveryAttempt> _attempts(String body) {
    // Every delivery id GitHub lists is past 2^53 (3856380378147192832), so
    // `id` comes back as its exact digits; HookDeliveryAttempt.fromJson
    // parses them into the VM's 64-bit int.
    final decoded = switch (decodeJsonRefusingDuplicateKeysAndUnsafeIntegers(
      body,
      integerFieldsAsStrings: const {'id'},
    )) {
      final List<Object?> items => items,
      _ => throw const GitHubApiException('a listing that is not a list'),
    };
    return [
      for (final item in decoded)
        HookDeliveryAttempt.fromJson(
          JsonObject.parse(item) ??
              (throw const GitHubApiException('an attempt that is no object')),
        ),
    ];
  }

  static final _next = RegExp(r'<([^>]+)>\s*;\s*rel="next"');

  static Uri? _nextPage(String? link) {
    if (link == null) return null;
    final m = _next.firstMatch(link);
    return m == null ? null : Uri.tryParse(m[1]!);
  }

  Uri? _sameOrigin(Uri? url) =>
      url != null &&
          url.scheme == api.scheme &&
          url.host == api.host &&
          url.port == api.port
      ? url
      : null;

  Future<(int, String, String?)> _call(String method, Uri url) =>
      _send(method, url).timeout(timeout);

  Future<(int, String, String?)> _send(String method, Uri url) async {
    final req = await _client.openUrl(method, url);
    req.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${_token._value}')
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set('x-github-api-version', '2022-11-28')
      ..set(HttpHeaders.userAgentHeader, 'is-github-relay-redelivery-sweep');
    final res = await req.close();
    final body = await utf8.decodeStream(res);
    return (res.statusCode, body, res.headers.value('link'));
  }

  void close() => _client.close(force: true);
}
