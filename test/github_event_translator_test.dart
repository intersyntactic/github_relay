import 'dart:convert';
import 'dart:typed_data';

import 'package:is_content_id/is_content_id.dart' show ObjectId;
import 'package:is_conversation_reply_vocabulary/is_conversation_reply_vocabulary.dart';
import 'package:is_docking_station_api/is_docking_station_api.dart';
import 'package:is_github_relay/is_github_relay.dart';
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart';
import 'package:test/test.dart';

final agent = GitHubUserId.parse(260000001)!;
final translator = GitHubEventTranslator(agent: agent);
const person = 1144884;

/// [bytes] as the relay records them, read back from its `github-event`
/// entry.
RelayedEvent recordedBytes(List<int> bytes) {
  final (kind, body) = encodeRelayedEvent(
    githubEventSource,
    at: DateTime.utc(2026, 11, 27, 0, 50),
    bytes: Uint8List.fromList(bytes),
  );
  final id = ObjectId.of(
    Uint8List.fromList([...utf8.encode('github-event\n-\n'), ...body]),
  );
  return RelayedEvent.read(id, kind, body)!;
}

RelayedEvent recorded(Map<String, Object?> delivery) =>
    recordedBytes(utf8.encode(jsonEncode(delivery)));

TranslatedEvent translate(Map<String, Object?> delivery) {
  final (state, event) = translator.step(translator.start, recorded(delivery));
  expect(state, isNull);
  return event;
}

Map<String, Object?> repository() => {
  'id': 700000001,
  'full_name': 'enspyrco/intersyntactic',
  'url': 'https://api.github.com/repos/enspyrco/intersyntactic',
};

Map<String, Object?> user(int id) => {
  'id': id,
  'login': id == agent.value ? 'intersyntactic-agent[bot]' : 'someone',
  'type': id == agent.value ? 'Bot' : 'User',
};

Map<String, Object?> issueComment({
  String action = 'created',
  int by = person,
  int commentId = 3500000001,
  String? body = 'Can you look at the failing build?',
  bool onPullRequest = false,
}) => {
  'action': action,
  'issue': {
    'id': 3000000007,
    'number': 7,
    'title': 'Build fails',
    'user': user(person),
    if (onPullRequest)
      'pull_request': {
        'url': 'https://api.github.com/repos/enspyrco/intersyntactic/pulls/7',
      },
  },
  'comment': {'id': commentId, 'body': body, 'user': user(by)},
  'repository': repository(),
  'sender': user(by),
};

Map<String, Object?> opened(
  String event, {
  int by = person,
  String? body = 'Steps to reproduce.',
}) => {
  'action': 'opened',
  event: {
    'id': 3000000009,
    'number': 9,
    'title': 'Crash on start',
    'body': body,
    'user': user(by),
  },
  'repository': repository(),
  'sender': user(by),
};

bool admits(ReplyEndpoint endpoint, String origin, String path) =>
    endpoint.admitsAddress(Origin.parse(origin)!, WebPath.parse(path)!);

void main() {
  test('a new comment is said in its issue, inside its repository', () {
    final said = translate(issueComment()) as MessageSaid;
    expect(
      said.addressInExternalSystem.value,
      'github:enspyrco/intersyntactic#7',
    );
    expect(said.containingAddress?.value, 'github:enspyrco/intersyntactic');
    expect(said.key.value, 'issue_comment.created:3500000001');
    expect(said.from.value, 'github:$person');
    expect(said.node.text, 'Can you look at the failing build?');
    expect(
      said.node.source.value,
      'enspyrco/intersyntactic/issues/comments/3500000001',
    );
    expect(said.addressedTo, isNull);
  });

  test("replies go to the thread's own issue and nowhere else", () {
    final endpoint = (translate(issueComment()) as MessageSaid).replyEndpoint!;
    const api = 'https://api.github.com';
    expect(
      admits(endpoint, api, '/repos/enspyrco/intersyntactic/issues/7/comments'),
      isTrue,
    );
    expect(
      admits(endpoint, api, '/repos/enspyrco/intersyntactic/issues/8/comments'),
      isFalse,
    );
    expect(
      admits(endpoint, api, '/repos/enspyrco/other/issues/7/comments'),
      isFalse,
    );
    expect(
      admits(
        endpoint,
        'https://example.com',
        '/repos/enspyrco/intersyntactic/issues/7/comments',
      ),
      isFalse,
    );
  });

  test('a comment on a pull request is said in that pull request', () {
    final said = translate(issueComment(onPullRequest: true)) as MessageSaid;
    expect(
      said.addressInExternalSystem.value,
      'github:enspyrco/intersyntactic#7',
    );
  });

  test('a new issue is said as its title and body', () {
    final said = translate(opened('issue')) as MessageSaid;
    expect(
      said.addressInExternalSystem.value,
      'github:enspyrco/intersyntactic#9',
    );
    expect(said.key.value, 'issues.opened:3000000009');
    expect(said.node.text, 'Crash on start\n\nSteps to reproduce.');
  });

  test('a new pull request is said, its title alone when it has no body', () {
    final said = translate(opened('pull_request', body: null)) as MessageSaid;
    expect(said.key.value, 'pull_request.opened:3000000009');
    expect(said.node.text, 'Crash on start');
    expect(
      admits(
        said.replyEndpoint!,
        'https://api.github.com',
        '/repos/enspyrco/intersyntactic/issues/9/comments',
      ),
      isTrue,
    );
  });

  group("the agent's own", () {
    test('comment is not said, so it never starts a turn', () {
      expect(translate(issueComment(by: agent.value)), isA<NothingToAdmit>());
    });

    test('edited comment is not admitted either', () {
      expect(
        translate(issueComment(action: 'edited', by: agent.value)),
        isA<NothingToAdmit>(),
      );
    });

    test('issue and pull request are not said', () {
      expect(
        translate(opened('issue', by: agent.value)),
        isA<NothingToAdmit>(),
      );
      expect(
        translate(opened('pull_request', by: agent.value)),
        isA<NothingToAdmit>(),
      );
    });
  });

  test("a person's edit or delete is not said again", () {
    expect(translate(issueComment(action: 'edited')), isA<NothingToAdmit>());
    expect(translate(issueComment(action: 'deleted')), isA<NothingToAdmit>());
  });

  test('a redelivery has the same key, even with different bytes', () {
    final first = translate(issueComment()) as MessageSaid;
    final again = translate({
      ...issueComment(),
      'installation': {'id': 1},
    }) as MessageSaid;
    expect(again.key, first.key);
    final other = translate(issueComment(commentId: 3500000002)) as MessageSaid;
    expect(other.key, isNot(first.key));
  });

  test('an empty comment is not said', () {
    expect(translate(issueComment(body: '  ')), isA<NothingToAdmit>());
    expect(translate(issueComment(body: null)), isA<NothingToAdmit>());
  });

  test('review comments, reviews, pushes and pings are not said', () {
    expect(
      translate({
        'action': 'created',
        'comment': {'id': 1, 'body': 'nit', 'user': user(person)},
        'pull_request': {
          'id': 2,
          'number': 3,
          'title': 't',
          'user': user(person),
        },
        'repository': repository(),
      }),
      isA<NothingToAdmit>(),
    );
    expect(
      translate({
        'action': 'submitted',
        'review': {'id': 1},
        'pull_request': {
          'id': 2,
          'number': 3,
          'title': 't',
          'user': user(person),
        },
        'repository': repository(),
      }),
      isA<NothingToAdmit>(),
    );
    expect(
      translate({'ref': 'refs/heads/main', 'repository': repository()}),
      isA<NothingToAdmit>(),
    );
    expect(
      translate({'zen': 'Keep it logically awesome.', 'hook_id': 700598542}),
      isA<NothingToAdmit>(),
    );
  });

  test('a body it cannot read is nothing to admit, never a throw', () {
    expect(
      translator.step(null, recordedBytes(utf8.encode('not json'))).$2,
      isA<NothingToAdmit>(),
    );
    expect(
      translator.step(null, recordedBytes([0xff, 0xfe])).$2,
      isA<NothingToAdmit>(),
    );
    final noUser = issueComment();
    (noUser['comment']! as Map<String, Object?>).remove(
      'user',
    ); // cast-ok: built just above
    expect(translate(noUser), isA<NothingToAdmit>());
    for (final url in [
      'not a url',
      'mailto:a@b.c',
      '/repos/enspyrco/intersyntactic',
    ]) {
      expect(
        translate({
          ...issueComment(),
          'repository': {...repository(), 'url': url},
        }),
        isA<NothingToAdmit>(),
        reason: url,
      );
    }
  });

  test('a user id must be positive', () {
    expect(GitHubUserId.parse(0), isNull);
    expect(GitHubUserId.parse(-1), isNull);
  });
}
