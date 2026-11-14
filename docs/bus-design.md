# The bus: a design, not yet built

This repo currently plays two roles in one process: it verifies GitHub's
webhook and it fans the result out to every listener on `/ws`. That second
role -- `_listen`/`_listeners`/`_broadcast` in `lib/src/relay.dart` -- isn't
actually GitHub-specific. It's a generic "one producer, many consumers"
broadcast, and it's the part that has to change the day a second source
(Microsoft Teams webhooks, most likely) shows up.

`lib/src/webhook_gate.dart`'s own doc comment already anticipated this:
"SOURCE-KEYED, NOT GITHUB-SHAPED. A `SourceSpec` per source, so another
pusher can be added without a second gate." `gate()` takes `sourceName` and
`SourceSpec` as parameters, not GitHub hardcoded, for exactly this reason.
This doc is about the half of the system that hasn't caught up yet: the
listener fanout, which today only exists inside this one GitHub-specific
process.

## The decision this doc assumes

Two shapes were on the table:

1. **One process, multiple routes.** A single deployed binary mounts
   `/webhook/github` and (later) `/webhook/teams`, each its own handler with
   its own `SourceSpec`, both broadcasting onto one in-memory `_listeners`
   set. Free -- no new service, no new auth, no new failure mode -- but it
   means `github_relay` and a future `teams_relay` can't be deployed,
   restarted, or scaled independently, and doesn't fit two separately-named
   subdomains.

2. **Separate processes, one shared bus.** `github_relay` and a future
   `teams_relay` are independent deployments, each with its own subdomain,
   each pushing what it already verified into a third thing that owns the
   listener fanout.

**Chosen: (2).** `github_relay.intersyntactic.space` is this repo's own
subdomain specifically because a second source gets its own subdomain too,
not a path on this one. That decision is what makes a shared bus necessary
in the first place -- it's a cost taken on deliberately, not a requirement
`gate()`'s design forced.

## The bus

A new, not-yet-built package/deployment (working name `intersyntactic_bus`,
working hostname `relay.intersyntactic.space` -- freed up by this repo's
move to its own subdomain).

It owns:

- `/ws`: unchanged from today's `_listen`/`_listeners`/`_broadcast`, lifted
  out of `Relay` wholesale. A listener (IS, wherever it runs) dials in with
  `Authorization: Bearer <listener-token>`, exactly as it does today.
- `/publish`: new, and **also a websocket upgrade, not an HTTP POST.** A
  source relay (`github_relay`, later `teams_relay`) dials in with
  `Authorization: Bearer <publisher-token>` and holds the connection open,
  writing a message onto it whenever its own gate says to. This mirrors
  `/ws`'s own check-token-then-upgrade shape exactly (the same
  `constantTimeEquals` pattern, the same `WebSocketTransformer.upgrade`),
  and lets `github_relay`'s side reuse whatever reconnect-with-backoff
  client code `relay_client.dart` already has for listeners -- a relay
  becomes a client of the bus the same way IS is a client of the bus, just
  writing instead of reading.

  Websocket over HTTP here isn't about reachability (a source relay is
  always reachable, by definition -- GitHub/Teams have to reach it). It's
  that a held-open connection tells the relay the bus is down the moment it
  drops, rather than only at the next webhook, and it means one connection
  abstraction serves both directions instead of two.

- A publisher-token registry: each token maps to exactly one source name.
  **The bus decides `source` from which token authenticated a connection,
  never from a field the message claims.** Same principle `webhook_gate.dart`
  already applies to signatures -- ask once, at the boundary, trust nothing
  self-reported. A leaked `github_relay` token must never be usable to forge
  a `teams` event.

- Nothing else. The bus does not parse the payload. It wraps whatever bytes
  a source relay already produced (today's `RelayMessage.toJson()`,
  unchanged) in a thin envelope -- `{"source": "github", "message": {...}}`
  -- and forwards that, unexamined, to every listener. It does not debounce:
  `relay.dart`'s existing stance ("COALESCING is not done here... the
  receiver's own topic debounce does the coalescing") holds just as well
  with a bus in front as it did without one.

Fire-and-forget on the publish side, same as today's `_broadcast`: no retry
queue, no ack. A dropped notification recovers itself the same way a dropped
listener write already does -- the next real event, or GitHub's/Teams' own
redelivery, catches it up. This matches `webhook_gate.dart`'s existing
tolerance for a replayed-but-idempotent trigger; nothing here raises the bar
on reliability past what the rest of the system already accepts.

## What changes in this repo, when that day comes

`lib/src/relay.dart`'s `Relay` loses `_listen`, `_listeners`, `_broadcast`,
the `/ws` route, `close()`'s listener-closing loop, and the `listeners`
getter -- all of it moves to the bus package instead. Where `_broadcast`
is called today, `Relay` instead writes to its own held-open connection to
the bus's `/publish`. `handle()` keeps exactly one route,
`/webhook/github`; everything about verifying and parsing GitHub's webhook
is untouched.

Every current listener's wire format changes -- `{source, message}` instead
of a bare `RelayMessage` at the top level -- which is why this is a real
migration, not a config flag.

## Why this isn't built yet

There is still exactly one source. Building the bus now would be paying for
a second source that doesn't exist, against an auth/envelope shape that
hasn't been tested against what Teams' webhooks actually look like.
`SourceSpec`/`gate()` already proved the cheap part (multi-source
verification) could be anticipated without the bus needing to exist first;
extracting `_listeners`/`_broadcast` into a standalone service is mechanical
and low-risk whenever a second source becomes real, not before. This doc
exists so that whoever does it then doesn't have to re-derive the reasoning
above from scratch.
