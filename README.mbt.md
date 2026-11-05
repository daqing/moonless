# moonless

**moonless** is a self-hosted serverless platform for your intranet, written
entirely in [MoonBit](https://www.moonbitlang.com). The name is a
portmanteau: **Moon**Bit + server**less**.

> **Status:** work-in-progress, built for the MoonBit hackathon (October
> 2026). This README describes the design we are building toward; features
> land in the order listed in the [Roadmap](#roadmap).
>
> [中文文档](README.zh-CN.md)

## Why moonless

You have a machine inside your network and a pile of small jobs that deserve
to run as services: an HTTP endpoint that renders a report, a nightly
cleanup task, a hook that fires whenever a file lands in a bucket. You
don't want to babysit a server for each of them, and you can't reach — or
don't want — a public FaaS cloud.

moonless gives that machine a job: run `docker compose up` once, and you
have a function platform for the whole intranet. Write functions in
MoonBit, ship them with one command, trigger them over HTTP, on a schedule,
or by uploading a file.

## Features at a glance

- **MoonBit-first functions.** A function is a MoonBit program compiled
  to a WebAssembly module — MoonBit's first-class target. No
  proprietary SDK, no vendor runtime: whatever `moon build --target
  wasm` produces is what the platform runs.
- **Sandboxed by default.** Functions execute as wasm modules under
  moonrun: memory-isolated, no ambient host access — while keeping full
  networking (TCP / TLS) through the runtime's host layer.
- **Three trigger types.** HTTP route, cron schedule, and S3 put events —
  declared in a small manifest next to your code.
- **A Unix-style function contract.** The trigger context arrives as the
  `MOONLESS_EVENT` environment variable; results go to stdout, logs to
  stderr. A function debugs locally with the platform completely out of
  the way.
- **Deploy source, not binaries.** `moonless deploy` uploads your MoonBit
  sources and vendored dependencies; the platform builds the wasm
  module — fully offline on the server side. No cross-compilation on
  your laptop, ever.
- **Platform services written in MoonBit.** Gateway, builder, runner, and
  scheduler are all MoonBit programs built on
  [`moonbitlang/async`](https://mooncakes.io/docs/moonbitlang/async@0.22.4).
- **S3-compatible storage included**, powered by
  [SeaweedFS](https://github.com/seaweedfs/seaweedfs): `aws`, `mc`,
  `rclone`, and friends work out of the box.
- **Bring your own data services.** moonless points functions at your
  existing Redis / MySQL / Postgres via injected environment variables, and
  you connect with MoonBit drivers.

## Architecture

```
                          ┌───────────────────────────────────────────────┐
                          │              docker compose                   │
                          │                                               │
   moonless CLI ─────────►│  gateway ─────► runner ─────► your function   │
   deploy / list / logs   │    │  ▲           │        (wasm via moonrun) │
                          │    │  │           │                           │
                          │    ▼  │           ▼                           │
                          │  builder        scheduler                    │
                          │    │              ▲                           │
                          │    ▼              │ put events                │
                          │  SeaweedFS ───────┘  (S3-compatible storage)  │
                          │                                               │
                          │  your Redis / MySQL / Postgres (external)     │
                          └───────────────────────────────────────────────┘
```

| Service      | Responsibility                                                            |
| ------------ | ------------------------------------------------------------------------- |
| `gateway`    | Platform entry point: function HTTP routes, management API, event intake  |
| `builder`    | Builds uploaded sources into wasm modules with the moon toolchain         |
| `runner`     | Execution plane: runs wasm modules via moonrun, captures stdout/stderr    |
| `scheduler`  | Fires functions on cron schedules                                         |
| SeaweedFS    | S3-compatible object storage; notifies moonless on object uploads         |

Redis, MySQL, and Postgres stay outside the platform: you run them (or
reuse the ones you already have), and moonless just hands functions their
addresses.

## Quick start

### 1. Start the platform

On any intranet machine with Docker:

```bash
git clone https://github.com/daqing/moonless.git
cd moonless
docker compose up -d
```

### 2. Install the CLI

```bash
moon update
moon build cmd/moonless --target native
mkdir -p "$HOME/.local/bin"
cp "$PWD/_build/native/debug/build/cmd/moonless/moonless.exe" "$HOME/.local/bin/moonless"
export PATH="$HOME/.local/bin:$PATH"
export MOONLESS_SERVER=http://localhost:8080
```

### 3. Write a function

Create a separate MoonBit project from the repository root:

```bash
moon new hello
cd hello
```

A function is a standard MoonBit project with an executable package. Say
`cmd/main/main.mbt` looks like this:

```moonbit nocheck
///|
fn main {
  match @env.get_env_var("MOONLESS_EVENT") {
    Some(event) => println("hello! triggered by: \{event}")
    None => println("hello!")
  }
}
```

with the env import in `cmd/main/moon.pkg`:

```text
import {
  "moonbitlang/core/env"
}

pkgtype(kind: "executable")
```

Add a `moonless.toml` next to `moon.mod` to declare the function and its
triggers:

```toml
name = "hello"
# Optional: the moon toolchain your function expects.
# Must not exceed the platform's pinned version.
toolchain = "0.10.11"

[triggers]
http = { enabled = true }
```

### 4. Deploy and call it

```bash
moonless deploy
curl "$MOONLESS_SERVER/fn/hello"
```

### 5. Read the logs

```bash
moonless logs hello
```

Add `--follow` to keep polling and print new log records as they arrive.

## The function contract

Functions follow plain Unix conventions:

| Channel             | Meaning                                                             |
| ------------------- | ------------------------------------------------------------------- |
| `MOONLESS_EVENT` env | Trigger context, as JSON                                           |
| stdout              | Function result: the HTTP response body (HTTP trigger) or archived |
| stderr              | Logs, collected by the platform and shown by `moonless logs`       |

The event payload by trigger source:

**http**
```json
{"source": "http", "method": "POST", "path": "/fn/hello", "query": "", "body": "..."}
```

**cron**
```json
{"source": "cron", "schedule": "0 8 * * *", "time": "2026-10-02T08:00:00Z"}
```

**s3**
```json
{"source": "s3", "event": "put", "bucket": "uploads", "key": "report.csv"}
```

### HTTP response control

By default, stdout is the response body with status `200`. To set a status code
or headers, write one JSON control line before the body:

```text
{"status":201,"headers":{"Content-Type":"application/json","X-Request-Id":"abc"}}
{"created":true}
```

The control line must contain `status` or `headers`. Output without a valid
control line remains unchanged. `Content-Length`, `Transfer-Encoding`, and
`Connection` are managed by the gateway and cannot be overridden.

### Debug locally — platform optional

Because the contract is just environment variables and standard streams,
you can run a function by hand exactly the way the platform does:

```bash
MOONLESS_EVENT='{"source":"http","method":"GET","path":"/fn/hello"}' \
  moon run cmd/main --target wasm
```

## Other languages — explicit opt-in

The event environment variable and stdout/stderr contract is language-agnostic.
To deploy an existing executable instead of MoonBit source, set its package-local
path in `moonless.toml`:

```toml
name = "native-worker"
binary = "func"

[triggers]
http = { enabled = true }
```

No `moon.mod` is required in this mode. The executable must match the runner's
OS and architecture. **Native binaries run directly without the wasm sandbox**;
only use this opt-in for trusted functions.

## Triggers

All triggers are optional and declared in `moonless.toml`:

```toml
name = "resize-images"

[triggers]
http = { enabled = true }
cron = "0 8 * * *"
s3 = { bucket = "uploads", events = ["put"] }
```

- **HTTP** — the function is routed at `/fn/<name>`.
- **cron** — standard five-field cron expressions; the function fires with
  the schedule in its event.
- **S3** — upload an object with any S3 client (`aws`, `mc`, `rclone`…);
  SeaweedFS notifies moonless and the function fires with the bucket and
  key in its event. Event delivery is best-effort.

## Per-function limits

Set optional timeout and concurrency overrides in `moonless.toml`:

```toml
[limits]
timeout_ms = 5000
concurrency = 2
```

Both must be positive integers. Excess calls queue, and the runner's global
`MOONLESS_RUN_TIMEOUT_MS` and `MOONLESS_MAX_CONCURRENCY` defaults apply when a
function has no override.

## Sandbox policies

A wasm function can name a package-local moonrun policy in `moonless.toml`:

```toml
sandbox = "policy.json"
```

For example, this policy permits only the event variable and denies other host
surfaces by default:

```json
{
  "env": { "from_host": ["MOONLESS_EVENT"] },
  "fs": { "read": [], "write": [] },
  "net": { "dns": [], "connect": [], "bind": [] },
  "process": { "spawn": false }
}
```

`net.connect` controls outbound sockets and also permits the required hostname
lookups; `net.bind` accepts IP addresses or `*`. Filesystem roots are host paths,
with relative roots resolved from the policy file. The policy is stored and
uploaded with each build. Native binary functions do not use this mechanism.

This moonrun policy mode is experimental and does not cover WASI. In particular,
`process.spawn: true` gives child processes ambient host access rather than
sandboxing them under the other policy sections.

## Versioning and rollback

Every successful deploy keeps its wasm artifact and adds the build to the
function's history. Roll back to the previous build with:

```bash
moonless rollback <name>
```

The next invocation uses the selected artifact immediately.

## Multi-node runners

Start another runner with a reachable public URL and gateway address; no shared
volume is required:

```bash
docker run -d --network moonless_default \
  -e MOONLESS_GATEWAY_URL=http://gateway:8080 \
  -e MOONLESS_RUNNER_PUBLIC_URL=http://node-2:8082 \
  moonless /app/bin/runner
```

Registered nodes join round-robin placement with the default runner. The gateway
uploads the active wasm build before each remote invocation, and runners renew
registration every 30 seconds. Registration is in memory, so a gateway restart
clears the node list until runners renew.

## Using data services

Give moonless the addresses of your Redis / MySQL / Postgres instances
(the knobs live in `docker-compose.yml`), and every function receives them
as environment variables at run time:

```text
MOONLESS_REDIS_URL=redis://redis.internal:6379
MOONLESS_MYSQL_URL=mysql://user:pass@mysql.internal:3306/db
MOONLESS_POSTGRES_URL=postgres://user:pass@pg.internal:5432/db
MOONLESS_S3_ENDPOINT=http://seaweedfs:8333
AWS_ACCESS_KEY_ID=moonless
AWS_SECRET_ACCESS_KEY=moonless-secret
AWS_REGION=us-east-1
```

Set the corresponding Compose inputs and recreate the runner, for example:

```bash
REDIS_URL=redis://redis.internal:6379 docker compose up -d runner
```

Unset or empty data-service URLs are not injected. The AWS variables use the
standard names so S3 clients can consume them directly. The values above are
the local development credentials from `deploy/seaweedfs/s3.json`; change them
together for other deployments.

Connect with the MoonBit ecosystem drivers (both work from wasm
functions):

- MySQL: [`moonbitstack/moonmysql`](https://mooncakes.io/docs/moonbitstack/moonmysql@0.7.3)
- Postgres: [`moonbit-community/postgres`](https://mooncakes.io/docs/moonbit-community/postgres@0.1.1)

> Redis note: [`oboard/redis`](https://mooncakes.io/docs/oboard/redis@0.2.1)
> declares native-only targets, so moonless maintains a vendored, patched
> copy inside the repo (`vendor/redis/`, wasm support opened and verified
> end-to-end with moonrun against a real Redis).

For a complete Redis example, see `examples/redis-counter`. With `REDIS_URL`
pointing at your instance, run `moon run scripts/e2e_redis_counter.mbtx` to
package the vendored driver, deploy the function, and verify two consecutive
increments.

## Guided demo

With Docker, MoonBit, and the AWS CLI installed, run:

```bash
moon run scripts/demo.mbtx
```

The script starts the Compose stack, deploys all three core examples, triggers
them over HTTP, cron, and S3, and prints their logs. It also checks that the
whole run stays within five minutes.

## Roadmap

- [x] **P0 — the minimum loop:** `deploy` / `list` / `logs` CLI, source
      upload, on-platform build, HTTP trigger with stdout responses
- [x] **P1 — schedules:** cron scheduler, log collection
- [x] **P2 — events:** SeaweedFS integration (S3 API + put-event triggers),
      data-service address injection
- [x] **P3 — hardening:** sandbox policies (Redis wasm support:
      patch verified, upstream PR pending)

## License

[MIT](LICENSE)
