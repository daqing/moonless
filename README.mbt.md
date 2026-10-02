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

- **MoonBit-first functions.** A function is an ordinary MoonBit native
  program. No proprietary SDK, no vendor runtime — whatever `moon build`
  produces is what the platform runs.
- **Three trigger types.** HTTP route, cron schedule, and S3 put events —
  declared in a small manifest next to your code.
- **A Unix-style function contract.** The trigger context arrives as the
  `MOONLESS_EVENT` environment variable; results go to stdout, logs to
  stderr. A function debugs locally with the platform completely out of
  the way.
- **Deploy source, not binaries.** `moonless deploy` uploads your MoonBit
  sources and vendored dependencies; the platform builds the Linux
  binary — fully offline on the server side. No cross-compilation on
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
   deploy / list / logs   │    │  ▲           │          (native binary)  │
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
| `builder`    | Builds uploaded sources into Linux binaries with the moon toolchain       |
| `runner`     | Execution plane: forks function processes, captures stdout/stderr         |
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
cd moonless
moon build cmd/moonless --target native
export MOONLESS_SERVER=http://localhost:8080
```

### 3. Write a function

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

MVP simplification: HTTP responses always return `200` with stdout as the
body. Status-code and header control is on the roadmap.

### Debug locally — platform optional

Because the contract is just environment variables and standard streams,
you can run a function by hand exactly the way the platform does:

```bash
MOONLESS_EVENT='{"source":"http","method":"GET","path":"/fn/hello"}' \
  moon run cmd/main --target native
```

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

## Using data services

Give moonless the addresses of your Redis / MySQL / Postgres instances
(the knobs live in `docker-compose.yml`), and every function receives them
as environment variables at run time:

```text
MOONLESS_REDIS_URL=redis://redis.internal:6379
MOONLESS_MYSQL_URL=mysql://user:pass@mysql.internal:3306/db
MOONLESS_POSTGRES_URL=postgres://user:pass@pg.internal:5432/db
MOONLESS_S3_ENDPOINT=http://seaweedfs:8333
```

Connect with the MoonBit ecosystem drivers:

- Redis: [`hackwaly/redis`](https://mooncakes.io/docs/hackwaly/redis@0.1.1)
- MySQL: [`moonbitstack/moonmysql`](https://mooncakes.io/docs/moonbitstack/moonmysql@0.7.3)
- Postgres: [`moonbit-community/postgres`](https://mooncakes.io/docs/moonbit-community/postgres@0.1.1)

## Roadmap

- [ ] **P0 — the minimum loop:** `deploy` / `list` / `logs` CLI, source
      upload, on-platform build, HTTP trigger with stdout responses
- [ ] **P1 — schedules:** cron scheduler, log collection
- [ ] **P2 — events:** SeaweedFS integration (S3 API + put-event triggers),
      data-service address injection
- [ ] **P3 — hardening:** timeouts and concurrency limits, versioning and
      rollback, HTTP status-code and header control

Ideas for later: multi-language functions (the function contract is
language-agnostic by design), function versioning, multi-node runners.

## License

[MIT](LICENSE)
