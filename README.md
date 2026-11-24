# is_github_relay

GitHub's part of an [is_relay](https://pub.dev/packages/is_relay) relay.
is_relay's `RelayServer` takes each webhook delivery, runs this package's
check against the raw bytes, records every authentic one in the logbook as
`github-event`, and answers 2xx only after that write. Readers get
deliveries from the logbook; nothing is pushed to anyone. See is_relay's
[DESIGN.md](https://github.com/intersyntactic/relay/blob/main/DESIGN.md)
for why.

This package supplies:

- **`GitHubDeliveryCheck`**: the HMAC-SHA256 of the raw body under the
  webhook secret, compared in constant time with `X-Hub-Signature-256`. It
  reads no other header. `X-GitHub-Event` and `X-GitHub-Delivery` are not
  covered by the signature, so a replayer could relabel a signed body with
  them; the translator classifies a delivery from its signed bytes alone,
  and gives `NothingToAdmit` for any shape it can't classify unambiguously.
- **`githubEventKey`**: the key the docking station decides a delivery
  under, `sha256:<hex of the bytes>`. A redelivery is the same bytes, so the
  relay keeps no record of what it has seen.
- **`RedeliverySweep`**: GitHub never redelivers a failed webhook by
  itself. The sweep lists each hook's last 71 hours of attempts and asks
  GitHub to redeliver each delivery that no attempt delivered: on every
  pass after an answer that asked for another try (no answer, 408, 429,
  5xx), and sparingly after any other 4xx (three attempts in all, an hour
  apart). The sweep sees only the status, so it can't tell the relay's 404
  from a misrouted proxy's, and a 401 during a secret rotation is the
  config at fault, not the delivery. Redelivering is safe however often:
  the same bytes are the same event key.

```dart
final relay = RelayServer(
  check: GitHubDeliveryCheck(secret: GitHubWebhookSecret.parse(secret)!),
  logbook: LogbookSocket.parse('/run/logbook/write.sock')!,
  path: githubRelayPath,
  budget: githubRelayBudget, // 8 s, inside GitHub's 10 s
  maxBodyBytes: githubMaxBodyBytes, // GitHub's own 25 MB cap
  rate: WriteRateBound(perMinute: 300, burst: 60),
);
await relay.serve(await HttpServer.bind(InternetAddress.loopbackIPv4, 8080));
```

## Running it

Two processes from one image (`Dockerfile`):

- `bin/github_relay.dart`, the relay. It needs `GITHUB_WEBHOOK_SECRET` and
  `LOGBOOK_SOCKET`, and the logbook's sender table must let its user write
  `github-event`. Put TLS in front, with a proxy that times out header reads
  and logs neither headers nor bodies: GitHub signs no time, so a body
  captured before it reached the relay is accepted once whenever it is sent.
- `bin/github_redelivery_sweep.dart`, the sweep, started with
  `--entrypoint /app/bin/github_redelivery_sweep`. It needs `GITHUB_TOKEN`
  and `GITHUB_HOOKS`. It holds a GitHub token, so it never shares the
  relay's process.

Each file's doc comment lists its environment variables. Missing or invalid
configuration aborts with exit 78 rather than serve an endpoint that waves
everyone in.

The webhook: payload URL `https://<host>/webhook/github`, content type
`application/json`, any events. Every authentic delivery is recorded, so
"send me everything" costs logbook entries, not correctness.
