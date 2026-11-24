/// Runs the redelivery sweep: every few minutes, asks GitHub to redeliver
/// each delivery to the relay that failed. GitHub never does by itself.
///
/// Its own process, never the relay's: it holds a GitHub token.
///
///   GITHUB_TOKEN=...      may read and redeliver the hooks' deliveries
///                         (`admin:repo_hook`, or fine-grained "Webhooks:
///                         read and write")
///   GITHUB_HOOKS=enspyrco/intersyntactic:700598542,some-org:123
///                         the hooks swept: `owner/repo:id` for a
///                         repository's, `org:id` for an organisation's
///   SWEEP_EVERY_MINUTES=5 optional; the wait between passes
library;

import 'dart:io';

import 'package:is_github_relay/is_github_relay.dart';

Future<void> main() async {
  final env = Platform.environment;
  void abort(String why) {
    stderr.writeln('abort: $why');
    exit(78);
  }

  final token = GitHubToken.parse(env['GITHUB_TOKEN'] ?? '');
  if (token == null) return abort('GITHUB_TOKEN is not set');
  final hooks = <GitHubHook>[];
  for (final raw in (env['GITHUB_HOOKS'] ?? '').split(',')) {
    if (raw.trim().isEmpty) continue;
    final hook = GitHubHook.parse(raw);
    if (hook == null) return abort('GITHUB_HOOKS: "$raw" is not a hook');
    hooks.add(hook);
  }
  if (hooks.isEmpty) return abort('GITHUB_HOOKS names no hook');
  final rawEvery = env['SWEEP_EVERY_MINUTES'] ?? '';
  final minutes = rawEvery.isEmpty ? 5 : int.tryParse(rawEvery);
  if (minutes == null || minutes < 1 || minutes > 24 * 60) {
    return abort('SWEEP_EVERY_MINUTES "$rawEvery" is not a number of minutes');
  }

  final sweep = RedeliverySweep(
    github: GitHubRestHookDeliveries(token: token),
    hooks: hooks,
  );
  stdout.writeln('redelivery sweep of ${hooks.join(', ')} every ${minutes}m');
  // One pass at a time: the next starts only after the last has ended.
  while (true) {
    final (:redelivered, :failed) = await sweep.sweep();
    stdout.writeln('sweep: $redelivered redelivered, $failed failed');
    await Future<void>.delayed(Duration(minutes: minutes));
  }
}
