/// Runs the GitHub relay: checks each delivery's HMAC, records it in the
/// logbook, and only then answers GitHub.
///
/// Run behind a TLS proxy, which must time out header reads (dart:io doesn't)
/// and must log neither headers nor bodies: GitHub signs no time, so a body
/// captured before it reached the relay is accepted once whenever it is sent.
///
///   GITHUB_WEBHOOK_SECRET=...  the secret set on the GitHub webhook
///   LOGBOOK_SOCKET=/run/...    the logbook writer's socket; its sender table
///                              must let this user send `github-event`
///   PORT=8080                  optional
///   HOST=127.0.0.1             optional; loopback, for a proxy on this
///                              machine.
///
/// GitHub: payload URL `https://<host>/webhook/github`, content type
/// application/json, any events: every authentic delivery is recorded, and
/// the translator decides what each one means. GitHub doesn't redeliver a
/// failed delivery; `bin/github_redelivery_sweep.dart` does.
library;

import 'dart:io';

import 'package:is_github_relay/is_github_relay.dart';
import 'package:is_relay/is_relay.dart';

Future<void> main() async {
  final env = Platform.environment;
  void abort(String why) {
    stderr.writeln('abort: $why');
    exit(78);
  }

  final secret = GitHubWebhookSecret.parse(env['GITHUB_WEBHOOK_SECRET'] ?? '');
  if (secret == null) return abort('GITHUB_WEBHOOK_SECRET is not set');
  final logbook = LogbookSocket.parse(env['LOGBOOK_SOCKET'] ?? '');
  if (logbook == null) return abort('LOGBOOK_SOCKET is not an absolute path');
  final rawPort = env['PORT'] ?? '';
  final port = rawPort.isEmpty ? 8080 : int.tryParse(rawPort);
  if (port == null || port < 1 || port > 65535) {
    return abort('PORT "$rawPort" is not a port number');
  }
  final rawHost = env['HOST'] ?? '';
  final address = InternetAddress.tryParse(
    rawHost.isEmpty ? '127.0.0.1' : rawHost,
  );
  if (address == null) return abort('HOST "$rawHost" is not an IP address');

  final relay = RelayServer(
    check: GitHubDeliveryCheck(secret: secret),
    logbook: logbook,
    path: githubRelayPath,
    budget: githubRelayBudget,
    maxBodyBytes: githubMaxBodyBytes,
    // Bodies run to 25 MB, so fewer at once than the default. A delivery
    // refused for room fails, and the sweep redelivers it.
    maxInFlight: 8,
    // Every event of a busy repository, with room for a sweep's catch-up.
    rate: WriteRateBound(perMinute: 300, burst: 60),
  );
  final server = await HttpServer.bind(address, port);
  stdout.writeln('github relay on ${address.address}:${server.port}');
  if (!address.isLoopback) {
    // Plain HTTP: signed bodies cross the wire in clear unless a TLS proxy
    // is the only thing that can reach this port.
    stderr.writeln(
      'warning: serving plain HTTP on ${address.address}, not loopback',
    );
  }
  await relay.serve(server);
}
