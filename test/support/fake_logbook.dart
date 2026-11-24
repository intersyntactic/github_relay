/// Copied from is_relay's test/relay_server_test.dart: a logbook write
/// service on a Unix socket, speaking its real wire protocol.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_logbook_client/is_logbook_client.dart';
import 'package:is_relay/is_relay.dart';

/// How the fake logbook answers a write.
enum FakeAnswer { ok, duplicate, refusedKind, failed, notTip, silent }

/// A logbook write service on a Unix socket, speaking its wire protocol:
/// the request `<kind>\n<previous>\n<body>` to the end of the stream, then
/// one line back naming the request's hash.
final class FakeLogbook {
  FakeLogbook._(this._server, this.socket, this._dir);

  static Future<FakeLogbook> start() async {
    final dir = await Directory.systemTemp.createTemp('relay');
    final path = '${dir.path}/w.sock';
    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    final logbook = FakeLogbook._(server, LogbookSocket.parse(path)!, dir);
    server.listen(logbook._serve);
    return logbook;
  }

  final ServerSocket _server;
  final Directory _dir;
  final LogbookSocket socket;
  final _open = <Socket>[];

  FakeAnswer answer = FakeAnswer.ok;

  /// Each request, in full, as it arrived.
  final requests = <Uint8List>[];

  /// Completes when the first request has arrived.
  final called = Completer<void>();

  /// While set, no answer is sent until it completes.
  Completer<void>? hold;

  Future<void> _serve(Socket s) async {
    _open.add(s);
    final b = BytesBuilder();
    try {
      await s.forEach(b.add);
    } on SocketException {
      return;
    }
    final request = b.takeBytes();
    requests.add(request);
    if (!called.isCompleted) called.complete();
    await hold?.future;
    final id = ObjectId.of(request).hex;
    final line = switch (answer) {
      FakeAnswer.ok => 'ok $id',
      FakeAnswer.duplicate => 'refused duplicate $id',
      FakeAnswer.refusedKind => 'refused kind not allowed',
      FakeAnswer.failed => 'failed disk',
      FakeAnswer.notTip => 'refused not-tip ${ObjectId.of(Uint8List(2)).hex}',
      FakeAnswer.silent => null,
    };
    if (line == null) return;
    try {
      s.write('$line\n');
      await s.close();
    } on SocketException {
      // The relay gave up and destroyed its end.
    }
  }

  /// The entry's kind and body, read back from [request].
  static (Kind, Uint8List) parse(Uint8List request) {
    final first = request.indexOf(0x0a);
    final second = request.indexOf(0x0a, first + 1);
    return (
      Kind.parse(utf8.decode(request.sublist(0, first)))!,
      Uint8List.sublistView(request, second + 1),
    );
  }

  bool _stopped = false;

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    for (final s in _open) {
      s.destroy();
    }
    await _server.close();
    await _dir.delete(recursive: true);
  }
}
