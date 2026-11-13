/// Decides whether an inbound GitHub webhook delivery is authentic and worth
/// acting on.
///
/// CURRENTLY UNWIRED. It is kept for the webhook that will make a closed
/// issue leave the app's task list -- the cases it handles (a forged
/// signature, an event we do not care about, a burst) are exactly that
/// webhook's cases.
///
/// This file decides; it never acts. Pure, so those cases are testable without
/// a socket, a server, or GitHub.
///
/// WHAT THIS GATE DOES NOT DO: REPLAY. A captured, authentic delivery replayed
/// later is ACCEPTED, and that is deliberate rather than missing.
///
/// The obvious fix is a TTL-bounded set of seen `X-GitHub-Delivery` ids. It was
/// considered and REFUSED, for a reason worth keeping:
///
///   1. **That header is not signed.** GitHub's HMAC covers the RAW BODY and
///      nothing else. A replayer editing one unsigned header defeats a
///      delivery-id set entirely, so the mechanism would look like replay
///      protection while providing none -- and a guard that reads as covering
///      something it does not is worse than an absent guard, because the next
///      reader stops looking. (`concept_nonce_originates_with_verifier` is the
///      general form: an anti-replay token must come from the VERIFIER, and
///      `X-GitHub-Delivery` comes from the sender.)
///
///   2. A set keyed on the SIGNATURE DIGEST would be sound -- the digest is
///      bound to the secret, so a replayer can only ever resend a body they
///      already have, reproducing a digest we have already seen. It was still
///      refused, because of what it would buy:
///
/// WHAT A REPLAY ACTUALLY GAINS, which is why the residual risk is accepted --
/// PROVIDED the action behind a `trigger` stays idempotent. The intended action
/// is "re-read the task list from GitHub and push it": NOTHING in the request
/// body or headers would reach it, so a replayer's entire capability is "cause
/// a refresh that would have been correct anyway", already rate-limited by
/// [debounce]. Digest-keyed dedupe would defend that for the cost of breaking
/// GitHub's own "Redeliver" button, which is a real operator action.
///
/// THE CONDITION THAT FLIPS THIS. If the trigger ever stops being idempotent --
/// if a delivery's body, event kind or count starts influencing what the
/// receiver DOES rather than merely that it runs -- digest-keyed dedupe becomes
/// required, and this paragraph is the note that says so. Note also that
/// because headers are unsigned, the EVENT KIND is attacker-selectable on a
/// replay: a signed `ping` body can be relabelled `issues`. That is no
/// escalation while both paths end at the same idempotent refresh, and it is
/// exactly what stops being true the moment the event kind means anything.
///
/// SOURCE-KEYED, NOT GITHUB-SHAPED. A [SourceSpec] per source, so another
/// pusher can be added without a second gate. GitHub's signature scheme is one
/// [SourceSpec], not the contract.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// What the caller should do. Closed set: a new outcome must be added here and
/// handled at every switch, rather than smuggled in as a null or a bare bool.
enum GateOutcome {
  /// Touch the trigger file. The sync wakes.
  trigger,

  /// Understood, authentic, but nothing to wake for (a ping, or an event kind
  /// that cannot change the projection). Answer 204 and do nothing.
  ignore,

  /// Authentic, and we already touched so recently that touching again would
  /// only spin the sync. Answer 204 -- the work is already queued.
  debounced,

  /// Refused. Never say why in the response body; the log may.
  reject,
}

class GateDecision {
  final GateOutcome outcome;

  /// Operator-facing, logged, never returned to the caller. A rejection reason
  /// in a response body is a hint to whoever is guessing at the signature.
  final String reason;

  const GateDecision(this.outcome, this.reason);

  bool get shouldTouch => outcome == GateOutcome.trigger;
}

/// One inbound source: how to authenticate it, and which of its events matter.
class SourceSpec {
  final String name;

  /// Shared secret. An empty secret is a configuration error, not an
  /// "unauthenticated mode" -- see [gate], which refuses rather than allows.
  final String secret;

  /// Header carrying the hex HMAC-SHA256, e.g. `x-hub-signature-256`. Compared
  /// case-insensitively by [gate]; store it lowercase.
  ///
  /// NOT A FOSSIL — do not sweep it. `x-hub-signature-256` is GitHub's own
  /// header name, fixed on their side; the `hub` in it is GitHub's word, not
  /// ours, and editing it silently breaks every delivery. It is flagged here
  /// because it matches the retired-name grep exactly, and the guard belongs
  /// beside the fact rather than in a rule the sweeper will not be reading.
  final String signatureHeader;

  /// Prefix GitHub puts before the hex digest (`sha256=`). Empty for a source
  /// that sends the bare digest.
  final String signaturePrefix;

  /// Header naming the event kind, e.g. `x-github-event`.
  final String eventHeader;

  /// Event kinds that can change the projection. Everything else is [ignore]d
  /// -- an allowlist, so a new GitHub event type cannot start waking the sync
  /// merely because nobody thought about it.
  final Set<String> wakeEvents;

  /// Event kinds that are authentic and deliberately uninteresting. Named
  /// separately from the unknown case only so the log can tell them apart.
  final Set<String> knownQuietEvents;

  const SourceSpec({
    required this.name,
    required this.secret,
    this.signatureHeader = 'x-hub-signature-256',
    this.signaturePrefix = 'sha256=',
    this.eventHeader = 'x-github-event',
    this.wakeEvents = const {'issues'},
    this.knownQuietEvents = const {'ping'},
  });
}

/// Constant-time comparison. A `==` on a hex digest leaks, through timing, how
/// many leading characters a guess got right, which turns forging a signature
/// into a per-character search instead of a 2^256 one. Length is compared
/// first and separately because differing lengths cannot be compared in
/// constant time anyway, and length is not the secret.
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// The hex HMAC-SHA256 of [body] under [secret], without any prefix.
///
/// [body] is the RAW request bytes. Re-encoding a parsed JSON body would change
/// the bytes (key order, whitespace, unicode escapes) and every signature would
/// fail for a reason that looks like a wrong secret.
String signBody(String secret, List<int> body) =>
    Hmac(sha256, utf8.encode(secret)).convert(body).toString();

/// The whole decision, as a pure function of the request and the clock.
///
/// [lastTouch] is when the trigger file was last written by THIS service --
/// null if never. [debounce] coalesces a burst: GitHub sends one delivery per
/// issue action, and the sync itself closes issues, so a journey path can produce a
/// small flock of deliveries whose work is already covered by the run that is
/// queued. Coalescing them is not dropping them: the sync reads the whole
/// world every time, so one wake covers any number of changes that preceded it.
GateDecision gate({
  required String sourceName,
  required SourceSpec? spec,
  required Map<String, String> headers,
  required List<int> body,
  required DateTime now,
  DateTime? lastTouch,
  Duration debounce = const Duration(seconds: 5),
  int maxBodyBytes = 1024 * 1024,
}) {
  if (spec == null) {
    return GateDecision(GateOutcome.reject, 'unknown source "$sourceName"');
  }

  // FAIL CLOSED ON A MISSING SECRET. The tempting alternative -- "no secret
  // configured means skip verification" -- turns a deploy that forgot to set
  // an environment variable into a public endpoint that wakes the sync for
  // anyone. A misconfigured guard must refuse, not wave through.
  if (spec.secret.isEmpty) {
    return GateDecision(
      GateOutcome.reject,
      'source "$sourceName" has no secret configured',
    );
  }

  if (body.length > maxBodyBytes) {
    return GateDecision(GateOutcome.reject, 'body ${body.length}b over cap');
  }

  final lower = {for (final e in headers.entries) e.key.toLowerCase(): e.value};

  final presented = lower[spec.signatureHeader];
  if (presented == null || presented.isEmpty) {
    return GateDecision(GateOutcome.reject, 'missing ${spec.signatureHeader}');
  }
  if (!presented.startsWith(spec.signaturePrefix)) {
    return GateDecision(GateOutcome.reject, 'signature prefix not recognised');
  }

  final expected = signBody(spec.secret, body);
  final offered = presented.substring(spec.signaturePrefix.length);
  if (!constantTimeEquals(expected, offered.toLowerCase())) {
    return GateDecision(GateOutcome.reject, 'signature mismatch');
  }

  // Authentic from here down. Everything below is about whether the authentic
  // message is worth waking for.
  final event = lower[spec.eventHeader] ?? '';
  if (!spec.wakeEvents.contains(event)) {
    final known = spec.knownQuietEvents.contains(event);
    return GateDecision(
      GateOutcome.ignore,
      known ? 'quiet event "$event"' : 'unhandled event "$event"',
    );
  }

  if (lastTouch != null) {
    final since = now.difference(lastTouch);
    // A negative difference means the clock moved backwards (NTP step). Treat
    // it as "recently touched" rather than as a debounce window stretching
    // into the past, which would wake on every delivery until the clock caught
    // up. The same shape as heartbeatIsStale's negative-age guard -- and note
    // THAT one resolves a negative age the opposite way, because there a
    // missed write is the danger and here a spin is.
    if (since.isNegative || since < debounce) {
      return GateDecision(
        GateOutcome.debounced,
        'within ${debounce.inSeconds}s of last touch',
      );
    }
  }

  return GateDecision(GateOutcome.trigger, 'event "$event"');
}
