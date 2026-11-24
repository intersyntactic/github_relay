import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_docking_station_api/is_docking_station_api.dart'
    show RelayedEvent;
import 'package:is_github_relay/is_github_relay.dart';
import 'package:is_logbook_client/is_logbook_client.dart' show ObjectId;
import 'package:is_relay/is_relay.dart';
import 'package:test/test.dart';

import 'support/fake_logbook.dart';

final secret = GitHubWebhookSecret.parse('correct horse battery staple')!;
final check = GitHubDeliveryCheck(secret: secret);

Uint8List body(Map<String, Object?> payload) =>
    utf8.encode(jsonEncode(payload));

final issueOpened = body({
  'action': 'opened',
  'issue': {'number': 7, 'title': 'a task'},
  'repository': {'full_name': 'enspyrco/intersyntactic'},
});

String signatureOf(List<int> b) => 'sha256=${secret.sign(b)}';

HeaderCheck<GitHubOfferedSignature> headers(Map<String, String> h) =>
    check.checkHeaders(DeliveryHeaders(h), DateTime.utc(2026, 11, 24));

BodyVerdict verdict(Uint8List b, {String? signature}) =>
    switch (headers({'X-Hub-Signature-256': signature ?? signatureOf(b)})) {
      HeadersVouch(:final vouched) => check.checkBody(vouched, b),
      HeadersRefused(:final reason) => fail('headers refused: $reason'),
    };

Matcher refusedHeaders = isA<HeadersRefused<Object>>().having(
  (r) => r.status,
  'status',
  RefusalStatus.unauthorized,
);

void main() {
  group('the secret', () {
    test('an empty one is no secret', () {
      expect(GitHubWebhookSecret.parse(''), isNull);
    });

    test('signs as GitHub documents it', () {
      // GitHub's worked example, from "Validating webhook deliveries".
      final s = GitHubWebhookSecret.parse("It's a Secret to Everybody")!;
      expect(
        s.sign(utf8.encode('Hello, World!')),
        '757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17',
      );
    });

    test('never prints itself', () {
      expect('$secret', isNot(contains('horse')));
    });
  });

  group('the header check', () {
    test('refuses a delivery with no signature', () {
      expect(headers({'X-GitHub-Event': 'issues'}), refusedHeaders);
    });

    test('refuses the old sha1 signature', () {
      expect(headers({'X-Hub-Signature': 'sha1=${'0' * 40}'}), refusedHeaders);
    });

    test('refuses a sha256= that is not a digest', () {
      expect(headers({'X-Hub-Signature-256': 'sha256=nothex'}), refusedHeaders);
      expect(
        headers({'X-Hub-Signature-256': 'sha256=${'a' * 63}'}),
        refusedHeaders,
      );
    });

    test('vouches for a well-formed signature, without the body', () {
      expect(
        headers({'x-hub-signature-256': 'sha256=${'A' * 64}'}),
        isA<HeadersVouch<GitHubOfferedSignature>>(),
      );
    });
  });

  group('the body check', () {
    test('records a body whose HMAC holds', () {
      expect(verdict(issueOpened), isA<Record>());
    });

    test('takes the digest in upper case', () {
      final upper = 'sha256=${secret.sign(issueOpened).toUpperCase()}';
      expect(verdict(issueOpened, signature: upper), isA<Record>());
    });

    test('refuses a body that is not the one signed', () {
      final other = body({'action': 'closed'});
      expect(
        verdict(other, signature: signatureOf(issueOpened)),
        isA<Refuse>().having(
          (r) => r.status,
          'status',
          RefusalStatus.unauthorized,
        ),
      );
    });

    test('records a body that is not JSON: authenticity is all it checks', () {
      expect(verdict(utf8.encode('payload=%7B%7D')), isA<Record>());
    });

    test('answers with no body: GitHub reads only the status', () {
      expect((verdict(issueOpened) as Record).response, isNull);
    });
  });

  group('the event key', () {
    test('is the sha256 of the bytes', () {
      expect(
        githubEventKey(utf8.encode('Hello, World!')).value,
        'sha256:dffd6021bb2bd5b0af676290809ec3a53191dd81c7f70a4b28688a362182986f',
      );
    });

    test('is the same for a redelivery, which is the same bytes', () {
      expect(
        githubEventKey(Uint8List.fromList(issueOpened)),
        githubEventKey(Uint8List.fromList(issueOpened)),
      );
    });
  });

  group('the relay, end to end', () {
    late HttpServer server;
    late FakeLogbook logbook;
    late List<String> logged;
    late Uri url;

    setUp(() async {
      logbook = await FakeLogbook.start();
      logged = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      url = Uri.parse('http://127.0.0.1:${server.port}/webhook/github');
      RelayServer(
        check: check,
        logbook: logbook.socket,
        path: githubRelayPath,
        budget: githubRelayBudget,
        maxBodyBytes: githubMaxBodyBytes,
        rate: WriteRateBound(perMinute: 60, burst: 10),
        log: logged.add,
      ).serve(server).ignore();
    });

    tearDown(() async {
      await server.close(force: true);
      await logbook.stop();
    });

    Future<int> post(List<int> b, Map<String, String> h) async {
      final client = HttpClient();
      try {
        final req = await client.postUrl(url);
        h.forEach(req.headers.set);
        req.add(b);
        final res = await req.close();
        await res.drain<void>();
        return res.statusCode;
      } on SocketException {
        // A refusal unread drops the connection; read it off the log.
        return int.parse(logged.last.split(' ')[2]);
      } finally {
        client.close(force: true);
      }
    }

    test('records the exact bytes as github-event, then answers 200', () async {
      final status = await post(issueOpened, {
        'X-Hub-Signature-256': signatureOf(issueOpened),
        'X-GitHub-Event': 'issues',
        'Content-Type': 'application/json',
      });
      expect(status, 200);
      final (kind, entry) = FakeLogbook.parse(logbook.requests.single);
      expect(kind.name, 'github-event');
      final event = RelayedEvent.read(ObjectId.of(entry), kind, entry)!;
      expect(event.bytes, issueOpened);
    });

    test('records an event of any kind: there is no wake filter', () async {
      final push = body({'ref': 'refs/heads/main', 'commits': <Object?>[]});
      final status = await post(push, {
        'X-Hub-Signature-256': signatureOf(push),
        'X-GitHub-Event': 'push',
      });
      expect(status, 200);
      expect(logbook.requests, hasLength(1));
    });

    test('records nothing of an unsigned header', () async {
      await post(issueOpened, {
        'X-Hub-Signature-256': signatureOf(issueOpened),
        'X-GitHub-Event': 'relabelled-by-a-replayer',
        'X-GitHub-Delivery': 'not-a-guid',
      });
      final request = utf8.decode(logbook.requests.single);
      expect(request, isNot(contains('relabelled')));
      expect(request, isNot(contains('not-a-guid')));
    });

    test('refuses a forged body with 401 and records nothing', () async {
      final status = await post(body({'action': 'closed'}), {
        'X-Hub-Signature-256': signatureOf(issueOpened),
      });
      expect(status, 401);
      expect(logbook.requests, isEmpty);
    });

    test('refuses an unsigned delivery with 401 and records nothing', () async {
      final status = await post(issueOpened, {'X-GitHub-Event': 'ping'});
      expect(status, 401);
      expect(logbook.requests, isEmpty);
    });

    test('answers 503 when the logbook refuses, so it can be swept', () async {
      logbook.answer = FakeAnswer.refusedKind;
      final status = await post(issueOpened, {
        'X-Hub-Signature-256': signatureOf(issueOpened),
      });
      expect(status, 503);
      expect(AttemptOutcome.of(status), AttemptOutcome.worthAnotherTry);
    });
  });
}
