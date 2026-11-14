# The bus: a design, not yet built

**Corrected 2026-11-14, per `intersyntactic-a8`:** the first version of this
doc assumed a second source was hypothetical and future. It isn't. A Teams
relay (`teams_module`'s `bin/teams_relay.dart`) has been live on
`enspyr-syd` since this morning, at `teams.intersyntactic.space` -- its own
separate process and deployment, already the shape "the decision" below
argues for. This doc is behind reality, not ahead of it; treat "why this
isn't built yet" as the part most likely to be wrong.

This repo currently plays two roles in one process: it verifies GitHub's
webhook and it fans the result out to every listener on `/ws`. That second
role -- `_listen`/`_listeners`/`_broadcast` in `lib/src/relay.dart` -- isn't
actually GitHub-specific. It's a generic "one producer, many consumers"
broadcast. `teams_relay.dart` almost certainly duplicates it today, since it
was built as its own separate process before this doc existed.

`lib/src/webhook_gate.dart`'s own doc comment anticipated the verification
half of this: "SOURCE-KEYED, NOT GITHUB-SHAPED. A `SourceSpec` per source, so
another pusher can be added without a second gate." `gate()` takes
`sourceName` and `SourceSpec` as parameters, not GitHub hardcoded, for
exactly this reason. This doc is about the half that verification doesn't
cover: the listener fanout, which exists at least twice right now (once
here, once in `teams_module`) with nothing shared between them.

## Hostnames: no underscores

Since CA/B Forum ballot SC12, Let's Encrypt refuses a certificate name
containing `_`. A hostname like `github_relay.intersyntactic.space` cannot
get a cert -- Caddy fails, the source goes dark. `intersyntactic-a8` and
`infra-5e` hit this on `teams_relay.*` today. Use a hyphen if a compound
name is wanted (`github-relay.`, `teams-relay.`); the two deployments that
actually exist right now are simpler than that anyway:

- GitHub relay (this repo): **`github.intersyntactic.space`**, matching
  Teams' pattern below. `relay.intersyntactic.space` was this repo's
  hostname until 2026-11-14 -- the generic pre-naming-discussion name,
  caught after it had already gone live (see "status" at the end of this
  doc) -- and is being retired, not repurposed.
- Teams relay (`teams_module`): `teams.intersyntactic.space`, live since
  2026-11-14.

Neither is named `<source>-relay`. Whatever a bus ends up being called, it
needs its own hostname, not `github.intersyntactic.space` or
`teams.intersyntactic.space` -- both are already a specific source's.

## The decision this doc assumes

Two shapes were on the table:

1. **One process, multiple routes.** A single deployed binary mounts
   `/webhook/github` and `/webhook/teams`, each its own handler with its own
   `SourceSpec`, both broadcasting onto one in-memory `_listeners` set.
   Free -- no new service, no new auth, no new failure mode -- but it means
   the GitHub and Teams relays can't be deployed, restarted, or scaled
   independently, and doesn't fit two separately-named subdomains.

2. **Separate processes, one shared bus.** Each source relay is an
   independent deployment, each with its own subdomain, each pushing what it
   already verified into a third thing that owns the listener fanout.

**Chosen: (2).** This is also, independently, what already exists in
production -- `github.intersyntactic.space` and `teams.intersyntactic.space`
are two separate deployments today, built without a shared bus between
them. The bus described below is the thing that's currently *missing* from
an architecture that otherwise already committed to shape (2).

## The airlock: where the bus has to sit

Nick, 2026-11-14: Teams arrivals must be witnessed by the airlock before
anything reads them. The Teams relay answers Teams `200` only after the
airlock has recorded the raw body. The airlock is becoming its own service
on the box (`airlock-a1`; see `is_airlock_api`).

This constrains the bus directly: **a bus that fans a raw event out to
listeners before the airlock has witnessed it breaks that rule.** The bus
cannot sit between a source relay and the airlock -- it has to sit at or
after the point where the airlock has already recorded the raw body,
fanning out what was witnessed, not what arrived. Whether that means the
airlock publishes to the bus (airlock as the only thing with a publisher
token) or the bus itself calls into the airlock to witness before
broadcasting is not decided here -- find out from whoever is building
`airlock-a1` and `is_airlock_api` before designing the publish side further;
this doc does not have enough knowledge of the airlock's own shape to settle
it.

## The bus

A new, not-yet-built package/deployment (working name `intersyntactic_bus`;
hostname not `github.intersyntactic.space` or `teams.intersyntactic.space`
-- see above, maybe `bus.intersyntactic.space`).

It owns:

- `/ws`: unchanged from today's `_listen`/`_listeners`/`_broadcast`, lifted
  out of `Relay` wholesale. A listener (IS, wherever it runs) dials in with
  `Authorization: Bearer <listener-token>`, exactly as it does today.
- `/publish`: new, and **also a websocket upgrade, not an HTTP POST.** A
  source relay dials in with `Authorization: Bearer <publisher-token>` and
  holds the connection open, writing a message onto it whenever its own
  gate (or, for Teams, the airlock -- see above) says to. This mirrors
  `/ws`'s own check-token-then-upgrade shape exactly (the same
  `constantTimeEquals` pattern, the same `WebSocketTransformer.upgrade`),
  and lets a source relay's side reuse whatever reconnect-with-backoff
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
  self-reported. A leaked GitHub-relay token must never be usable to forge
  a Teams event.

- Nothing else. The bus does not parse the payload. It wraps whatever bytes
  a source relay already produced (today's `RelayMessage.toJson()` for
  GitHub, unchanged) in a thin envelope -- `{"source": "github", "message":
  {...}}` -- and forwards that, unexamined, to every listener. It does not
  debounce: `relay.dart`'s existing stance ("COALESCING is not done here...
  the receiver's own topic debounce does the coalescing") holds just as
  well with a bus in front as it did without one.

Fire-and-forget on the publish side, same as today's `_broadcast`: no retry
queue, no ack. A dropped notification recovers itself the same way a dropped
listener write already does -- the next real event, or GitHub's/Teams' own
redelivery, catches it up. This matches `webhook_gate.dart`'s existing
tolerance for a replayed-but-idempotent trigger; nothing here raises the bar
on reliability past what the rest of the system already accepts. (This
tolerance is about redelivery, not about skipping the airlock's witness --
see above.)

## What changes in this repo, when the bus is built

`lib/src/relay.dart`'s `Relay` loses `_listen`, `_listeners`, `_broadcast`,
the `/ws` route, `close()`'s listener-closing loop, and the `listeners`
getter -- all of it moves to the bus package instead. Where `_broadcast`
is called today, `Relay` instead writes to its own held-open connection to
the bus's `/publish`. `handle()` keeps exactly one route,
`/webhook/github`; everything about verifying and parsing GitHub's webhook
is untouched.

Every current listener's wire format changes -- `{source, message}` instead
of a bare `RelayMessage` at the top level -- which is why this is a real
migration, not a config flag. `teams_module`'s relay presumably needs the
equivalent change, and whatever it does today instead of a shared bus
(its own `/ws`? something else?) needs checking before assuming this repo's
half of the migration is the only half.

## Status

**Deployment, 2026-11-14:** `relay.intersyntactic.space` (the old systemd
binary, untraceable to any commit) was replaced the same day this doc's
corrections were written, pinned to this repo's GHCR image by digest
(`enspyrco/infra#371`). It then moved again, same day, to its correctly
source-named hostname, `github.intersyntactic.space` -- caught only after
the first switch had already gone live, which is why both names briefly
served the same container during the transition. `relay.intersyntactic.space`
is retired once `enspyrco/intersyntactic`'s webhook (hook `700598542`)
points at `github.` and a real delivery has landed there.

**The bus itself: not built.** Two source relays exist in production right
now with no bus between them -- this is a real gap, not a hypothetical one,
and whether to close it now or later is Nick's call, not a decision this
doc makes for him. What's settled is the shape it takes when built:
separate deployments per source (already true), a bus that sits after
witnessing (per the airlock constraint above), websocket on the publish
side, and a thin non-parsing envelope. What's open: the bus's own hostname
and package name, the airlock integration's exact shape, and whether
`teams_relay.dart` needs touching regardless of when the bus itself gets
built.
