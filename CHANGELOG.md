# Changelog

## 0.1.0

- Extracted from `enspyrco/intersyntactic`'s `packages/intersyntactic_relay`
  and `webhook_gate.dart` into its own repo, so it can ship as a versioned
  GHCR image instead of a bare binary deployed from a laptop.
- The pushed message is now a typed `RelayMessage`, read and written through
  `checked_json`, instead of an ad hoc `jsonEncode`/`jsonDecode` map.
