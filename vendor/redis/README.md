# Vendored from oboard/moonbit-redis

Vendored copy of [oboard/moonbit-redis](https://github.com/oboard/moonbit-redis)
(MIT, see LICENSE) maintained inside moonless.

Local patch: `moon.pkg` opens `supported_targets` to `+native+wasm`
(upstream declares native-only). Verified against a real Redis on both
targets via moonrun — see `probe_wasm/`.

Upstream tests were not vendored (they require a Redis on localhost:6379).
