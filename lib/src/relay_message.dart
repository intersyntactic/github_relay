/// What the relay pushes to a listening server: `{"event":...,"repo":...}`.
library;

import 'package:checked_json/checked_json.dart';

/// The GitHub event kinds the relay pushes by default and can tell apart.
/// [RelayEvent.kind] is null for anything else -- including a kind an
/// operator has configured WAKE_EVENTS to push that this build has never
/// seen -- and a receiver must treat null the same as "redeliver
/// everything", the same way it treats a reconnect: these two are the only
/// kinds whose message tells it which single list to re-read.
enum RelayEventKind { pullRequest, issues }

/// A GitHub event kind, read off the wire exactly once at [RelayEvent.parse].
/// Every string is a valid [RelayEvent] -- an operator may set WAKE_EVENTS to
/// a kind this build predates, and that delivery must still be representable,
/// not rejected -- so [parse] never returns null; an event this build has no
/// case for becomes the unknown case instead, built only inside this library.
///
/// [wire] is kept as the relay received it, on the `x-github-event` header,
/// alongside [kind] -- the typed reading -- because the raw value is still
/// worth logging even when there is no typed member for it.
sealed class RelayEvent {
  const RelayEvent._();

  const factory RelayEvent.pullRequest() = _PullRequest;
  const factory RelayEvent.issues() = _Issues;

  factory RelayEvent.parse(String wire) => switch (wire) {
        'pull_request' => const RelayEvent.pullRequest(),
        'issues' => const RelayEvent.issues(),
        _ => _Unknown(wire),
      };

  String get wire;

  RelayEventKind? get kind => switch (this) {
        _PullRequest() => RelayEventKind.pullRequest,
        _Issues() => RelayEventKind.issues,
        _Unknown() => null,
      };
}

final class _PullRequest extends RelayEvent {
  const _PullRequest() : super._();
  @override
  String get wire => 'pull_request';
}

final class _Issues extends RelayEvent {
  const _Issues() : super._();
  @override
  String get wire => 'issues';
}

final class _Unknown extends RelayEvent {
  const _Unknown(this.wire) : super._();
  @override
  final String wire;
}

/// One push from the relay to a listening server.
///
/// [repo] is the `owner/name` the (signed) body said this was about, or null
/// when the body did not say. [event] comes from an UNSIGNED header -- see
/// [webhook_gate.dart] -- so a receiver may use it only to pick which list to
/// re-read, never to decide what the delivery's contents mean.
class RelayMessage {
  final RelayEvent event;
  final String? repo;

  const RelayMessage({required this.event, this.repo});

  RelayEventKind? get kind => event.kind;

  factory RelayMessage.fromJson(JsonObject json) => RelayMessage(
      event: RelayEvent.parse(json.string('event')),
      repo: json.stringOrNull('repo'));

  JsonObject toJson() => JsonObject.of({'event': event.wire, 'repo': repo});
}
