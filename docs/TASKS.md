# moonless — Task Breakdown

A numbered task list for building moonless step by step in spare time,
derived from the [README](../README.mbt.md) and the design decisions in
[project-notes.md](project-notes.md).

Conventions:

- Tasks are grouped by milestone: Steps 0–6 make up **P0** (the minimum
  loop), 7–8 are **P1**, 9–10 are **P2**, 11 validates the whole, 12 is
  **P3** stretch.
- Work through tasks in order within a step; across steps, respect
  the *Depends on* references.
- Each task has a *Done when* line — the acceptance check. Tick the box
  only when it passes.
- Unless stated otherwise, every task ends with `moon info && moon fmt`
  and a green `moon test`.

## Step 0. Pre-flight spike (P0)

- [x] **T0.1 — async http server spike.** Half a day, before anything
  else (R7): a minimal service on `moonbitlang/async`'s http server with
  path routing, JSON body handling, and concurrent requests; note any
  API rough edges.
  *Done when:* the spike handles two concurrent JSON requests correctly;
  findings recorded in `project-notes.md`.

## Step 1. Project scaffolding (P0)

- [x] **T1.1 — Repository layout.** Create five executable packages
  `cmd/gateway`, `cmd/builder`, `cmd/runner`, `cmd/scheduler`,
  `cmd/moonless` (each a `println("hello from <name>")` main), and a
  shared library package `src/shared` for cross-service types. Remove the
  scaffold `cmd/main`.
  *Done when:* `moon build --target native` succeeds for all five
  entries and `moon test` is green.
- [x] **T1.2 — Compose + images.** Write `docker-compose.yml` (gateway,
  builder, runner, scheduler) and a single shared image `Dockerfile`
  bundling the version-pinned moon toolchain (per R1; wasm builds need
  no C toolchain — moonrun ships with the toolchain); builder and
  runner run the same image with different entry points. Declare one
  named volume `/var/lib/moonless` shared by builder, runner, and
  gateway.
  *Done when:* `docker compose up` brings up four service containers
  (hello-world behavior is fine at this point).
- [x] **T1.3 — Dependencies.** Add `moonbit-community/toml` to
  `moon.mod` (`moonbitlang/async` already added in T0.1; dependency
  rule: prefer moonbit-community packages when candidates exist); the
  cron library follows in T7.1.
  *Done when:* builds pass with the new imports; `pkg.generated.mbti`
  diffs look expected.
- [x] **T1.4 — Platform conventions doc.** Record in this file's sibling
  `project-notes.md`: port assignments (e.g. gateway 8080, builder 8081,
  runner 8082, scheduler 8083), the shared-volume layout
  (`/var/lib/moonless/{functions,builds,logs,registry}/`), and the
  `MOONLESS_*` environment variable list, the function output cap
  (default 10MB per stream, R4), and the timezone convention (container
  `TZ`, UTC by default, R8).
  *Done when:* compose files, code, and notes agree with each other.

## Step 2. Shared foundations — `src/shared` (P0)

- [x] **T2.1 — Event type.** Model the trigger context as a type with
  three variants (http / cron / s3) and the exact JSON shape from the
  README, with encode/decode.
  *Done when:* unit tests round-trip all three variants.
- [x] **T2.2 — Manifest parsing.** Decode and validate `moonless.toml`:
  `name` required, triggers all optional, `cron` a five-field expression,
  `s3.events` a subset of `{put, delete}`, and the optional `toolchain`
  field must not exceed the platform's pinned version (R1).
  *Done when:* unit tests cover valid and invalid samples.
- [ ] **T2.3 — HTTP server helper.** A thin router on top of
  `moonbitlang/async`: path matching, method dispatch, JSON body reading,
  response helpers.
  *Done when:* used by at least one service smoke test.
- [ ] **T2.4 — HTTP client helper.** GET/POST with JSON bodies and a
  configurable timeout.
  *Done when:* unit test against the local test server.
- [ ] **T2.5 — Logging helper.** Structured stderr logging: service name,
  timestamp, level, message.
  *Done when:* adopted by all five services.
- [ ] **T2.6 — Inter-service protocol types.** Structs + JSON codecs for
  `DeployRequest`, `BuildResult`, `RunRequest`, `RunResult`, and the
  registry record.
  *Done when:* round-trip unit tests pass.

## Step 3. Builder service (P0)

- [ ] **T3.1 — Build API.** `POST /build` accepting a tar.gz of a MoonBit
  project plus the function name; reject packages missing `moon.mod` or
  `moonless.toml`.
  *Done when:* hand-crafted tar.gz requests return success/failure
  correctly.
- [ ] **T3.2 — Unpack safely.** Extract into an isolated work dir
  `/var/lib/moonless/builds/<build-id>/` with path-traversal protection
  (zip-slip).
  *Done when:* a malicious archive with `../` entries is rejected.
- [ ] **T3.3 — Invoke the toolchain.** Run `moon build --target wasm` in
  the work dir via `@moonbitlang/async/process` (`run` +
  `collect_output`), capture output, locate the produced `.wasm` module.
  *Done when:* a fixture project builds and the module path is reported.
- [ ] **T3.4 — Artifact store.** Copy the module to
  `/var/lib/moonless/functions/<name>/<build-id>/func.wasm` and write
  build metadata next to it.
  *Done when:* artifacts survive a builder container restart (named
  volume).
- [ ] **T3.5 — Failure reporting.** Return the tail of build stderr in
  `BuildResult` so the CLI can show why a deploy failed.
  *Done when:* a broken fixture yields a readable error message.
- [ ] **T3.6 — Offline build verification.** Dependencies arrive
  vendored inside the uploaded package (R2); confirm the builder needs no
  network at all during a build.
  *Done when:* a deploy succeeds with the builder container's network
  access disabled.
- [ ] **T3.7 — Builder tests.** Integration tests: one good fixture
  project, one broken one.
  *Done when:* both paths covered by `moon test` or a script under
  `scripts/`.

## Step 4. Runner service (P0)

- [ ] **T4.1 — Run API.** `POST /run` with `{name, event, env?}` →
  executes the stored wasm module with `MOONLESS_EVENT` set, returns
  `{stdout, stderr, exitCode, duration}`.
  *Done when:* curl against a deployed fixture returns captured output.
- [ ] **T4.2 — Process execution.** Execute via a moonrun child process
  through `@moonbitlang/async/process`: spawn `moonrun <module.wasm>`
  with `extra_env` (`MOONLESS_EVENT` plus injected service URLs),
  capture stdout/stderr with `collect_output`.
  *Done when:* echo/sleep/exit-code cases all behave correctly.
- [ ] **T4.3 — Timeout.** Kill functions after a default 60s and report
  a timeout result.
  *Done when:* a `sleep` fixture is killed and reported.
- [ ] **T4.4 — Concurrency cap.** A simple semaphore limiting concurrent
  forks (default 8, configurable via env); excess requests queue.
  *Done when:* a burst test shows queued rather than failed executions.
- [ ] **T4.5 — Module resolution.** Resolve `<name>` to its newest
  `.wasm` under `/var/lib/moonless/functions/`.
  *Done when:* re-deploying a fixture makes the next run use the new
  module.
- [ ] **T4.6 — Log capture.** Append each run's event and stderr to
  `/var/lib/moonless/logs/<name>/<date>.log` for gateway-side queries.
  *Done when:* files appear in the expected layout.
- [ ] **T4.7 — Runner tests.** Cover: plain stdout, stderr noise,
  non-zero exit, large output, timeout.
  *Done when:* all cases pass.
- [ ] **T4.8 — Output cap.** Enforce the per-stream output limit (default
  10MB, env-tunable): truncate excess and flag `truncated` in the result
  (R4); the HTTP response path honors the same cap.
  *Done when:* an infinite-echo fixture is truncated without runner
  memory growth.

## Step 5. Gateway service (P0)

- [ ] **T5.1 — Management API.** `POST /api/deploy` (tar.gz; forwards to
  builder, then registers), `GET /api/functions`, `GET /api/functions/
  <name>`, `GET /api/functions/<name>/logs?tail=N`.
  *Done when:* curl drives a full deploy → list → logs cycle.
- [ ] **T5.2 — Registry.** The function registry as a local file under
  `/var/lib/moonless/registry/`, written atomically (temp file + rename);
  records carry the manifest and the current build id.
  *Done when:* concurrent deploys never leave a corrupted registry file.
- [ ] **T5.3 — HTTP trigger.** Route `/fn/<name>` (any method) → build
  the http event JSON → call runner → return stdout as the body with
  status 200 (buffered; streaming is out of scope for MVP).
  *Done when:* `curl $MOONLESS_SERVER/fn/hello` returns the function's
  stdout.
- [ ] **T5.4 — Internal event intake.** `POST /api/events` accepting any
  event source; match it against the registry's triggers and dispatch to
  the runner.
  *Done when:* a synthetic s3 event triggers the bound function.
- [ ] **T5.5 — Deploy orchestration.** Sequence upload → build →
  register, propagating build failures to the caller with the reason.
  *Done when:* a broken deploy returns an error, a good one is callable.
- [ ] **T5.6 — Gateway tests.** Integration test: deploy fixture, HTTP
  trigger, logs retrieval.
  *Done when:* scripted end-to-end passes against a compose stack.

## Step 6. moonless CLI (P0)

- [ ] **T6.1 — CLI skeleton.** Subcommand dispatch (`deploy`, `list`,
  `logs`), `MOONLESS_SERVER` env with `--server` override.
  *Done when:* `moonless` with no args prints usage.
- [ ] **T6.2 — `deploy`.** Validate the current directory is a MoonBit
  project with a `moonless.toml`; resolve dependencies locally if needed,
  then tar.gz the sources **plus** the vendored `.mooncakes/` cache
  (excluding `_build/`, dotfiles) so the builder never needs network
  (R2); upload; stream the build outcome.
  *Done when:* deploying the hello example from the repo works.
- [ ] **T6.3 — `list`.** Table of deployed functions with their
  triggers and last build status.
  *Done when:* output matches the registry state.
- [ ] **T6.4 — `logs`.** Fetch the tail (default 50 lines); `--follow`
  streaming is deferred (T12.4).
  *Done when:* after HTTP-triggering a function, its stderr shows up.
- [ ] **T6.5 — Error UX.** Friendly messages for: server unreachable,
  not a MoonBit project, missing `moonless.toml`, unknown function.
  *Done when:* each case prints an actionable hint, not a stack trace.
- [ ] **T6.6 — Smoke script.** A script under `scripts/` running the
  whole P0 flow: deploy → curl → logs.
  *Done when:* the script passes on a fresh compose stack.

## Step 7. Scheduler (P1)

- [ ] **T7.1 — Cron library.** Pick and integrate one of
  `lijunjie860/moonbit_cron`, `cxh04/cron_mbt`, `001-Elsa/mooncron` (or
  justify writing our own five-field parser). None of these are
  moonbit-community packages; if one emerges before this task, prefer it
  per the dependency rule in project-notes.
  *Done when:* next-fire-time computation is unit-tested.
- [ ] **T7.2 — Registry sync.** Poll the gateway every 30s for functions
  with cron triggers; keep an in-memory schedule table.
  *Done when:* deploying a cron function is picked up within a poll
  cycle.
- [ ] **T7.3 — Dispatch loop.** On each fire time, assemble the cron
  event and POST it to the gateway's `/api/events`.
  *Done when:* an `* * * * *` fixture fires within the minute.
- [ ] **T7.4 — Missed-fire policy.** Document and implement
  skip-if-late (no catch-up bursts after downtime).
  *Done when:* behavior verified by a short-period test.
- [ ] **T7.5 — Scheduler tests.** Cover parsing, next-fire, and the
  dispatch path with a fake clock where possible.
  *Done when:* suite is green.

## Step 8. Log collection deepening (P1)

- [ ] **T8.1 — Rotation.** Rotate log files by day (or size cap), keep
  the last N files.
  *Done when:* synthetic writes trigger rotation as configured.
- [ ] **T8.2 — Query enhancements.** Filter logs by trigger source and
  time window in the gateway API; surface filters in `moonless logs`.
  *Done when:* CLI flags `--source` and `--since` work.
- [ ] **T8.3 — Run records.** One record per invocation (function,
  source, duration, exit code) queryable via
  `GET /api/functions/<name>/runs`; `moonless runs <name>` shows them.
  *Done when:* the last N runs are listed with correct metadata.

## Step 9. SeaweedFS integration (P2)

- [ ] **T9.1 — Compose integration.** Add SeaweedFS to compose using the
  single-process `weed server` mode (master / volume / filer / S3
  gateway in one container, R6) with a persistent volume and static S3
  credentials.
  *Done when:* the S3 gateway answers from inside the compose network.
- [ ] **T9.2 — S3 smoke test.** Using `aws` CLI (or `mc`) with the
  endpoint and credentials: create a bucket, upload, download.
  *Done when:* commands succeed from the host through the published
  port; document exact commands.
- [ ] **T9.3 — Filer webhook.** Configure the filer's notification
  webhook to POST events to the gateway's `/api/events`.
  *Done when:* an upload produces an event arriving at the gateway
  (log line is enough).
- [ ] **T9.4 — Event adapter.** Parse the SeaweedFS filer event JSON;
  map it to our s3 event (`bucket`, `key`), handling SeaweedFS's
  `/buckets/<bucket>/...` path convention; ignore non-S3 paths.
  *Done when:* unit tests over recorded event fixtures.
- [ ] **T9.5 — Trigger matching.** Match s3 events against
  `moonless.toml` s3 triggers (bucket + events) and dispatch.
  *Done when:* an upload to a bound bucket triggers the function; other
  buckets do not.
- [ ] **T9.6 — E2E.** `mc cp` a file → the bound function logs an s3
  event with the right bucket/key.
  *Done when:* scripted and passing.
- [ ] **T9.7 — S3 endpoint injection.** Expose `MOONLESS_S3_ENDPOINT`
  (and credentials) to functions; verify against the README's
  data-services section.
  *Done when:* a function can list its trigger bucket via an S3 client.

## Step 10. Data-service injection (P2)

- [ ] **T10.1 — Compose knobs.** `REDIS_URL`, `MYSQL_URL`,
  `POSTGRES_URL` entries in compose (commented-out examples by default,
  pointing at user-provided instances).
  *Done when:* setting them propagates to the runner.
- [ ] **T10.2 — Runner injection.** Fork functions with
  `MOONLESS_REDIS_URL` / `MOONLESS_MYSQL_URL` / `MOONLESS_POSTGRES_URL`
  set from the configured values.
  *Done when:* a function reads one back and echoes it.
- [ ] **T10.3 — Example function.** A Redis-backed counter example
  using the vendored patched driver at `vendor/redis/`, deployed and
  triggered over HTTP.
  *Done when:* repeated curls increment the counter.
- [ ] **T10.4 — Docs check.** Walk the README data-services section
  against the running system.
  *Done when:* every documented env var and driver link is accurate.

## Step 11. End-to-end & demo (final validation)

- [ ] **T11.1 — Examples.** Ship `examples/hello`,
  `examples/nightly-cleanup` (cron), and `examples/on-upload` (s3)
  projects in the repo.
  *Done when:* each deploys cleanly via `moonless deploy`.
- [ ] **T11.2 — Quick-start walk.** Execute the README quick start
  verbatim on a fresh machine/VM.
  *Done when:* every command works as written; fix the README where it
  doesn't.
- [ ] **T11.3 — README sync.** Update the Roadmap checkboxes in both
  READMEs to reflect reality; keep the Chinese version in lockstep.
  *Done when:* both files agree with the shipped state.
- [ ] **T11.4 — Demo script.** A judge-friendly demo flow: start stack,
  deploy, trigger all three ways, show logs.
  *Done when:* dry-run takes under five minutes.

## Step 12. Stretch (P3)

- [ ] **T12.1 — Per-function limits.** Timeout and concurrency settings
  in `moonless.toml`, honored by the runner.
- [ ] **T12.2 — Versioning & rollback.** Keep a build history per
  function; `moonless rollback <name>` switches the active build.
- [ ] **T12.3 — HTTP response control.** A protocol for functions to
  set status code and headers (e.g. a leading JSON header line on
  stdout), replacing the fixed 200.
- [ ] **T12.4 — `logs --follow`.** Stream logs to the terminal.
- [ ] **T12.5 — Multi-node runners.** Runner registration with the
  gateway and function placement across nodes.
- [ ] **T12.6 — Multi-language functions.** Document that the contract
  is language-agnostic; accept non-MoonBit binaries with explicit
  opt-in.
- [ ] **T12.7 — CI.** GitHub Actions running `moon test` and
  `moon fmt --check` on push.
- [ ] **T12.8 — Sandbox policies.** Explore moonrun's experimental
  sandbox policy (network connect/bind, DNS, file-access rules) as the
  mechanism for per-function permissions.
