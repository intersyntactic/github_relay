# is_github_relay

The meeting point between GitHub and a machine nothing can reach.

GitHub POSTs `/webhook/github` to wherever this is deployed; each server
that has dialled `/ws` (outbound from its side, so no inbound port on a
laptop) is told that something changed. Nothing here asks GitHub anything
and nothing polls: the only timer is the websocket ping that notices a dead
connection.

```dart
import 'package:is_github_relay/is_github_relay.dart';

final relay = Relay(
  secret: Platform.environment['GITHUB_WEBHOOK_SECRET']!,
  token: Platform.environment['RELAY_TOKEN']!,
);
final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8080);
await for (final req in server) {
  unawaited(relay.handle(req));
}
```

## The pushed message

A pushed websocket frame is `{"event":"pull_request","repo":"owner/name"}`,
typed as `RelayMessage` (`RelayMessage.fromJson`/`toJson`). `event` is kept
raw alongside its typed reading, `RelayMessage.kind` (`RelayEventKind`),
because `WAKE_EVENTS` may be configured to push a kind this build does not
know; a receiver should treat a null `kind` the same as a reconnect --
"something may have changed, re-read everything" -- never fall through to
acting on the raw string.

The event kind comes from GitHub's `x-github-event` header, which is NOT
covered by the request signature. A receiver may use it only to pick which
list to re-read, never to decide what the delivery's contents mean -- see
the comment on `gate` in `lib/src/webhook_gate.dart` for why, and what would
have to change first.

## Running it

See `bin/github_relay.dart`'s doc comment for the environment variables.
`Dockerfile` builds a static binary onto `FROM scratch`, binding
`0.0.0.0:8085` inside the container; put TLS in front of it, since GitHub
needs https and the listener token travels in a header.

A bare `POST /webhook/github` with no `x-github-event` header gets `204`,
unverified -- by design, matching GitHub's own `event` header dispatch, not
a bug. A liveness probe that sends a bare POST will read as healthy without
exercising the signature check at all; probe with `X-GitHub-Event: ping`
plus a correctly signed empty body if the check itself needs exercising.

## A second source (Teams is already live)

This relay's listener fanout (`/ws`, `_listeners`, `_broadcast` in
`lib/src/relay.dart`) is GitHub-adjacent only because it was built before a
second source existed. A Teams relay (`teams_module`) is a separate
deployment at `teams.intersyntactic.space`, with no bus shared between it
and this one. `lib/src/webhook_gate.dart`'s `gate()` is already
source-keyed, not GitHub-shaped; the fanout isn't yet. See
`docs/bus-design.md` for the design of what closes that gap, including a
constraint from the airlock that any such design has to sit behind.
