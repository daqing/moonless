///|
async fn write_function_limits(
  data_root : String,
  name : String,
  timeout_ms~ : Int32? = None,
  concurrency~ : Int32? = None,
) -> Unit {
  let record = @shared.RegistryRecord(
    name~,
    manifest=@shared.Manifest(
      name~,
      limits=@shared.FunctionLimits(timeout_ms~, concurrency~),
    ),
    build_id="b-1001",
    updated_at="2026-11-05T00:00:00.000Z",
  )
  let root : Map[String, Json] = Map([])
  root[name] = record.to_json()
  @fs.mkdir(data_root + "/registry", recursive=true, allow_exist=true)
  @fs.write_file(
    data_root + "/registry/registry.json",
    Json::object(root).stringify(),
  )
}

///|
fn limits_event(name : String) -> @shared.Event {
  @shared.Event::Http(
    @shared.HttpEventData(
      http_method="GET",
      path="/fn/\{name}",
      query="",
      body="",
    ),
  )
}

///|
fn limits_async_module() -> String {
  (
    #|name = "fixture/limits"
    #|version = "0.1.0"
    #|
    #|import {
    #|  "moonbitlang/async@0.22.4",
    #|}
  )
}

///|
async test "manifest timeout overrides the runner default" {
  let fixture_dir = @fs.tmpdir(prefix="moonless-runner-fixture-")
  let slow_main =
    #|async fn main {
    #|  @async.sleep(30_000)
    #|}
  let wasm_module = build_fixture_module(
    fixture_dir,
    async_pkg(),
    slow_main,
    moon_mod=limits_async_module(),
  )
  let data_root = @fs.tmpdir(prefix="moonless-runner-test-")
  install_function(data_root, "limited-slow", "b-1001", wasm_module)
  write_function_limits(data_root, "limited-slow", timeout_ms=Some(100))
  let result = run_function(
    test_config(data_root),
    @shared.RunRequest(name="limited-slow", event=limits_event("limited-slow")),
  )
  assert_eq(result.exit_code, 124)
  assert_true(result.stderr.contains("100ms"))
}

///|
async test "manifest concurrency serializes calls to one function" {
  let fixture_dir = @fs.tmpdir(prefix="moonless-runner-fixture-")
  let hold_main =
    #|async fn main {
    #|  @async.sleep(300)
    #|  println("held")
    #|}
  let wasm_module = build_fixture_module(
    fixture_dir,
    async_pkg(),
    hold_main,
    moon_mod=limits_async_module(),
  )
  let data_root = @fs.tmpdir(prefix="moonless-runner-test-")
  install_function(data_root, "limited-hold", "b-1001", wasm_module)
  write_function_limits(data_root, "limited-hold", concurrency=Some(1))
  let cfg = test_config(data_root)
  let results = FixedArray::make(2, @shared.RunResult())
  let started = @async.now()
  @async.with_task_group(group => {
    for i in 0..<2 {
      group.spawn_bg(() => {
        results[i] = run_function(
          cfg,
          @shared.RunRequest(
            name="limited-hold",
            event=limits_event("limited-hold"),
          ),
        )
      })
    }
  })
  for result in results {
    assert_eq(result.exit_code, 0)
    assert_eq(result.stdout, "held\n")
  }
  assert_true((@async.now() - started).to_int() >= 550)
}
