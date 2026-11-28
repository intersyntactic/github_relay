import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:is_github_relay/is_github_relay.dart';
import 'package:is_relay/is_relay.dart' show RefusalStatus;
import 'package:test/test.dart';

final now = DateTime.utc(2026, 11, 24, 12);
final hook = GitHubHook.parse('enspyrco/intersyntactic:700598542')!;

HookDeliveryAttempt attempt(
  int id,
  String guid,
  int status, {
  Duration ago = const Duration(minutes: 10),
}) => HookDeliveryAttempt(
  id: id,
  guid: guid,
  deliveredAt: now.subtract(ago),
  status: status,
);

/// Answers from [attempts], and records what was redelivered.
final class _FakeGitHub implements ListsAndRedeliversHookDeliveries {
  _FakeGitHub(this.attempts);

  final Map<String, List<HookDeliveryAttempt>> attempts;
  final redelivered = <(String, int)>[];
  final failListing = <String>{};
  final failRedelivery = <int>{};
  DateTime? askedSince;

  @override
  Future<List<HookDeliveryAttempt>> attemptsSince(
    GitHubHook hook,
    DateTime since,
  ) async {
    askedSince = since;
    if (failListing.contains('$hook')) {
      throw const GitHubApiException('listing answered 500');
    }
    return attempts['$hook'] ?? const [];
  }

  @override
  Future<void> redeliver(GitHubHook hook, int attemptId) async {
    if (failRedelivery.contains(attemptId)) {
      throw const GitHubApiException('answered 422');
    }
    redelivered.add(('$hook', attemptId));
  }
}

void main() {
  group('a hook', () {
    test("is a repository's as owner/repo:id", () {
      expect(
        hook,
        isA<RepositoryHook>().having(
          (h) => h.deliveriesPath,
          'path',
          '/repos/enspyrco/intersyntactic/hooks/700598542/deliveries',
        ),
      );
    });

    test("is an organisation's as org:id", () {
      expect(
        GitHubHook.parse('intersyntactic:12'),
        isA<OrganisationHook>().having(
          (h) => h.deliveriesPath,
          'path',
          '/orgs/intersyntactic/hooks/12/deliveries',
        ),
      );
    });

    test('is nothing else', () {
      for (final s in [
        '',
        'owner/repo',
        'owner/repo:',
        'owner/repo:0',
        'owner/repo:x',
        '../etc:1',
        'a/b/c:1',
        'owner/re po:1',
      ]) {
        expect(GitHubHook.parse(s), isNull, reason: s);
      }
    });
  });

  group('what an answer says', () {
    test('a 2xx delivered it', () {
      expect(AttemptOutcome.of(200), AttemptOutcome.delivered);
      expect(AttemptOutcome.of(204), AttemptOutcome.delivered);
    });

    test('no answer, 408, 429 and 5xx ask for another try', () {
      for (final s in [0, 408, 429, 500, 502, 503, 504]) {
        expect(
          AttemptOutcome.of(s),
          AttemptOutcome.worthAnotherTry,
          reason: '$s',
        );
      }
    });

    test('a refusal follows is_relay: final ones are refused', () {
      for (final s in [400, 401, 403, 404, 405, 413]) {
        expect(AttemptOutcome.of(s), AttemptOutcome.refused, reason: '$s');
      }
      for (final r in RefusalStatus.values) {
        expect(
          AttemptOutcome.of(r.code),
          r.worthAnotherTry
              ? AttemptOutcome.worthAnotherTry
              : AttemptOutcome.refused,
          reason: '${r.code}',
        );
      }
    });

    test('a status no relay refuses with asks for another try', () {
      // The relay never sends these, so they say nothing about the delivery.
      for (final s in [301, 402, 418, 421]) {
        expect(
          AttemptOutcome.of(s),
          AttemptOutcome.worthAnotherTry,
          reason: '$s',
        );
      }
    });
  });

  group('which attempts are redelivered', () {
    List<HookDeliveryAttempt> redeliverable(
      List<HookDeliveryAttempt> attempts,
    ) => attemptsToRedeliver(attempts, now: now);

    test('a failed delivery, once, by its latest attempt', () {
      final due = redeliverable([
        attempt(3, 'a', 503, ago: const Duration(minutes: 1)),
        attempt(1, 'a', 0, ago: const Duration(minutes: 20)),
        attempt(2, 'a', 503, ago: const Duration(minutes: 10)),
      ]);
      expect(due.map((a) => a.id), [3]);
    });

    test('none of a delivery that any attempt delivered', () {
      final due = redeliverable([
        attempt(1, 'a', 503, ago: const Duration(minutes: 20)),
        attempt(2, 'a', 200, ago: const Duration(minutes: 10)),
        attempt(3, 'a', 503, ago: const Duration(minutes: 1)),
      ]);
      expect(due, isEmpty);
    });

    test('oldest delivery first, by its first attempt', () {
      final due = redeliverable([
        attempt(9, 'new', 503, ago: const Duration(minutes: 1)),
        attempt(8, 'old', 503, ago: const Duration(minutes: 2)),
        attempt(2, 'old', 503, ago: const Duration(hours: 60)),
        attempt(5, 'mid', 0, ago: const Duration(hours: 5)),
      ]);
      expect(due.map((a) => a.guid), ['old', 'mid', 'new']);
    });

    test('a refused one, once its latest attempt is an hour old', () {
      // A 401 during a secret rotation, or a proxy's 404 mid-deploy.
      expect(
        redeliverable([attempt(1, 'a', 401, ago: const Duration(minutes: 59))]),
        isEmpty,
      );
      expect(
        redeliverable([
          attempt(1, 'a', 503, ago: const Duration(hours: 3)),
          attempt(2, 'a', 401, ago: const Duration(hours: 1)),
        ]).map((a) => a.id),
        [2],
      );
    });

    test('a refused one, no more after three attempts in all', () {
      expect(
        redeliverable([
          attempt(1, 'a', 404, ago: const Duration(hours: 5)),
          attempt(2, 'a', 404, ago: const Duration(hours: 3)),
          attempt(3, 'a', 404, ago: const Duration(hours: 1)),
        ]),
        isEmpty,
      );
    });

    test('a refused one is tried again only on the latest answer', () {
      // A 503 after a 401 is due every pass again, not capped.
      expect(
        redeliverable([
          for (var i = 1; i <= 5; i++)
            attempt(i, 'a', i == 1 ? 401 : 503, ago: Duration(minutes: 60 - i)),
        ]).map((a) => a.id),
        [5],
      );
    });

    test('each failed delivery on its own', () {
      final due = redeliverable([
        attempt(1, 'a', 503),
        attempt(2, 'b', 204),
        attempt(3, 'c', 0),
      ]);
      expect(due.map((a) => a.guid), unorderedEquals(['a', 'c']));
    });
  });

  group('a sweep', () {
    late List<String> logged;
    setUp(() => logged = []);

    RedeliverySweep sweepOf(
      _FakeGitHub github, {
      List<GitHubHook>? hooks,
      int maxPerSweep = 30,
    }) => RedeliverySweep(
      github: github,
      hooks: hooks ?? [hook],
      maxPerSweep: maxPerSweep,
      now: () => now,
      log: logged.add,
    );

    test('redelivers what failed, and reads only inside the window', () async {
      final github = _FakeGitHub({
        '$hook': [attempt(9, 'a', 503), attempt(8, 'b', 204)],
      });
      final result = await sweepOf(github).sweep();
      expect(result, (redelivered: 1, failed: 0));
      expect(github.redelivered, [('$hook', 9)]);
      expect(github.askedSince, now.subtract(const Duration(hours: 71)));
    });

    test('goes on to the next hook when one listing fails', () async {
      final other = GitHubHook.parse('intersyntactic:12')!;
      final github = _FakeGitHub({
        '$other': [attempt(5, 'x', 0)],
      })..failListing.add('$hook');
      final result = await sweepOf(github, hooks: [hook, other]).sweep();
      expect(result, (redelivered: 1, failed: 0));
      expect(logged.first, contains('listing failed'));
    });

    test('counts a redelivery GitHub refuses, and goes on', () async {
      final github = _FakeGitHub({
        '$hook': [attempt(1, 'a', 503), attempt(2, 'b', 503)],
      })..failRedelivery.add(1);
      final result = await sweepOf(github).sweep();
      expect(result, (redelivered: 1, failed: 1));
    });

    test('asks for at most maxPerSweep in one pass', () async {
      final github = _FakeGitHub({
        '$hook': [for (var i = 1; i <= 5; i++) attempt(i, 'g$i', 503)],
      });
      final result = await sweepOf(github, maxPerSweep: 2).sweep();
      expect(result, (redelivered: 2, failed: 0));
    });

    test('a redelivery GitHub refuses takes no room in the pass', () async {
      final github = _FakeGitHub({
        '$hook': [for (var i = 1; i <= 5; i++) attempt(i, 'g$i', 503)],
      })..failRedelivery.addAll([1, 2, 3]);
      final result = await sweepOf(github, maxPerSweep: 2).sweep();
      expect(result, (redelivered: 2, failed: 3));
    });

    test('logs ids and statuses, never a token', () async {
      final github = _FakeGitHub({
        '$hook': [attempt(9, 'a', 503)],
      });
      await sweepOf(github).sweep();
      expect(logged.last, contains('attempt 9, was 503'));
    });
  });

  group('the REST API', () {
    late HttpServer api;
    late List<HttpRequest> seen;
    late FutureOr<void> Function(HttpRequest) answer;
    late GitHubRestHookDeliveries github;
    final token = GitHubToken.parse('ghp_test')!;

    setUp(() async {
      seen = [];
      api = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      api.listen((req) async {
        seen.add(req);
        await answer(req);
        await req.response.close();
      });
      github = GitHubRestHookDeliveries(
        token: token,
        api: Uri.parse('http://127.0.0.1:${api.port}'),
      );
    });

    tearDown(() async {
      github.close();
      await api.close(force: true);
    });

    Map<String, Object?> wire(int id, String guid, int status, Duration ago) =>
        {
          'id': id,
          'guid': guid,
          'delivered_at': now.subtract(ago).toIso8601String(),
          'redelivery': false,
          'status': 'OK',
          'status_code': status,
          'event': 'issues',
        };

    test('lists across pages, newest first, until the window ends', () async {
      final base = 'http://127.0.0.1:${api.port}';
      answer = (req) {
        final cursor = req.uri.queryParameters['cursor'];
        final page = switch (cursor) {
          null => [
            wire(3855678701813374976, 'a', 204, const Duration(minutes: 1)),
            wire(3855678701813374975, 'b', 503, const Duration(minutes: 2)),
          ],
          _ => [
            wire(2, 'c', 0, const Duration(hours: 1)),
            wire(1, 'd', 503, const Duration(hours: 80)),
          ],
        };
        if (cursor == null) {
          req.response.headers.set(
            'link',
            '<$base${req.uri.path}?per_page=100&cursor=v1_2>; rel="next"',
          );
        }
        req.response.write(jsonEncode(page));
      };
      final got = await github.attemptsSince(
        hook,
        now.subtract(const Duration(hours: 71)),
      );
      expect(got.map((a) => a.guid), ['a', 'b', 'c']);
      // An id past 2^53 survives: the VM's int is 64-bit.
      expect(got.first.id, 3855678701813374976);
      expect(seen, hasLength(2));
      expect(
        seen.first.uri.path,
        '/repos/enspyrco/intersyntactic/hooks/700598542/deliveries',
      );
      expect(seen.first.uri.queryParameters['per_page'], '100');
      expect(seen.first.headers.value('authorization'), 'Bearer ghp_test');
      expect(seen.first.headers.value('x-github-api-version'), '2022-11-28');
    });

    test('never follows a next page to another origin', () async {
      answer = (req) {
        req.response.headers.set(
          'link',
          '<https://evil.example/collect?per_page=100>; rel="next"',
        );
        req.response.write(
          jsonEncode([wire(1, 'a', 503, const Duration(minutes: 1))]),
        );
      };
      final got = await github.attemptsSince(
        hook,
        now.subtract(const Duration(hours: 71)),
      );
      expect(got, hasLength(1));
      expect(seen, hasLength(1));
    });

    test('says so when it stops at maxPages', () async {
      final base = 'http://127.0.0.1:${api.port}';
      final lines = <String>[];
      final capped = GitHubRestHookDeliveries(
        token: token,
        api: Uri.parse(base),
        maxPages: 1,
        log: lines.add,
      );
      answer = (req) {
        req.response.headers.set(
          'link',
          '<$base${req.uri.path}?cursor=v1_2>; rel="next"',
        );
        req.response.write(
          jsonEncode([wire(1, 'a', 503, const Duration(minutes: 1))]),
        );
      };
      final got = await capped.attemptsSince(
        hook,
        now.subtract(const Duration(hours: 71)),
      );
      capped.close();
      expect(got, hasLength(1));
      expect(lines.single, contains('stopped at 1 pages'));
    });

    test('refuses a listing that names a key twice', () async {
      answer = (req) => req.response.write(
        '[{"id":1,"guid":"a","delivered_at":"${now.toIso8601String()}",'
        '"status_code":503,"status_code":200}]',
      );
      await expectLater(
        github.attemptsSince(hook, now.subtract(const Duration(hours: 1))),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws on a listing GitHub refuses', () async {
      answer = (req) => req.response.statusCode = 404;
      await expectLater(
        github.attemptsSince(hook, now),
        throwsA(isA<GitHubApiException>()),
      );
    });

    test('redelivers with a POST to the attempt', () async {
      answer = (req) => req.response.statusCode = 202;
      await github.redeliver(hook, 42);
      expect(seen.single.method, 'POST');
      expect(
        seen.single.uri.path,
        '/repos/enspyrco/intersyntactic/hooks/700598542/deliveries/42/attempts',
      );
    });

    test('throws on a redelivery GitHub refuses', () async {
      answer = (req) => req.response.statusCode = 422;
      await expectLater(
        github.redeliver(hook, 42),
        throwsA(isA<GitHubApiException>()),
      );
    });

    test('a token is never empty, never printed', () {
      expect(GitHubToken.parse(''), isNull);
      expect(GitHubToken.parse('a b'), isNull);
      expect('$token', isNot(contains('ghp')));
    });
  });
}
