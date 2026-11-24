/// GitHub's check of a delivery, for an is_relay [RelayServer]: the
/// HMAC-SHA256 of the raw body under the webhook secret, compared in
/// constant time with `X-Hub-Signature-256`.
///
/// Every delivery whose HMAC holds is recorded. No unsigned header is read:
/// `X-GitHub-Event` and `X-GitHub-Delivery` sit outside the HMAC, so a
/// replayer could relabel a signed body with them. The translator
/// classifies a delivery from its signed bytes alone.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:is_docking_station_api/is_docking_station_api.dart'
    show EventKey, RelayedEventSource;
import 'package:is_relay/is_relay.dart';

/// The source GitHub deliveries are recorded as: kind `github-event`.
final githubEventSource = RelayedEventSource.parse('github')!;

/// The path the webhook's payload URL names.
final githubRelayPath = RelayPath.parse('/webhook/github')!;

/// A whole request's time. GitHub marks a delivery failed after 10 s
/// without an answer.
const githubRelayBudget = Duration(seconds: 8);

/// GitHub's own cap: it sends no payload larger than 25 MB, so nothing it
/// sends is refused for size.
const githubMaxBodyBytes = 25 * 1024 * 1024;

/// The key the docking station decides a GitHub delivery under: the sha256
/// of its bytes. A redelivery is the same signed bytes, so it has the same
/// key, and a delivery is decided once however often it is recorded.
EventKey githubEventKey(Uint8List bytes) =>
    EventKey.parse('sha256:${sha256.convert(bytes)}')!;

/// The webhook's secret. Never empty: an empty one would sign anything a
/// guesser chose.
final class GitHubWebhookSecret {
  const GitHubWebhookSecret._(this._value);

  /// [s] as a secret, or null when it is empty.
  static GitHubWebhookSecret? parse(String s) =>
      s.isEmpty ? null : GitHubWebhookSecret._(s);

  final String _value;

  /// The hex HMAC-SHA256 GitHub sends after `sha256=`, over the raw [body].
  /// The raw bytes: re-encoding a parsed body changes them.
  String sign(List<int> body) =>
      Hmac(sha256, utf8.encode(_value)).convert(body).toString();

  @override
  String toString() => 'GitHubWebhookSecret(…)';
}

/// The signature the headers offered, still to be compared against the
/// body. Only [GitHubDeliveryCheck.checkHeaders] makes one.
final class GitHubOfferedSignature {
  const GitHubOfferedSignature._(this._hex);

  /// 64 lower-case hex digits.
  final String _hex;
}

final class GitHubDeliveryCheck
    implements ChecksDeliveries<GitHubOfferedSignature> {
  GitHubDeliveryCheck({required this.secret});

  final GitHubWebhookSecret secret;

  @override
  RelayedEventSource get source => githubEventSource;

  @override
  HeaderCheck<GitHubOfferedSignature> checkHeaders(
    DeliveryHeaders headers,
    DateTime now,
  ) {
    final presented = headers['x-hub-signature-256'];
    if (presented == null || !presented.startsWith('sha256=')) {
      return const HeadersRefused(
        RefusalStatus.unauthorized,
        'no sha256= x-hub-signature-256',
      );
    }
    final hex = presented.substring(7);
    if (!_digest.hasMatch(hex)) {
      return const HeadersRefused(
        RefusalStatus.unauthorized,
        'x-hub-signature-256 is not a sha256 digest',
      );
    }
    return HeadersVouch(GitHubOfferedSignature._(hex.toLowerCase()));
  }

  @override
  BodyVerdict checkBody(GitHubOfferedSignature vouched, Uint8List body) =>
      constantTimeEquals(secret.sign(body), vouched._hex)
      ? const Record()
      : const Refuse(RefusalStatus.unauthorized, 'signature mismatch');

  static final _digest = RegExp(r'^[0-9a-fA-F]{64}$');
}

/// Constant-time comparison: a `==` on a hex digest leaks through timing how
/// many leading characters a guess got right. Lengths are compared first;
/// length is not the secret.
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}
