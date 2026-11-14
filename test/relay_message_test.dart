import 'package:checked_json/checked_json.dart';
import 'package:is_github_relay/src/relay_message.dart';
import 'package:test/test.dart';

void main() {
  group('RelayMessage', () {
    test('round-trips a pull_request event with a repo', () {
      final message = RelayMessage(
          event: const RelayEvent.pullRequest(), repo: 'owner/name');

      final json = message.toJson();
      final decoded = RelayMessage.fromJson(json);

      expect(decoded.event.wire, 'pull_request');
      expect(decoded.repo, 'owner/name');
      expect(decoded.kind, RelayEventKind.pullRequest);
    });

    test('round-trips an issues event with no repo', () {
      final message = RelayMessage(event: const RelayEvent.issues());

      final decoded = RelayMessage.fromJson(message.toJson());

      expect(decoded.event.wire, 'issues');
      expect(decoded.repo, isNull);
      expect(decoded.kind, RelayEventKind.issues);
    });

    test(
        'kind is null for an event WAKE_EVENTS names but this build has not seen',
        () {
      final decoded = RelayMessage.fromJson(
          JsonObject.of({'event': 'release', 'repo': null}));

      expect(decoded.event.wire, 'release');
      expect(decoded.kind, isNull);
    });

    test('toJson round-trips through the wire shape unchanged', () {
      final message = RelayMessage(
          event: const RelayEvent.pullRequest(), repo: 'intersyntactic/relay');

      final roundTripped = RelayMessage.fromJson(message.toJson()).toJson();

      expect(roundTripped.asUncheckedMap(), message.toJson().asUncheckedMap());
    });

    test('RelayEvent.parse never returns null, even for an unseen kind', () {
      final event = RelayEvent.parse('release');

      expect(event.wire, 'release');
      expect(event.kind, isNull);
    });
  });
}
