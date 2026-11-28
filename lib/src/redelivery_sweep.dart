/// GitHub never redelivers a failed webhook by itself, so this does: it
/// lists each hook's recent deliveries and asks GitHub to redeliver every
/// one whose attempts all failed and whose last answer asked for another
/// try.
///
/// A redelivery is the same signed bytes, so it has the same
/// [githubEventKey], and redelivering twice is harmless. That is why this
/// keeps no record of its own: what GitHub lists is the whole state.
///
/// It holds a GitHub token, so it runs in its own process; the relay never
/// does.
library;

import 'dart:async';
import 'dart:io';

import 'package:checked_json/checked_json.dart';
import 'package:is_relay/is_relay.dart' show RefusalStatus;

/// A webhook whose deliveries are swept: a repository's or an
/// organisation's.
sealed class GitHubHook {
  const GitHubHook();

  /// `owner/repo:id` for a repository's hook, `org:id` for an
  /// organisation's; null for anything else.
  static GitHubHook? parse(String s) {
    final m = _form.firstMatch(s.trim());
    if (m == null) return null;
    final id = int.tryParse(m[3]!);
    if (id == null || id < 1) return null;
    return switch (m[2]) {
      final repo? => RepositoryHook._(m[1]!, repo, id),
      null => OrganisationHook._(m[1]!, id),
    };
  }

  static final _form = RegExp(
    r'^([A-Za-z0-9][A-Za-z0-9_.-]*)(?:/([A-Za-z0-9_.-]+))?:([0-9]{1,19})$',
  );

  /// Where its deliveries are listed, under the REST API's root.
  String get deliveriesPath;
}

final class RepositoryHook extends GitHubHook {
  const RepositoryHook._(this.owner, this.repo, this.id);
  final String owner;
  final String repo;
  final int id;

  @override
  String get deliveriesPath => '/repos/$owner/$repo/hooks/$id/deliveries';

  @override
  String toString() => '$owner/$repo:$id';
}

final class OrganisationHook extends GitHubHook {
  const OrganisationHook._(this.org, this.id);
  final String org;
  final int id;

  @override
  String get deliveriesPath => '/orgs/$org/hooks/$id/deliveries';

  @override
  String toString() => '$org:$id';
}

/// What one attempt's answer says about trying again.
enum AttemptOutcome {
  /// A 2xx: the relay recorded it.
  delivered,

  /// A refusal the relay marks [RefusalStatus.worthAnotherTry], or a status
  /// no relay refuses with: no answer (GitHub's status 0), or one the proxy
  /// gave itself, such as a 502.
  worthAnotherTry,

  /// A refusal the relay means as final (a signature that doesn't hold, a
  /// wrong path). But the sweep sees only the number, so it can't tell the
  /// relay's 404 from a misrouted proxy's, and a 401 during a secret
  /// rotation is the relay's config being wrong, not the delivery. So these
  /// are tried again too, sparingly: see [attemptsToRedeliver].
  refused;

  static AttemptOutcome of(int status) => switch (status) {
    >= 200 && < 300 => delivered,
    _ =>
      RefusalStatus.ofCode(status)?.worthAnotherTry ?? true
          ? worthAnotherTry
          : refused,
  };
}

/// One attempt at a delivery, as GitHub lists it. Attempts at one delivery
/// share a [guid]; each has its own [id].
final class HookDeliveryAttempt {
  const HookDeliveryAttempt({
    required this.id,
    required this.guid,
    required this.deliveredAt,
    required this.status,
  });

  /// One entry of `GET …/hooks/{id}/deliveries`, decoded with `id` as its
  /// digits: GitHub's ids are past 2^53, which only a 64-bit int holds, and
  /// this runs only on the VM. `int.parse` refuses one past 2^63 - 1.
  factory HookDeliveryAttempt.fromJson(JsonObject json) => HookDeliveryAttempt(
    id: int.parse(json.string('id')),
    guid: json.string('guid'),
    deliveredAt: DateTime.parse(json.string('delivered_at')),
    status: json.integer('status_code'),
  );

  final int id;
  final String guid;
  final DateTime deliveredAt;

  /// The HTTP status the relay answered, or 0 when it gave none.
  final int status;

  AttemptOutcome get outcome => AttemptOutcome.of(status);
}

/// Lists a hook's delivery attempts, and asks GitHub to redeliver one.
abstract interface class ListsAndRedeliversHookDeliveries {
  /// The hook's attempts delivered at or after [since], newest first.
  Future<List<HookDeliveryAttempt>> attemptsSince(
    GitHubHook hook,
    DateTime since,
  );

  /// Asks GitHub to deliver attempt [attemptId]'s payload again.
  Future<void> redeliver(GitHubHook hook, int attemptId);
}

/// For each delivery among [attempts] that none delivered, its latest
/// attempt, when it is due again:
///
/// - after [AttemptOutcome.worthAnotherTry], on every pass;
/// - after [AttemptOutcome.refused], only while the delivery has had fewer
///   than [refusedAttempts] attempts, and only once its latest is at least
///   [refusedSpacing] old at [now]. A misrouted deploy or a secret rotation
///   then recovers within hours, and a delivery that really is bad stops
///   after a few tries rather than one every pass for 71 hours.
///
/// Redelivering is safe however often: it only resends what GitHub itself
/// sent, and the same bytes are the same event key.
///
/// Oldest delivery first, by its first attempt: that one is nearest the
/// end of the time GitHub will still redeliver it.
List<HookDeliveryAttempt> attemptsToRedeliver(
  Iterable<HookDeliveryAttempt> attempts, {
  required DateTime now,
  int refusedAttempts = 3,
  Duration refusedSpacing = const Duration(hours: 1),
}) {
  final byGuid = <String, List<HookDeliveryAttempt>>{};
  for (final a in attempts) {
    (byGuid[a.guid] ??= []).add(a);
  }
  bool due(List<HookDeliveryAttempt> tries, HookDeliveryAttempt last) =>
      switch (last.outcome) {
        AttemptOutcome.delivered => false,
        AttemptOutcome.worthAnotherTry => true,
        AttemptOutcome.refused =>
          tries.length < refusedAttempts &&
              now.difference(last.deliveredAt) >= refusedSpacing,
      };
  final dueNow = [
    for (final tries in byGuid.values)
      if (!tries.any((t) => t.outcome == AttemptOutcome.delivered))
        if (_latest(tries) case final last when due(tries, last))
          (first: _first(tries), last: last),
  ]..sort((a, b) => a.first.compareTo(b.first));
  return [for (final d in dueNow) d.last];
}

DateTime _first(List<HookDeliveryAttempt> tries) =>
    tries.map((t) => t.deliveredAt).reduce((a, b) => a.isBefore(b) ? a : b);

HookDeliveryAttempt _latest(List<HookDeliveryAttempt> tries) => tries.reduce(
  (a, b) => switch (a.deliveredAt.compareTo(b.deliveredAt)) {
    < 0 => b,
    > 0 => a,
    _ => a.id >= b.id ? a : b,
  },
);

/// One pass over [hooks]: list each one's recent attempts and redeliver the
/// failed deliveries.
final class RedeliverySweep {
  RedeliverySweep({
    required this.github,
    required this.hooks,
    this.window = const Duration(hours: 71),
    this.maxPerSweep = 30,
    this.refusedAttempts = 3,
    this.refusedSpacing = const Duration(hours: 1),
    this._now = DateTime.now,
    this.log = _stderr,
  });

  final ListsAndRedeliversHookDeliveries github;
  final List<GitHubHook> hooks;

  /// How far back attempts are read. GitHub redelivers only what it
  /// delivered in the last 3 days, so this stays inside that.
  final Duration window;

  /// The most redeliveries GitHub accepts in one pass, across every hook.
  /// After an outage the relay's write-rate bound would refuse a flood of
  /// them; the rest wait for the next pass. One GitHub refuses doesn't
  /// count, so a delivery it will no longer redeliver can't hold the
  /// others back.
  final int maxPerSweep;

  /// How many attempts in all a refused delivery gets, and how long after
  /// its latest attempt it is due again: see [attemptsToRedeliver].
  final int refusedAttempts;
  final Duration refusedSpacing;

  /// One line per hook and per redelivery: ids and statuses, never content.
  final void Function(String line) log;

  final DateTime Function() _now;

  static void _stderr(String line) => stderr.writeln(line);

  /// Runs one pass. A hook whose listing fails is skipped, and a
  /// redelivery GitHub refuses is logged: the next pass tries both again.
  Future<({int redelivered, int failed})> sweep() async {
    final now = _now().toUtc();
    final since = now.subtract(window);
    var redelivered = 0;
    var failed = 0;
    for (final hook in hooks) {
      final List<HookDeliveryAttempt> attempts;
      try {
        attempts = await github.attemptsSince(hook, since);
      } on Exception catch (e) {
        log('sweep $hook: listing failed: $e');
        continue;
      }
      final due = attemptsToRedeliver(
        attempts,
        now: now,
        refusedAttempts: refusedAttempts,
        refusedSpacing: refusedSpacing,
      );
      log(
        'sweep $hook: ${attempts.length} attempt(s), ${due.length} to redeliver',
      );
      for (final a in due) {
        if (redelivered >= maxPerSweep) {
          log('sweep: $maxPerSweep asked for this pass; the rest wait');
          return (redelivered: redelivered, failed: failed);
        }
        try {
          await github.redeliver(hook, a.id);
          redelivered++;
          log(
            'sweep $hook: redelivered ${a.guid} (attempt ${a.id}, was ${a.status})',
          );
        } on Exception catch (e) {
          failed++;
          log('sweep $hook: redelivering ${a.guid} failed: $e');
        }
      }
    }
    return (redelivered: redelivered, failed: failed);
  }
}
