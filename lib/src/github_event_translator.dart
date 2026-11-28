import 'dart:convert';

import 'package:checked_json/checked_json.dart';
import 'package:is_conversation_vocabulary/is_conversation_vocabulary.dart'
    show RepliesUnderWebAddress, SourceMessageId, UserSaid;
import 'package:is_docking_station_api/is_docking_station_api.dart';
import 'package:is_shapes/is_shapes.dart' show ActorId;
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart'
    show AddressPrefix, Origin, PathPrefix;

import 'github_delivery_check.dart' show githubEventSource;

/// A GitHub account's numeric user id. The id never changes; a login can be
/// renamed, and a GitHub App's bot login follows its app's slug.
final class GitHubUserId {
  const GitHubUserId._(this.value);

  final int value;

  /// [id] as a user id, or null unless it is positive.
  static GitHubUserId? parse(int id) => id > 0 ? GitHubUserId._(id) : null;

  /// The actor the docking station knows this account as.
  ActorId get actor => ActorId.parse('github:$value')!;

  @override
  bool operator ==(Object other) =>
      other is GitHubUserId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'GitHubUserId($value)';
}

/// The GitHub relay's translator, for the docking station: what each
/// delivery the relay recorded is, in the docking station's terms.
///
/// Something said is a new issue, a new pull request, or a new comment on
/// either: each is [MessageSaid] in that issue's or pull request's thread.
/// Everything else is [NothingToAdmit] for now:
///
/// - anything [agent] wrote. GitHub delivers the agent's own comments to its
///   webhook too, and each said event may start a turn, so admitting them
///   would have the agent answer itself without end;
/// - an edit or a delete, until a module can say what a message became;
/// - review comments, reviews, pushes and every other event;
/// - a body this can't read.
///
/// It keeps no state: every delivery names its repository, thread, author
/// and text, so `step` reads each one alone.
///
/// The relay records only the signed body, since `X-GitHub-Event` sits
/// outside the HMAC, so an event is told by its body's shape: an `action`,
/// and which of `comment`, `issue` and `pull_request` it carries.
///
/// Addresses: `github:<owner>/<repo>#<number>` for a thread, inside
/// `github:<owner>/<repo>`, the mission. Replies go under the thread's
/// issue in the REST API the delivery names (`repository.url`), which is
/// where GitHub takes comments on issues and pull requests alike.
///
/// Event keys are GitHub's own id for what happened, not the delivery's
/// bytes, so a redelivery has the same key even if GitHub sends it with
/// different bytes: `issue_comment.created:<comment id>`,
/// `issues.opened:<issue id>`, `pull_request.opened:<pull request id>`.
///
/// [AddressedEvent.addressedTo] is null: a repository's webhook is sent to
/// no account GitHub vouches for.
final class GitHubEventTranslator implements TranslatesRelayedEvents<Null> {
  const GitHubEventTranslator({required this.agent});

  /// The account the agent writes on GitHub as, whose own messages are
  /// never admitted.
  final GitHubUserId agent;

  @override
  RelayedEventSource get source => githubEventSource;

  @override
  Null get start => null;

  @override
  (Null, TranslatedEvent) step(Null state, RelayedEvent recorded) {
    final GitHubSaid? said;
    try {
      said = GitHubSaid.fromJson(
        JsonObject.decode(utf8.decode(recorded.bytes)),
      );
    } on FormatException {
      // The relay records every authentic delivery, read or not, so this is
      // a body that isn't what its shape promised: nothing to admit, rather
      // than a fold that stops at it every time the docking station starts.
      return (null, const NothingToAdmit());
    }
    if (said == null || said.author == agent) {
      return (null, const NothingToAdmit());
    }
    return (null, said.event ?? const NothingToAdmit());
  }
}

/// What a new issue, pull request or comment says, read from a delivery's
/// body.
final class GitHubSaid {
  const GitHubSaid._({
    required this.repository,
    required this.apiRepository,
    required this.number,
    required this.key,
    required this.source,
    required this.author,
    required this.text,
  });

  /// The delivery [json] as something said, or null when it is some other
  /// event. Throws [FormatException] when it has the shape of one but a
  /// field of it doesn't.
  static GitHubSaid? fromJson(JsonObject json) {
    final action = json.stringOrNull('action');
    final repo = json.objectOrNull('repository');
    if (action == null || repo == null) return null;
    final fullName = repo.string('full_name');
    final apiRepository = Uri.tryParse(repo.string('url'));
    // Checked here, since Uri.origin throws a StateError, not a
    // FormatException, on anything but an http(s) address.
    if (apiRepository == null ||
        !apiRepository.hasAuthority ||
        !(apiRepository.isScheme('https') || apiRepository.isScheme('http'))) {
      throw const FormatException('repository.url is not a web address');
    }
    switch ((
      action,
      json.objectOrNull('comment'),
      json.objectOrNull('issue'),
      json.objectOrNull('pull_request'),
      json.has('review'),
    )) {
      case ('created', final comment?, final issue?, null, false):
        final number = issue.integer('number');
        final id = comment.integer('id');
        return GitHubSaid._(
          repository: fullName,
          apiRepository: apiRepository,
          number: number,
          key: 'issue_comment.created:$id',
          source: '$fullName/issues/comments/$id',
          author: _author(comment),
          text: comment.stringOrNull('body') ?? '',
        );
      case ('opened', null, final issue?, null, false):
        return _opened(fullName, apiRepository, 'issues', issue);
      case ('opened', null, null, final pull?, false):
        return _opened(fullName, apiRepository, 'pull_request', pull);
      default:
        return null;
    }
  }

  static GitHubSaid _opened(
    String fullName,
    Uri apiRepository,
    String event,
    JsonObject opened,
  ) {
    final number = opened.integer('number');
    final body = opened.stringOrNull('body') ?? '';
    final title = opened.string('title');
    return GitHubSaid._(
      repository: fullName,
      apiRepository: apiRepository,
      number: number,
      key: '$event.opened:${opened.integer('id')}',
      source: '$fullName/issues/$number',
      author: _author(opened),
      text: body.isEmpty ? title : '$title\n\n$body',
    );
  }

  static GitHubUserId? _author(JsonObject written) =>
      GitHubUserId.parse(written.object('user').integer('id'));

  /// `<owner>/<repo>`.
  final String repository;

  /// The repository in the REST API, such as
  /// `https://api.github.com/repos/<owner>/<repo>`.
  final Uri apiRepository;

  /// The issue's or pull request's number.
  final int number;
  final String key;
  final String source;

  /// Null when GitHub names no account it can be: a deleted user's `id` is
  /// still positive, so in practice this is set.
  final GitHubUserId? author;
  final String text;

  /// This as the docking station's event, or null when a part of it isn't
  /// one the docking station takes.
  MessageSaid? get event {
    final address = AddressInExternalSystem.parse('github:$repository#$number');
    final key = EventKey.parse(this.key);
    final source = SourceMessageId.parse(this.source);
    final author = this.author;
    final origin = Origin.parse(apiRepository.origin);
    final thread = PathPrefix.parse('${apiRepository.path}/issues/$number/');
    if (address == null ||
        key == null ||
        source == null ||
        author == null ||
        origin == null ||
        thread == null ||
        text.trim().isEmpty) {
      return null;
    }
    return MessageSaid(
      addressInExternalSystem: address,
      containingAddress: AddressInExternalSystem.parse('github:$repository'),
      addressedTo: null,
      replyEndpoint: RepliesUnderWebAddress(AddressPrefix.of(origin, thread)),
      key: key,
      node: UserSaid(author: author.actor, source: source, text: text),
    );
  }
}
