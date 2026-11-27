# Multi-node runners

[中文版](multi_node_guide.zh-CN.md)

By default the stack runs one runner: the `runner` service in
`docker-compose.yml`. Multi-node runners add more execution nodes without a
shared volume. Nodes announce themselves to the gateway, the gateway hands each
run to one node in round-robin order, and it ships the wasm build to nodes that
do not already have it on disk.

```text
runner node ──POST /api/runners/register──► gateway       (every 30s)
gateway ──POST /modules (wasm + policy)──► node           (remote nodes, every run)
gateway ──POST /run (event, build_id, limits)──► node ──► moonrun
```

Every trigger type converges on the same place: HTTP (`/fn/:name`), cron, and
S3 events all call `dispatch_run` in `cmd/gateway/events.mbt`. Placement is
therefore decided only by the gateway, and the CLI and scheduler need no
knowledge of runner nodes.

## Quick start: add a second node

The stack's own runner (node 0) needs no configuration. To add a node:

1. Bring the stack up and note the Compose network name. It is
   `<project>_default`; for this repo (directory `moonless`) that is
   `moonless_default`:

   ```bash
   docker compose up -d
   docker network ls --format '{{.Name}}' | grep moonless
   ```

2. Start the node on that same network. Do **not** use `127.0.0.1` for the
   public URL — the gateway calls the node from inside its own container, where
   `127.0.0.1` is the gateway itself. Use the node's container name:

   ```bash
   docker run -d --name node-2 --network moonless_default \
     -e MOONLESS_GATEWAY_URL=http://gateway:8080 \
     -e MOONLESS_RUNNER_PUBLIC_URL=http://node-2:8082 \
     moonless /app/bin/runner
   ```

   A remote node does not need the `moonless-data` volume: the gateway uploads
   the build to it before every run. Its `MOONLESS_DATA` defaults to
   `/var/lib/moonless` inside that container, so attach a volume if you want its
   per-node logs and uploaded builds to survive a restart. The `moonless` image
   is the one `docker compose build` produced.

3. Verify the gateway can reach it, and that it registered:

   ```bash
   docker compose exec gateway wget -qO- http://node-2:8082/healthz   # -> ok
   docker compose logs gateway | grep 'registered runner'
   ```

4. Trigger a function and watch which node runs it:

   ```bash
   curl http://127.0.0.1:8080/fn/bot
   docker logs -f node-2
   ```

   Placement is round-robin, so consecutive calls alternate between nodes; each
   runner logs `node=<url> start|execute|finish …` for the runs it handled.

## Registration

A runner joins the pool only when both environment variables are set
(`cmd/runner/main.mbt`):

| Variable                   | Purpose                                                    |
| -------------------------- | ---------------------------------------------------------- |
| `MOONLESS_GATEWAY_URL`     | Where to register, for example `http://gateway:8080`       |
| `MOONLESS_RUNNER_PUBLIC_URL` | The URL the gateway should call this node on             |

The node then posts `{"id": <public_url>, "url": <public_url>}` to
`/api/runners/register` in a loop (`cmd/runner/register.mbt`): 5 s per-request
timeout, then a 30 s sleep between attempts. A failed attempt logs a warning
and is retried on the next tick.

The node id is the public URL, so restarting a node re-announces the same id
instead of creating a duplicate. The registration handler
(`cmd/gateway/runners.mbt`) strips one trailing slash, updates the URL in place
when the id is already known, and appends a new node otherwise. The registry is
an in-memory `RunnerRegistry` guarded by a mutex; the reply is
`{"ok": true, "runners": <count>}`.

## Reachability

Registration and execution flow in **opposite directions**, which is the usual
source of "runner registers, but the gateway cannot reach it":

```text
runner ──POST /api/runners/register──► gateway   (runner → gateway)
gateway ──POST /modules, /run───────► runner     (gateway → runner)
```

A runner only needs to reach the gateway to register; the gateway's port is
usually published, so that leg works. But the gateway then calls the runner on
the advertised `MOONLESS_RUNNER_PUBLIC_URL`, and that name must resolve **from
inside the gateway container**. If it does not, dispatches routed to that node
fail with `moonless: failed to upload module to runner: POST <url>/modules
failed: …`.

`127.0.0.1` / `localhost` are never right here: inside the gateway container
they point at the gateway itself, not at the host or another container. Pick one
of these instead:

- **Same Docker network (recommended for a second container).** Attach the
  runner to the Compose network and advertise its service/container name:

  ```bash
  docker run -d --name node-2 --network moonless_default \
    -e MOONLESS_GATEWAY_URL=http://gateway:8080 \
    -e MOONLESS_RUNNER_PUBLIC_URL=http://node-2:8082 \
    moonless /app/bin/runner
  ```

  `node-2` resolves from `gateway` because both share `moonless_default` (the
  project's default network; adjust if your Compose project name differs).

- **Runner outside Docker (on the host).** The runner listens on
  `0.0.0.0:8082`; publish/reach it from containers via the host gateway name.
  Unlike the containerized runner, a host runner **must** set `MOONLESS_DATA` to
  a directory your user can write, because the default `/var/lib/moonless` is
  root-owned and the gateway's upload would fail with `500 moonless: cannot
  store module at /var/lib/moonless/...: <permission error>`:

  ```bash
  # on the host
  MOONLESS_DATA="$HOME/.moonless" \
  MOONLESS_GATEWAY_URL=http://127.0.0.1:8080 \
  MOONLESS_RUNNER_PUBLIC_URL=http://host.docker.internal:8082 \
    moon run -- cmd/runner
  ```

  `host.docker.internal` resolves on Docker Desktop (macOS/Windows). On Linux
  add `extra_hosts: ["host.docker.internal:host-gateway"]` to the gateway
  service (or use the bridge IP, e.g. `172.17.0.1`). If you see 500s on upload
  in the runner log, check that the `MOONLESS_DATA` directory exists and is
  writable by the user running the runner.

- **Both must agree on the port.** The runner always binds `8082`; the public
  URL must point at a host/port that forwards to it.

To verify from inside the gateway container before relying on it:

```bash
docker compose exec gateway sh -c \
  'wget -qO- http://node-2:8082/healthz || curl -fsS http://node-2:8082/healthz'
```

The runner answers `GET /healthz` with `ok`. If that fails, the URL is not
reachable and dispatch uploads will fail the same way. The runner also logs its
advertised URL at startup (`listening on 0.0.0.0:8082 (advertising <url>)`), and
the gateway logs each upload outcome with the node URL it used.

## Placement

`select_runner` treats the Compose runner as an implicit node 0, configured by
the gateway's `MOONLESS_RUNNER_URL` (default `http://runner:8082`). With N
registered nodes:

```moonbit
let count = registry.nodes.length() + 1
let selected = registry.next % count
```

`next` increments on every dispatch, so traffic is round-robin over N+1 slots:

- slot 0 is always `MOONLESS_RUNNER_URL`;
- slots 1..N are the registered nodes in registration order.

Because `id` and `url` are the same value, two nodes must not announce the same
URL, and **changing** a node's public URL registers a *new* node rather than
updating the old one. The old entry is not removed immediately: each
registration refreshes a heartbeat, and a node that has not re-registered for
90 s (three missed 30 s rounds) is pruned before the next placement decision, so
a stale shadow entry stops receiving traffic shortly after its runner changes
address or dies. The counter and the node list are process-local, so a gateway
restart resets both; nodes reappear within 30 s as they re-register.

## Module delivery

The Compose runner, the builder, and the gateway share the `moonless-data`
volume, so a build the builder wrote is already on the runner's disk. A remote
node has its own `MOONLESS_DATA`, so the gateway uploads the build before
invoking it:

1. `ensure_runner_module` reads
   `<data_root>/functions/<name>/<build_id>/func.wasm` and the `policy.json`
   next to it from the gateway's own data root.
2. It base64-encodes the wasm and posts
   `ModuleUpload{name, build_id, wasm, policy}` to `<node>/modules` with a 30 s
   timeout.
3. The node validates the path segments, writes `func.wasm` (mode 755) and
   `policy.json` under its own `data_root/functions/<name>/<build_id>/`, and
   replies `{"ok": true}` (`cmd/runner/modules.mbt`).

The upload runs before every invocation placed on a remote node; there is no
"already uploaded" cache.

The gateway then posts `RunRequest{name, event, build_id, limits}` to
`<node>/run` with a 70 s client timeout. The runner resolves the module from
the requested `build_id` — an explicit build wins when the file exists, and
otherwise the node reports `build unavailable on runner` — runs it under
moonrun, and returns
`RunResult{stdout, stderr, exit_code, duration_ms, truncated}`.

When a step fails, the gateway synthesizes a result with exit code 127 and a
marker in stderr:

| stderr | Cause |
| -------------------------------------------- | ----------------------------------------------------- |
| `moonless: failed to upload module to runner: <reason>` | build unreadable on the gateway, or the `/modules` call failed (the reason names the path or URL) |
| `moonless: runner unreachable`                | `/run` timed out or the connection failed             |
| `moonless: runner protocol error`             | the response body did not parse as `RunResult`        |

The gateway also logs the selected node and the upload outcome (`uploaded <fn>
build=<id> to runner <url>` / `module upload to <url> failed: <reason>`), so a
failure names the node that was chosen. A non-JSON reply now carries the HTTP
status and a body snippet (`returned status 500 with a non-JSON body: internal
error`), so you can see what actually answered at that address. A common cause
is a registered node URL the gateway cannot reach — for example `127.0.0.1`
announced from inside the gateway's network namespace points back at the gateway
itself, not the node. Another is a stale node left behind after changing
`MOONLESS_RUNNER_PUBLIC_URL`; it is pruned 90 s after it stops re-registering.

The runner logs its side of these gateway interactions too, so a failed upload
is diagnosable without correlating two log streams:

```text
[runner] INFO  node=http://node-2:8082 gateway upload name=resize build=b-1001 wasm=2841b policy=0b
[runner] INFO  node=http://node-2:8082 stored upload name=resize build=b-1001 wasm=2841b at /var/lib/moonless/functions/resize/b-1001
[runner] INFO  node=http://node-2:8082 gateway run request name=resize source=http build=b-1001
```

A rejection is logged at WARN with the reason (`rejected upload …`,
`rejected /modules: <parse error>`), and a storage failure — for example an
unwritable `MOONLESS_DATA` on a host runner — is logged at ERROR with the target
path and the OS error, and returned in the 500 body as `moonless: cannot store
module at <dir>: <error>` (no longer just the router's generic `internal
error`).

## Per-node configuration

Nodes are not interchangeable: each one runs with its own environment
(`cmd/runner/execute.mbt`).

| Variable                    | Default           | Effect                                              |
| --------------------------- | ----------------- | --------------------------------------------------- |
| `MOONLESS_DATA`             | `/var/lib/moonless` | module, log, and registry directory on that node  |
| `MOONLESS_RUN_TIMEOUT_MS`   | `60000`           | default run timeout                                 |
| `MOONLESS_MAX_CONCURRENCY`  | `8`               | global concurrent runs on the node                  |
| `MOONLESS_OUTPUT_LIMIT`     | `10485760`        | per-stream stdout/stderr cap                        |
| `MOONLESS_LOG_MAX_BYTES`    | `16777216`        | per-file run log size cap                           |
| `MOONLESS_LOG_KEEP`         | `14`              | log files retained per function                     |
| `MOONLESS_REDIS_URL`, `MOONLESS_MYSQL_URL`, `MOONLESS_POSTGRES_URL`, `MOONLESS_S3_ENDPOINT`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` | unset | injected into every function process on the node |

The gateway does not populate `RunRequest.env`, so data-service addresses and
AWS credentials must be set on every node that should hand them to functions.

Per-function `[limits]` are resolved by the gateway and sent with every run, so
remote nodes honor them without the shared registry volume. Two scopes differ:

- `timeout_ms` and `concurrency` are enforced by whichever node receives the
  run, so `concurrency` is per-node, not cluster-wide: with three nodes and
  `concurrency = 2`, up to six runs can execute at once.
- `max_connection` is enforced at the gateway and stays cluster-wide for HTTP
  triggers.

## Caveats

- **In-memory registry.** A gateway restart drops the node list. Until nodes
  re-register (within 30 s), only the default runner receives work.
- **Stale nodes expire.** Each registration refreshes a node's heartbeat. A
  node that stops re-registering for 90 s (three missed 30 s rounds) is pruned,
  so a node that changed its `MOONLESS_RUNNER_PUBLIC_URL` — which, because the
  id *is* the URL, arrives as a *new* node — stops shadowing the live one after
  the TTL. The gateway does not actively probe nodes; `GET /healthz` on a runner
  (returns `ok`) is for manual checks only.
- **Logs are node-local.** Each runner appends run logs under its own
  `MOONLESS_DATA`, while the gateway's logs API reads only its own data root.
  Runs executed on remote nodes therefore do not appear in `moonless logs` or
  `moonless runs`. Collect them from the node directly, or point
  `MOONLESS_DATA` at shared storage. Every runner also writes one `start` and
  one `finish` line per invocation to stderr, tagged with `node=<public_url>`
  (its `MOONLESS_RUNNER_PUBLIC_URL`, or `local` when unset), so a collected
  stream shows which node executed which function:

  ```text
  ... [runner] INFO node=http://node-2:8082 start name=resize source=http build=b-1001
  ... [runner] INFO node=http://node-2:8082 execute name=resize module=/var/lib/moonless/functions/resize/b-1001/func.wasm timeout=60000ms concurrency=8
  ... [runner] INFO node=http://node-2:8082 finish name=resize source=http exit=0 duration=42ms truncated=false
  ```

- **Delete is node-local.** `moonless delete` removes modules, builds, and logs
  under the gateway's data root only; copies uploaded to remote nodes stay
  there.
- **Upload cost.** With no upload cache, every remote run pays the wasm
  transfer again. A module large enough to exceed the 30 s upload timeout fails
  with the upload marker above.
- **Round-robin ignores load and locality.** A slow or busy node still gets its
  turn; placement does not consider capacity or whether the node already holds
  the build.
- **Gateway wait is 70 s.** `/run` uses a 70 s client timeout, so a function
  whose `timeout_ms` exceeds that surfaces as `runner unreachable`.

## Security

Neither the runner's `/run` and `/modules` nor the gateway's `/api/*` endpoints
authenticate requests. Anyone who can reach a node can push a module and
execute it, and anyone who can reach the gateway can register a bogus runner
and receive uploaded wasm builds. Keep runner ports on a trusted network, and
do not publish 8082 or the management API. Because `/api/runners/register` is
unauthenticated and in-memory, the node list is a scheduling hint, not a
security boundary.
