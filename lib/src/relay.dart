/// The meeting point between GitHub and a machine nothing can reach.
///
/// GitHub POSTs `/webhook/github`; each intersyntactic server that has dialled
/// `/ws` (outbound from its side, so no inbound port on a laptop) is told that
/// something changed. Nothing here asks GitHub anything and nothing polls: the
/// only timer is the websocket ping that notices a dead connection.
///
/// WHAT IS SENT is "this repo had a pull_request event", and the receiver's
/// whole reaction is to re-read the PR list. That is the idempotent action
/// `webhook_gate.dart` says its replay tolerance depends on: a replayed
/// delivery can cause a refresh that would have been correct anyway, and
/// nothing in the message chooses what the receiver DOES. If a receiver ever
/// starts acting on the message's contents, replay protection (a digest-keyed
/// seen set) becomes required -- see that file.
///
/// COALESCING is not done here. The gate's own debounce DROPS later deliveries
/// inside its window, which would lose a change that lands just after a
/// refresh already ran; so it is set to zero and the receiver's topic debounce
/// (wait for the burst to settle, then read once) does the coalescing.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'relay_message.dart';
import 'webhook_gate.dart';

/// The GitHub events that are pushed on, unless the relay is told otherwise:
/// a pull request changing (the open-PR count) and an issue changing (the
/// tasks list, which is GitHub issues).
const defaultWakeEvents = {'pull_request', 'issues'};

class Relay {
  /// [secret] is the GitHub webhook secret; [token] is what a server must
  /// present to listen. Either empty is a configuration error, not "open".
  ///
  /// [wakeEvents] are the event kinds that are pushed; any other is answered
  /// 204 and dropped, so the webhook may be set to "send everything".
  Relay({
    required String secret,
    required this.token,
    this.wakeEvents = defaultWakeEvents,
    DateTime Function()? now,
    this.log = _stderr,
    this.authFailDelay = const Duration(seconds: 1),
    this.delay = Future<void>.delayed,
    this.bodyTimeout = const Duration(seconds: 10),
    this.maxDelayedRefusals = 32,
  })  : _spec = SourceSpec(
          name: 'github',
          secret: secret,
          wakeEvents: wakeEvents,
        ),
        _now = now ?? DateTime.now {
    if (secret.isEmpty) throw ArgumentError('the webhook secret is empty');
    if (token.isEmpty) throw ArgumentError('the listener token is empty');
  }

  final String token;
  final Set<String> wakeEvents;
  final void Function(String line) log;

  /// A wrong listener token is answered this long after it is sent. That caps
  /// guessing at about one try a second per connection without locking anyone
  /// out (behind a proxy every client shares one address, so a per-address
  /// lockout would let an attacker lock out the real server).
  final Duration authFailDelay;

  /// Waits out [authFailDelay]: a real timer, unless a test gives its own.
  final Future<void> Function(Duration) delay;

  /// How long a webhook body may take to arrive in full.
  final Duration bodyTimeout;

  /// At most this many wrong-token refusals wait out [authFailDelay] at once;
  /// further ones are refused immediately, so the delay cannot be used to pile
  /// up held connections.
  final int maxDelayedRefusals;
  int _delayedRefusals = 0;
  final SourceSpec _spec;
  final DateTime Function() _now;
  final Set<WebSocket> _listeners = {};

  static void _stderr(String line) => stderr.writeln(line);

  /// How many servers are listening.
  int get listeners => _listeners.length;

  void _forget(WebSocket s) {
    _listeners.remove(s);
  }

  Future<void> handle(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (req.method == 'POST' && path == '/webhook/github') {
        await _webhook(req);
      } else if (path == '/ws' && WebSocketTransformer.isUpgradeRequest(req)) {
        await _listen(req);
      } else {
        await _end(req, HttpStatus.notFound);
      }
    } catch (e) {
      log('relay: $e');
      try {
        await _end(req, HttpStatus.internalServerError);
      } catch (_) {}
    }
  }

  Future<void> _webhook(HttpRequest req) async {
    const cap = 1024 * 1024;
    // An event we do not push on is not worth reading: GitHub may be sending
    // everything, and a `push` payload can be megabytes. Nothing is decided on
    // this header -- both answers are 204 -- so skipping the signature check
    // for it gives a caller nothing. `ping` is the exception: it is small, and
    // the one that GitHub sends on setup, so a 204 for it should MEAN the
    // secret is right (a wrong one is a 401).
    final event = req.headers.value('x-github-event') ?? '';
    if (!wakeEvents.contains(event) && event != 'ping') {
      req.response.headers.set('connection', 'close');
      await _end(req, HttpStatus.noContent);
      return;
    }
    if (req.contentLength > cap) {
      await _end(req, HttpStatus.requestEntityTooLarge);
      return;
    }
    final body = <int>[];
    var tooLarge = false;
    try {
      // The whole body must arrive within [bodyTimeout]: bytes dribbled under
      // the cap would otherwise hold the connection open indefinitely.
      await () async {
        await for (final chunk in req) {
          if (body.length + chunk.length > cap) {
            // Answer before leaving the loop: cancelling the request stream
            // first would drop the connection instead.
            await _end(req, HttpStatus.requestEntityTooLarge);
            tooLarge = true;
            return;
          }
          body.addAll(chunk);
        }
      }()
          .timeout(bodyTimeout);
    } on TimeoutException {
      log('relay: webhook body too slow');
      await _end(req, HttpStatus.requestTimeout);
      return;
    }
    if (tooLarge) return;
    final headers = <String, String>{};
    req.headers.forEach((name, values) => headers[name] = values.first);
    final d = gate(
      sourceName: 'github',
      spec: _spec,
      headers: headers,
      body: body,
      now: _now(),
      debounce: Duration.zero,
    );
    log('relay: webhook ${d.outcome.name}: ${d.reason}');
    if (d.outcome == GateOutcome.reject) {
      // No reason in the response: it would be a hint to whoever is guessing.
      await _end(req, HttpStatus.unauthorized);
      return;
    }
    if (d.shouldTouch) {
      final message = _message(event, body);
      log('relay: pushing to $listeners listener(s): $message');
      _broadcast(message);
    }
    await _end(req, HttpStatus.noContent);
  }

  /// `{"event":"issues","repo":"owner/name"}`; [RelayMessage.repo] is null
  /// when the (signed) body does not say.
  static String _message(String event, List<int> body) {
    String? repo;
    try {
      final j = jsonDecode(utf8.decode(body));
      repo = ((j as Map)['repository'] as Map?)?['full_name'] as String?;
    } catch (_) {}
    return jsonEncode(
        RelayMessage(event: RelayEvent.parse(event), repo: repo).toJson());
  }

  // The seam docs/bus-design.md describes: this whole method, plus
  // _listen/_listeners/close()'s listener loop, is what moves out to a
  // standalone bus -- a real gap today, not a hypothetical one, since
  // teams_module's relay is already a second, separate deployment with no
  // bus shared between it and this one. Nothing here is GitHub-specific;
  // it's just GitHub-only because this relay has never been wired to
  // anything else.
  void _broadcast(String message) {
    for (final s in _listeners.toList()) {
      try {
        s.add(message);
      } catch (_) {
        _forget(s);
      }
    }
  }

  Future<void> _listen(HttpRequest req) async {
    final presented = req.headers.value('authorization') ?? '';
    if (!constantTimeEquals(presented, 'Bearer $token')) {
      log('relay: listener refused');
      if (_delayedRefusals < maxDelayedRefusals) {
        _delayedRefusals++;
        try {
          await delay(authFailDelay);
        } finally {
          _delayedRefusals--;
        }
      }
      await _end(req, HttpStatus.unauthorized);
      return;
    }
    final socket = await WebSocketTransformer.upgrade(req);
    // Notices a connection that died without saying so; it is not a request
    // for data.
    socket.pingInterval = const Duration(seconds: 30);
    _listeners.add(socket);
    log('relay: listener connected ($listeners)');
    socket.listen(
      (_) {},
      onDone: () {
        _forget(socket);
        log('relay: listener left ($listeners)');
      },
      onError: (Object _) => _forget(socket),
      cancelOnError: true,
    );
  }

  static Future<void> _end(HttpRequest req, int status) async {
    req.response.statusCode = status;
    await req.response.close();
  }

  Future<void> close() async {
    for (final s in _listeners.toList()) {
      await s.close();
      _forget(s);
    }
  }
}
