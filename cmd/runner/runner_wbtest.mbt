///|
// Runner fixtures: compile tiny function projects to wasm with the real
// toolchain and install them into a test data root, exactly as the builder
// would store them.

///|
priv suberror FixtureError {
  FixtureError(String)
} derive(Debug)

///|
// moon test runs test files in parallel worker processes, so fixed listen
// ports collide across runs; pick a random port instead.
fn fixture_listen_port() -> Int {
  match @env.rand(2) {
    Some(bytes) =>
      20_000 + (bytes[0].to_int() * 256 + bytes[1].to_int()) % 30_000
    None => 18_475
  }
}

///|
async fn write_fixture_files(
  dir : String,
  files : Array[(String, String)],
) -> Unit {
  @fs.mkdir(dir, recursive=true, allow_exist=true) catch {
    _ => ()
  }
  for pair in files {
    let (path, content) = pair
    let full = dir + "/" + path
    match full.rev_split_once("/") {
      Some((parent, _)) =>
        @fs.mkdir(parent, recursive=true, allow_exist=true) catch {
          _ => raise FixtureError("cannot create \{parent}")
        }
      None => ()
    }
    @fs.write_file(full, content)
  }
}

///|
// Builds the fixture to wasm and returns the module bytes.
async fn build_fixture_module(
  dir : String,
  pkg : String,
  main : String,
  moon_mod? : String = "name = \"fixture/probe\"\nversion = \"0.1.0\"\n",
) -> Bytes {
  write_fixture_files(dir, [
    ("moon.mod", moon_mod),
    ("moon.pkg", pkg),
    ("main.mbt", main),
  ])
  let (code, _, stderr) = @process.collect_output(
    "moon",
    ["build", "--target", "wasm"],
    cwd=dir[:],
  )
  if code != 0 {
    raise FixtureError("fixture build failed: \{stderr.text()}")
  }
  let build_root = dir + "/_build/wasm"
  let found : Array[String] = []
  @fs.walk(build_root, (d, entries) => {
    for entry in entries {
      if entry.has_suffix(".wasm") && found.length() == 0 {
        found.push(d + "/" + entry)
      }
    }
  })
  if found.length() == 0 {
    raise FixtureError("fixture produced no wasm module")
  }
  (@fs.read_file(found[0]) catch {
    _ => raise FixtureError("module unreadable")
  }).binary()
}

///|
async fn install_function(
  data_root : String,
  name : String,
  build_id : String,
  wasm_module : Bytes,
) -> Unit {
  let dir = data_root + "/functions/" + name + "/" + build_id
  @fs.mkdir(dir, recursive=true, allow_exist=true) catch {
    _ => raise FixtureError("cannot create \{dir}")
  }
  @fs.write_file(dir + "/func.wasm", wasm_module[:])
}

///|
fn echo_pkg() -> String {
  (
    #|import {
    #|  "moonbitlang/core/env",
    #|}
    #|
    #|pkgtype(kind: "executable")
  )
}

///|
fn echo_main() -> String {
  (
    #|fn main {
    #|  match @env.get_env_var("MOONLESS_EVENT") {
    #|    Some(event) => println("EVT:\{event}")
    #|    None => println("NOEVT")
    #|  }
    #|}
  )
}

///|
fn env_echo_main() -> String {
  (
    #|fn main {
    #|  let event = @env.get_env_var("MOONLESS_EVENT").unwrap_or("NOEVT")
    #|  let redis = @env.get_env_var("MOONLESS_REDIS_URL").unwrap_or("NOREDIS")
    #|  println("EVT:\{event}")
    #|  println("REDIS:\{redis}")
    #|}
  )
}

///|
fn async_pkg() -> String {
  (
    #|import {
    #|  "moonbitlang/async",
    #|}
    #|
    #|pkgtype(kind: "executable")
  )
}

///|
fn sleep_main() -> String {
  (
    #|async fn main {
    #|  @async.sleep(400)
    #|  println("awake")
    #|}
  )
}

///|
fn crash_main() -> String {
  (
    #|fn main {
    #|  println("before")
    #|  let x : Int = 1 / 0
    #|  ignore(x)
    #|}
  )
}

///|
fn test_config(
  data_root : String,
  timeout_ms? : Int = 60_000,
  max_concurrency? : Int = 8,
  output_cap? : Int = 10 * 1024 * 1024,
) -> RunnerConfig {
  make_runner_config(data_root, timeout_ms, max_concurrency, output_cap)
}

///|
async test "POST /run executes a stored function with the event env" {
  let fixture_dir = @fs.tmpdir(prefix="moonless-runner-fixture-")
  let wasm_module = build_fixture_module(fixture_dir, echo_pkg(), echo_main())
  let data_root = @fs.tmpdir(prefix="moonless-runner-test-")
  install_function(data_root, "echo-fn", "b-1001", wasm_module)
  let port = fixture_listen_port()
  @async.with_task_group(group => {
    let server = @http.Server(
      @socket.Addr::parse("127.0.0.1:\{port}"),
      reuse_addr=true,
    )
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(server, runner_router(test_config(data_root)))
    })
    let payload : Json = {
      "name": "echo-fn",
      "event": { "source": "http", "method": "GET", "path": "/fn/echo-fn" },
    }
    let response = @shared.http_post_json(
      "http://127.0.0.1:\{port}/run",
      payload,
      timeout_ms=30_000,
    )
    let text = response.stringify()
    assert_true(text.contains("\"exitCode\":0"))
    // The function echoed MOONLESS_EVENT back on stdout.
    assert_true(text.contains("EVT:"))
    assert_true(text.contains("echo-fn"))
    server.close()
  })
}

///|
async test "run_function reports unknown functions" {
  let data_root = @fs.tmpdir(prefix="moonless-runner-test-")
  let result = run_function(
    test_config(data_root),
    @shared.RunRequest(
      name="ghost",
      event=@shared.Event::Http(
        @shared.HttpEventData(
          http_method="GET",
          path="/fn/ghost",
          query="",
          body="",
        ),
      ),
    ),
  )
  assert_eq(result.exit_code, 127)
  assert_true(result.stderr.contains("unknown function"))
}

///|
async test "injected service-URL env reaches the function" {
  let fixture_dir = @fs.tmpdir(prefix="moonless-runner-fixture-")
  let wasm_module = build_fixture_module(
    fixture_dir,
    echo_pkg(),
    env_echo_main(),
  )
  let data_root = @fs.tmpdir(prefix="moonless-runner-test-")
  install_function(data_root, "env-fn", "b-1001", wasm_module)
  let env : Map[String, String] = Map([])
  env["MOONLESS_REDIS_URL"] = "redis://redis.internal:6379"
  let result = run_function(
    test_config(data_root),
    @shared.RunRequest(
      name="env-fn",
      event=@shared.Event::Cron(
        @shared.CronEventData(schedule="0 8 * * *", time="2026-10-03T08:00:00Z"),
      ),
      env~,
    ),
  )
  assert_eq(result.exit_code, 0)
  assert_true(result.stdout.contains("REDIS:redis://redis.internal:6379"))
  assert_true(result.stdout.contains("EVT:"))
  assert_true(result.stdout.contains("0 8 * * *"))
}

///|
async test "sleep fixture completes after its delay" {
  let fixture_dir = @fs.tmpdir(prefix="moonless-runner-fixture-")
  let with_async =
    #|name = "fixture/sleep-fn"
    #|version = "0.1.0"
    #|
    #|import {
    #|  "moonbitlang/async@0.22.4",
    #|}
  let wasm_module = build_fixture_module(
    fixture_dir,
    async_pkg(),
    sleep_main(),
    moon_mod=with_async,
  )
  let data_root = @fs.tmpdir(prefix="moonless-runner-test-")
  install_function(data_root, "sleep-fn", "b-1001", wasm_module)
  let result = run_function(
    test_config(data_root),
    @shared.RunRequest(
      name="sleep-fn",
      event=@shared.Event::S3(
        @shared.S3EventData(event="put", bucket="uploads", key="k"),
      ),
    ),
  )
  assert_eq(result.exit_code, 0)
  assert_eq(result.stdout, "awake\n")
  assert_true(result.duration_ms >= 350)
}

///|
async test "non-zero exit surfaces stderr from the runtime" {
  let fixture_dir = @fs.tmpdir(prefix="moonless-runner-fixture-")
  let wasm_module = build_fixture_module(fixture_dir, echo_pkg(), crash_main())
  let data_root = @fs.tmpdir(prefix="moonless-runner-test-")
  install_function(data_root, "crash-fn", "b-1001", wasm_module)
  let result = run_function(
    test_config(data_root),
    @shared.RunRequest(
      name="crash-fn",
      event=@shared.Event::Http(
        @shared.HttpEventData(
          http_method="GET",
          path="/fn/crash-fn",
          query="",
          body="",
        ),
      ),
    ),
  )
  assert_eq(result.exit_code, 1)
  assert_eq(result.stdout, "before\n")
  assert_true(result.stderr.contains("RuntimeError"))
}

///|
async test "slow functions are killed and reported as timed out" {
  let fixture_dir = @fs.tmpdir(prefix="moonless-runner-fixture-")
  let with_async =
    #|name = "fixture/slow-fn"
    #|version = "0.1.0"
    #|
    #|import {
    #|  "moonbitlang/async@0.22.4",
    #|}
  let slow_main =
    #|async fn main {
    #|  println("starting")
    #|  @async.sleep(30_000)
    #|  println("never")
    #|}
  let wasm_module = build_fixture_module(
    fixture_dir,
    async_pkg(),
    slow_main,
    moon_mod=with_async,
  )
  let data_root = @fs.tmpdir(prefix="moonless-runner-test-")
  install_function(data_root, "slow-fn", "b-1001", wasm_module)
  let started = @async.now()
  let result = run_function(
    test_config(data_root, timeout_ms=400),
    @shared.RunRequest(
      name="slow-fn",
      event=@shared.Event::Http(
        @shared.HttpEventData(
          http_method="GET",
          path="/fn/slow-fn",
          query="",
          body="",
        ),
      ),
    ),
  )
  assert_eq(result.exit_code, 124)
  assert_true(result.stderr.contains("timed out"))
  assert_true(result.duration_ms < 5000)
  assert_true((@async.now() - started).to_int() < 10_000)
}

///|
async test "burst requests queue behind the concurrency cap" {
  let fixture_dir = @fs.tmpdir(prefix="moonless-runner-fixture-")
  let with_async =
    #|name = "fixture/hold-fn"
    #|version = "0.1.0"
    #|
    #|import {
    #|  "moonbitlang/async@0.22.4",
    #|}
  let hold_main =
    #|async fn main {
    #|  @async.sleep(300)
    #|  println("held")
    #|}
  let wasm_module = build_fixture_module(
    fixture_dir,
    async_pkg(),
    hold_main,
    moon_mod=with_async,
  )
  let data_root = @fs.tmpdir(prefix="moonless-runner-test-")
  install_function(data_root, "hold-fn", "b-1001", wasm_module)
  // Cap of 2 with 6 concurrent requests: three waves of ~300ms.
  let cfg = test_config(data_root, max_concurrency=2)
  let results : FixedArray[@shared.RunResult] = FixedArray::make(
    6,
    @shared.RunResult(),
  )
  let started = @async.now()
  @async.with_task_group(group => {
    for i in 0..<6 {
      group.spawn_bg(() => {
        results[i] = run_function(
          cfg,
          @shared.RunRequest(
            name="hold-fn",
            event=@shared.Event::Http(
              @shared.HttpEventData(
                http_method="GET",
                path="/fn/hold-fn",
                query="",
                body="",
              ),
            ),
          ),
        )
      })
    }
  })
  let elapsed = (@async.now() - started).to_int()
  for i in 0..<6 {
    assert_eq(results[i].exit_code, 0)
    assert_eq(results[i].stdout, "held\n")
  }
  // 6 runs / 2 slots = 3 waves of ~300ms: queued, not rejected or raced.
  assert_true(elapsed >= 800)
}

///|
async test "runs resolve to the newest stored build" {
  let data_root = @fs.tmpdir(prefix="moonless-runner-test-")
  let old_dir = @fs.tmpdir(prefix="moonless-runner-fixture-")
  let old_main =
    #|fn main {
    #|  println("MARK:old")
    #|}
  let old_module = build_fixture_module(old_dir, echo_pkg(), old_main)
  install_function(data_root, "mark-fn", "b-1001", old_module)
  let request = @shared.RunRequest(
    name="mark-fn",
    event=@shared.Event::Http(
      @shared.HttpEventData(
        http_method="GET",
        path="/fn/mark-fn",
        query="",
        body="",
      ),
    ),
  )
  let result = run_function(test_config(data_root), request)
  assert_eq(result.stdout, "MARK:old\n")
  // Re-deploy: a newer build id takes over on the next run.
  let new_dir = @fs.tmpdir(prefix="moonless-runner-fixture-")
  let new_main =
    #|fn main {
    #|  println("MARK:new")
    #|}
  let new_module = build_fixture_module(new_dir, echo_pkg(), new_main)
  install_function(data_root, "mark-fn", "b-1002", new_module)
  let result = run_function(test_config(data_root), request)
  assert_eq(result.stdout, "MARK:new\n")
}

///|
async test "each run appends an event+stderr record to the day log" {
  let fixture_dir = @fs.tmpdir(prefix="moonless-runner-fixture-")
  let wasm_module = build_fixture_module(fixture_dir, echo_pkg(), crash_main())
  let data_root = @fs.tmpdir(prefix="moonless-runner-test-")
  install_function(data_root, "log-fn", "b-1001", wasm_module)
  let result = run_function(
    test_config(data_root),
    @shared.RunRequest(
      name="log-fn",
      event=@shared.Event::S3(
        @shared.S3EventData(event="put", bucket="uploads", key="a.csv"),
      ),
    ),
  )
  assert_eq(result.exit_code, 1)
  let date = @shared.format_timestamp(@async.now())[:10].to_owned()
  let log_path = data_root + "/logs/log-fn/\{date}.log"
  assert_true(@fs.exists(log_path))
  let log = (@fs.read_file(log_path) catch {
    _ => raise FixtureError("log unreadable")
  }).text() catch {
    _ => raise FixtureError("log not text")
  }
  assert_true(log.contains("event="))
  assert_true(log.contains("uploads"))
  assert_true(log.contains("exit=1"))
  assert_true(log.contains("RuntimeError"))
}

///|
async test "large output is captured in full under the cap" {
  let fixture_dir = @fs.tmpdir(prefix="moonless-runner-fixture-")
  let big_main =
    #|fn main {
    #|  for i in 0..<2000 {
    #|    println("line \{i} abcdefghijabcdefghijabcdefghijabcdefghij")
    #|  }
    #|}
  let wasm_module = build_fixture_module(fixture_dir, echo_pkg(), big_main)
  let data_root = @fs.tmpdir(prefix="moonless-runner-test-")
  install_function(data_root, "big-fn", "b-1001", wasm_module)
  let result = run_function(
    test_config(data_root),
    @shared.RunRequest(
      name="big-fn",
      event=@shared.Event::Http(
        @shared.HttpEventData(
          http_method="GET",
          path="/fn/big-fn",
          query="",
          body="",
        ),
      ),
    ),
  )
  assert_eq(result.exit_code, 0)
  assert_eq(result.truncated, false)
  assert_true(result.stdout.length() > 90_000)
  assert_true(result.stdout.contains("line 0 "))
  assert_true(result.stdout.contains("line 1999 "))
  let mut lines = 0
  for ch in result.stdout {
    if ch == '\n' {
      lines += 1
    }
  }
  assert_eq(lines, 2000)
}

///|
async test "infinite echo is capped, truncated, and timed out" {
  let fixture_dir = @fs.tmpdir(prefix="moonless-runner-fixture-")
  let spam_main =
    #|fn main {
    #|  for ;; {
    #|    println("spam spam spam spam spam")
    #|  }
    #|}
  let wasm_module = build_fixture_module(fixture_dir, echo_pkg(), spam_main)
  let data_root = @fs.tmpdir(prefix="moonless-runner-test-")
  install_function(data_root, "spam-fn", "b-1001", wasm_module)
  // Tiny cap and short deadline: the buffers must stay bounded.
  let result = run_function(
    test_config(data_root, timeout_ms=1500, output_cap=4000),
    @shared.RunRequest(
      name="spam-fn",
      event=@shared.Event::Http(
        @shared.HttpEventData(
          http_method="GET",
          path="/fn/spam-fn",
          query="",
          body="",
        ),
      ),
    ),
  )
  assert_eq(result.exit_code, 124)
  assert_eq(result.truncated, true)
  assert_true(result.stderr.contains("timed out"))
  // stdout bounded by the cap despite the function echoing forever.
  assert_true(result.stdout.length() > 0)
  assert_true(result.stdout.length() <= 4000)
  assert_true(result.stdout.contains("spam"))
}
