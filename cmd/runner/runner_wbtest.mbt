///|
// Runner fixtures: compile tiny function projects to wasm with the real
// toolchain and install them into a test data root, exactly as the builder
// would store them.

///|
priv suberror FixtureError {
  FixtureError(String)
} derive(Debug)

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
fn test_config(data_root : String, timeout_ms? : Int = 60_000) -> RunnerConfig {
  { data_root, timeout_ms, }
}

///|
async test "POST /run executes a stored function with the event env" {
  let fixture_dir = @fs.tmpdir(prefix="moonless-runner-fixture-")
  let wasm_module = build_fixture_module(fixture_dir, echo_pkg(), echo_main())
  let data_root = @fs.tmpdir(prefix="moonless-runner-test-")
  install_function(data_root, "echo-fn", "b-1001", wasm_module)
  @async.with_task_group(group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:18475"))
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(server, runner_router(test_config(data_root)))
    })
    let payload : Json = {
      "name": "echo-fn",
      "event": { "source": "http", "method": "GET", "path": "/fn/echo-fn" },
    }
    let response = @shared.http_post_json(
      "http://127.0.0.1:18475/run",
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
