# Changelog

## 0.3.0

- **Breaking:** moves onto [is_relay](https://pub.dev/packages/is_relay).
  The relay is now is_relay's `RelayServer` with `GitHubDeliveryCheck`: it
  records every delivery whose HMAC holds in the logbook as `github-event`,
  and answers 2xx only after the write.
- **Breaking:** the `/ws` fan-out is gone, with `Relay`, `RelayMessage`,
  `RelayEvent`, `RELAY_TOKEN` and `WAKE_EVENTS`. Readers get deliveries from
  the logbook. `webhook_gate.dart` is gone too: no wake filter, no debounce,
  and no unsigned header is read.
- `githubEventKey`: the sha256 of a delivery's bytes, the key the docking
  station decides it under.
- `RedeliverySweep` and `bin/github_redelivery_sweep.dart`: GitHub never
  redelivers a failed delivery by itself, so the sweep asks it to. Its own
  process, from the same image.
- The relay now needs `LOGBOOK_SOCKET`. The SDK floor is 3.13.

## 0.2.2

- No behavior change. Corrects `docs/bus-design.md` and its pointers in
  `README.md`/`lib/src/relay.dart`: a Teams relay is already live and
  separately deployed (`teams.intersyntactic.space`), not a future
  hypothetical, and hostnames must not contain `_` (Let's Encrypt refuses
  the cert). Per `intersyntactic-a8`.

## 0.2.1

- No behavior change. A comment in `lib/src/relay.dart` and docs
  (`docs/bus-design.md`, `README.md`) now point at the bus design for a
  second webhook source. The guard added in 0.2.0 correctly caught this as
  "lib/ changed, version didn't bump" and refused to publish 0.2.0 again
  under a different commit -- this version exists to satisfy that guard,
  not because anything here behaves differently.

## 0.2.0

- **Breaking:** `RelayMessage.event` is now a `RelayEvent` (a sealed class),
  not a bare `String`. Build one with `RelayEvent.parse(wire)`, or the
  `RelayEvent.pullRequest()` / `RelayEvent.issues()` factories for a known
  kind. `RelayMessage.kind` is unchanged.
- The GHCR publish workflow's overwrite guard now fails (instead of quietly
  skipping) when the version tag already exists but was built from a
  different commit than the one being pushed -- catching a version that
  wasn't bumped to match a real code change, not just an identical rerun.

## 0.1.0

- Extracted from `enspyrco/intersyntactic`'s `packages/intersyntactic_relay`
  and `webhook_gate.dart` into its own repo, so it can ship as a versioned
  GHCR image instead of a bare binary deployed from a laptop.
- The pushed message is now a typed `RelayMessage`, read and written through
  `checked_json`, instead of an ad hoc `jsonEncode`/`jsonDecode` map.
