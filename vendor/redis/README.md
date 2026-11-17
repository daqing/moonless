# Vendored from oboard/moonbit-redis

Vendored copy of [oboard/moonbit-redis](https://github.com/oboard/moonbit-redis)
(MIT, see LICENSE) maintained inside moonless.

Local patches:

- `moon.pkg` opens `supported_targets` to `+native+wasm` (upstream declares
  native-only). Verified against a real Redis on both targets via moonrun —
  see `probe_wasm/`.
- `connect_with_url` connects from a
  `redis://[[username]:[password]@]host[:port][/db]` URL (upstream only
  exposes the host/port `connect`).

Upstream tests were not vendored (they require a Redis on localhost:6379).
