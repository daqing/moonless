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
URL. The counter and the node list are process-local, so a gateway restart
resets both; nodes reappear within 30 s as they re-register.

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

| stderr                                       | Cause                                                 |
| -------------------------------------------- | ----------------------------------------------------- |
| `moonless: failed to upload module to runner` | module read, policy read, or `/modules` call failed   |
| `moonless: runner unreachable`                | `/run` timed out or the connection failed             |
| `moonless: runner protocol error`             | the response body did not parse as `RunResult`        |

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
- **No unregister or health checks.** There is no endpoint to remove a node,
  and dead nodes are not detected. A dead node keeps its share of the
  round-robin and fails those runs with `runner unreachable` (exit 127).
  Restart the gateway to drop it from the list.
- **Logs are node-local.** Each runner appends run logs under its own
  `MOONLESS_DATA`, while the gateway's logs API reads only its own data root.
  Runs executed on remote nodes therefore do not appear in `moonless logs` or
  `moonless runs`. Collect them from the node directly, or point
  `MOONLESS_DATA` at shared storage.
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
