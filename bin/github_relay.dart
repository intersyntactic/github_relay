/// Run behind TLS (a reverse proxy): GitHub needs https, and the listener
/// token travels in a header.
///
///   GITHUB_WEBHOOK_SECRET=...  the secret set on the GitHub webhook
///   RELAY_TOKEN=...            what each intersyntactic server presents
///   WAKE_EVENTS=pull_request,issues
///                              optional; the GitHub event kinds pushed to
///                              the servers (default as shown). Any other
///                              event is answered 204 and dropped, so the
///                              webhook may be set to "send everything".
///   PORT=8080                  optional; a value that is not a port aborts
///   HOST=127.0.0.1             optional; the address to bind. The default is
///                              loopback, for a proxy on the same machine.
///                              0.0.0.0 serves plain HTTP on every interface,
///                              which is how the container image binds.
///
/// GitHub: payload URL `https://<host>/webhook/github`, content type
/// application/json, event "Pull requests".
library;

import 'dart:async';
import 'dart:io';

import 'package:is_github_relay/github_relay.dart';

Future<void> main() async {
  final env = Platform.environment;
  final Relay relay;
  try {
    final wake = {
      for (final e in (env['WAKE_EVENTS'] ?? '').split(','))
        if (e.trim().isNotEmpty) e.trim(),
    };
    relay = Relay(
      secret: env['GITHUB_WEBHOOK_SECRET'] ?? '',
      token: env['RELAY_TOKEN'] ?? '',
      wakeEvents: wake.isEmpty ? defaultWakeEvents : wake,
    );
  } on ArgumentError catch (e) {
    // Refuse to start, rather than serve an endpoint that waves everyone in.
    stderr.writeln('abort: ${e.message}');
    exit(78);
  }
  final rawPort = env['PORT'];
  final port =
      rawPort == null || rawPort.isEmpty ? 8080 : int.tryParse(rawPort);
  if (port == null || port < 1 || port > 65535) {
    stderr.writeln('abort: PORT "$rawPort" is not a port number');
    exit(78);
  }
  final rawHost = env['HOST'];
  final host = rawHost == null || rawHost.isEmpty ? '127.0.0.1' : rawHost;
  final address = InternetAddress.tryParse(host);
  if (address == null) {
    stderr.writeln('abort: HOST "$host" is not an IP address');
    exit(78);
  }
  final server = await HttpServer.bind(address, port);
  stdout.writeln('relay listening on ${address.address}:${server.port}');
  if (!address.isLoopback) {
    stderr.writeln(
      'warning: bound to ${address.address}, which serves plain HTTP; '
      'put TLS in front or the listener token travels in clear',
    );
  }
  await for (final req in server) {
    unawaited(relay.handle(req));
  }
}
