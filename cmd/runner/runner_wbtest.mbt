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
) -> Bytes {
  write_fixture_files(dir, [
    ("moon.mod", "name = \"fixture/probe\"\nversion = \"0.1.0\"\n"),
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
fn test_config(data_root : String) -> RunnerConfig {
  { data_root, }
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
