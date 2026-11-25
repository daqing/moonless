# max_connection admission limit

[中文版](max_connection_guide.zh-CN.md)

`[limits] max_connection` caps how many HTTP client requests the gateway admits
for a function at the same time. Requests above the cap fail immediately: they
never reach the runner, and the function is not executed.

## Configuration

```toml
[limits]
timeout_ms = 10000
concurrency = 2
max_connection = 2
```

All three values must be positive integers. `max_connection` applies to HTTP
triggers only; cron and S3 dispatches do not consume a slot.

## Enforcement path

For `/fn/<name>`, the gateway:

1. looks up the function in the registry;
2. checks that the HTTP trigger is enabled;
3. tries to reserve a connection slot for the function;
4. if no slot is available, replies `429 Too Many Requests` and ends the
   request;
5. otherwise reads the body, builds the event, and calls `dispatch_run`;
6. releases the slot when the request ends, whether it succeeds, fails, times
   out, or the client disconnects.

The slot check happens before `dispatch_run`, so an over-limit request never
appears at the runner's `/run` endpoint, never executes the function, and
produces no run log entry.

"Fail" here means the HTTP request ends with 429; the gateway process keeps
running. The response body looks like:

```text
moonless: function <name> exceeded max_connection=<n>
```

## How it differs from concurrency

- `concurrency` caps how many runs execute at once on a runner. Extra runs wait
  in the runner's queue and eventually execute.
- `max_connection` caps how many HTTP requests the gateway admits at once.
  Extra requests get 429 immediately; they are neither queued nor executed.

Both counters include running and waiting requests:

- an admitted gateway request holds a `max_connection` slot until it returns;
- a run holds a `concurrency` slot while it waits in the runner.

Consequences:

- with `max_connection > concurrency`, admitted requests beyond the execution
  capacity wait in the runner;
- with `max_connection <= concurrency`, new requests are mostly rejected once
  the execution slots are full;
- to reject as soon as execution capacity is full, set the two values equal.

## Scope

- Counted per function.
- The counter lives in the gateway process. A single-gateway deployment gets a
  global limit; with multiple gateways, each process has its own budget.
- HTTP triggers only. Cron, S3, and direct calls to the runner's `/run` bypass
  this counter.
- An idle keep-alive connection holds no slot; only requests in flight count.

## Verifying it

Check the status code and body of an over-limit request:

```bash
# Expect 429 with max_connection in the body
curl -i http://127.0.0.1:8080/fn/<name>
```

A full acceptance run:

1. set `max_connection = 1` on the function and redeploy;
2. start one request that blocks for a while;
3. while it is still running, send a second request; it should get 429;
4. after the first request finishes, send another; it should succeed.

The automated test in `cmd/gateway/connections_wbtest.mbt` covers this path: the
runner invocation count stays unchanged after a rejection, and only a request
admitted after the slot is released reaches the runner.

## Deployment notes

- Rebuild the gateway image after changing the code:
  `docker compose up -d --build gateway`.
- After editing `moonless.toml`, run `moonless deploy` again so the registry
  manifest includes `maxConnection`.
- Restarting the gateway without redeploying keeps the old manifest, which has
  no such field, so the function remains unlimited.

## Implementation

- `cmd/gateway/trigger.mbt` — admission check and the 429 response.
- `cmd/gateway/connections.mbt` — per-function connection counter.
- `cmd/gateway/connections_wbtest.mbt` — regression test for rejection, slot
  release, and the runner not being called.
- `src/shared/manifest.mbt`, `src/shared/protocol.mbt` — TOML and registry JSON
  codecs.
