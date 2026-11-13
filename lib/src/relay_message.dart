/// What the relay pushes to a listening server: `{"event":...,"repo":...}`.
library;

import 'package:checked_json/checked_json.dart';

/// The GitHub event kinds the relay pushes by default. [RelayEventKind.parse]
/// returns null for anything else -- including a kind an operator has
/// configured WAKE_EVENTS to push that this build has never seen -- and a
/// receiver must treat null the same as "redeliver everything", the same way
/// it treats a reconnect: these two are the only kinds whose message tells it
/// which single list to re-read.
enum RelayEventKind {
  pullRequest('pull_request'),
  issues('issues');

  final String wire;
  const RelayEventKind(this.wire);

  static RelayEventKind? parse(String wire) {
    for (final k in values) {
      if (k.wire == wire) return k;
    }
    return null;
  }
}

/// One push from the relay to a listening server.
///
/// [event] is kept as the relay received it, on the `x-github-event` header,
/// alongside [kind] -- its typed reading -- because WAKE_EVENTS may name a
/// kind [RelayEventKind] does not, and the raw value is still worth logging
/// even when there is no typed member for it.
///
/// [repo] is the `owner/name` the (signed) body said this was about, or null
/// when the body did not say. The event kind comes from an UNSIGNED header --
/// see [webhook_gate.dart] -- so a receiver may use it only to pick which list
/// to re-read, never to decide what the delivery's contents mean.
class RelayMessage {
  final String event;
  final String? repo;

  const RelayMessage({required this.event, this.repo});

  RelayEventKind? get kind => RelayEventKind.parse(event);

  factory RelayMessage.fromJson(JsonObject json) => RelayMessage(
      event: json.string('event'), repo: json.stringOrNull('repo'));

  JsonObject toJson() => JsonObject.of({'event': event, 'repo': repo});
}
