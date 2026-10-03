///|
// Gateway fixtures: a fake builder answering canned BuildResults, plus a
// real tar.gz package layout like `moonless deploy` will upload.

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
    None => 18_476
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
async fn pack_tar_gz(dir : String) -> Bytes {
  let out_dir = @fs.tmpdir(prefix="moonless-gw-pkg-")
  let tgz = out_dir + "/package.tar.gz"
  let (code, _, stderr) = @process.collect_output("tar", [
    "--format=ustar", "-czf", tgz, "-C", dir, ".",
  ])
  if code != 0 {
    raise FixtureError("tar failed: \{stderr.text()}")
  }
  (@fs.read_file(tgz) catch {
    _ => raise FixtureError("tar output unreadable")
  }).binary()
}

///|
// A builder stand-in that records the deploy name and answers ok/failure.
priv struct FakeBuilder {
  mut result : @shared.BuildResult
  seen_names : Array[String]
}

///|
fn FakeBuilder::FakeBuilder(
  result~ : @shared.BuildResult,
  seen_names~ : Array[String],
) -> FakeBuilder {
  { result, seen_names, }
}

///|
fn fake_builder_router(fake : FakeBuilder) -> @shared.Router {
  let router = @shared.Router::new()
  router.add(
    @shared.route(http_method=@http.Post, pattern="/build", handler=ctx => {
      let request = @shared.DeployRequest::from_json(
        @shared.read_json_body(ctx),
      )
      fake.seen_names.push(request.name)
      @shared.send_json(ctx.conn, 200, fake.result.to_json())
    }),
  )
  router
}

///|
fn test_config(data_root : String, builder_port : Int) -> GatewayConfig {
  {
    data_root,
    builder_url: "http://127.0.0.1:\{builder_port}",
    runner_url: "http://127.0.0.1:65534",
    registry_lock: @async.Mutex::Mutex(),
  }
}

///|
async fn write_test_package(dir : String) -> Bytes {
  write_fixture_files(dir, [
    ("moon.mod", "name = \"fixture/hello-fn\"\nversion = \"0.1.0\"\n"),
    (
      "moonless.toml",
      (
        #|name = "hello-fn"
        #|
        #|[triggers]
        #|http = { enabled = true }
      ),
    ),
    ("moon.pkg", "pkgtype(kind: \"executable\")\n"),
    ("main.mbt", "fn main {\n  println(\"hello\")\n}\n"),
  ])
  pack_tar_gz(dir)
}

///|
async fn write_test_log(
  data_root : String,
  name : String,
  lines : Array[String],
) -> Unit {
  let dir = data_root + "/logs/" + name
  @fs.mkdir(dir, recursive=true, allow_exist=true) catch {
    _ => ()
  }
  let date = @shared.format_timestamp(@async.now())[:10].to_owned()
  let mut content = ""
  for line in lines {
    content = content + line + "\n"
  }
  @fs.write_file(dir + "/\{date}.log", content)
}

///|
async test "deploy registers the function; list, detail, and logs answer" {
  let data_root = @fs.tmpdir(prefix="moonless-gw-test-")
  let fake = FakeBuilder(
    result=@shared.BuildResult(
      ok=true,
      build_id="b-2001",
      wasm_path="/var/lib/moonless/functions/hello-fn/b-2001/func.wasm",
    ),
    seen_names=[],
  )
  let pkg_dir = @fs.tmpdir(prefix="moonless-gw-fixture-")
  let archive = write_test_package(pkg_dir)
  let builder_port = fixture_listen_port()
  let gateway_port = fixture_listen_port()
  @async.with_task_group(group => {
    let builder_server = @http.Server(
      @socket.Addr::parse("127.0.0.1:\{builder_port}"),
      reuse_addr=true,
    )
    let gateway_server = @http.Server(
      @socket.Addr::parse("127.0.0.1:\{gateway_port}"),
      reuse_addr=true,
    )
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(builder_server, fake_builder_router(fake))
    })
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(
        gateway_server,
        gateway_router(test_config(data_root, builder_port)),
      )
    })
    // deploy
    let payload : Json = {
      "name": "hello-fn",
      "archive": @base64.encode(archive[:]),
    }
    let response = @shared.http_post_json(
      "http://127.0.0.1:\{gateway_port}/api/deploy",
      payload,
      timeout_ms=30_000,
    )
    assert_true(response.stringify().contains("\"ok\":true"))
    assert_eq(fake.seen_names.length(), 1)
    assert_eq(fake.seen_names[0], "hello-fn")
    // registry persisted on disk
    let registry = (@fs.read_file(data_root + "/registry/registry.json") catch {
      _ => raise FixtureError("registry missing")
    }).text() catch {
      _ => raise FixtureError("registry not text")
    }
    assert_true(registry.contains("hello-fn"))
    assert_true(registry.contains("b-2001"))
    // list
    let response = @shared.http_get_json(
      "http://127.0.0.1:\{gateway_port}/api/functions",
    )
    assert_true(response.stringify().contains("hello-fn"))
    // detail
    let response = @shared.http_get_json(
      "http://127.0.0.1:\{gateway_port}/api/functions/hello-fn",
    )
    assert_true(response.stringify().contains("b-2001"))
    let missing = @shared.http_get(
      "http://127.0.0.1:\{gateway_port}/api/functions/ghost",
    )
    assert_eq(missing.status, 404)
    // logs
    write_test_log(data_root, "hello-fn", ["line-one", "line-two", "line-three"])
    let response = @shared.http_get(
      "http://127.0.0.1:\{gateway_port}/api/functions/hello-fn/logs?tail=2",
    )
    assert_eq(response.status, 200)
    assert_eq(response.body, "line-two\nline-three\n")
    let response = @shared.http_get(
      "http://127.0.0.1:\{gateway_port}/api/functions/hello-fn/logs",
    )
    assert_eq(response.body, "line-one\nline-two\nline-three\n")
    builder_server.close()
    gateway_server.close()
  })
}

///|
async test "concurrent deploys never corrupt the registry file" {
  let data_root = @fs.tmpdir(prefix="moonless-gw-test-")
  let cfg = {
    data_root,
    builder_url: "http://127.0.0.1:65534",
    runner_url: "http://127.0.0.1:65534",
    registry_lock: @async.Mutex::Mutex(),
  }
  let path = data_root + "/registry/registry.json"
  let torn_reads : Ref[Int] = Ref(0)
  @async.with_task_group(group => {
    // Reader: every on-disk snapshot must be complete, parseable JSON.
    group.spawn_bg(() => {
      for _ in 0..<100 {
        let content = try @fs.read_file(path) catch {
          _ => None
        } noraise {
          c => Some(c)
        }
        match content {
          Some(data) => {
            let text = data.text() catch { _ => "" }
            if text != "" {
              let parsed = try @json.parse(text) catch {
                _ => None
              } noraise {
                j => Some(j)
              }
              if parsed is None {
                torn_reads.val = torn_reads.val + 1
              }
            }
          }
          None => ()
        }
      }
    })
    // Writers: 12 concurrent deploys through the real mutation path.
    for i in 0..<12 {
      group.spawn_bg(() => {
        registry_set(
          cfg,
          @shared.RegistryRecord(
            name="fn-\{i}",
            manifest=@shared.Manifest(name="fn-\{i}"),
            build_id="b-\{i}",
            updated_at="2026-10-03T00:00:00.000Z",
          ),
        )
      })
    }
  })
  assert_eq(torn_reads.val, 0)
  let records = registry_all(cfg)
  for i in 0..<12 {
    assert_true(records.get("fn-\{i}") is Some(_))
  }
}

///|
// A runner stand-in that records the last RunRequest; functions not in
// the installed list answer like the real runner's unknown-function path.
priv struct FakeRunner {
  mut result : @shared.RunResult
  last_request : Ref[String]
  installed : Ref[Array[String]]
}

///|
fn FakeRunner::FakeRunner(
  result~ : @shared.RunResult,
  last_request~ : Ref[String],
  installed~ : Ref[Array[String]],
) -> FakeRunner {
  { result, last_request, installed, }
}

///|
fn fake_runner_router(fake : FakeRunner) -> @shared.Router {
  let router = @shared.Router::new()
  router.add(
    @shared.route(http_method=@http.Post, pattern="/run", handler=ctx => {
      let request = @shared.read_json_body(ctx)
      fake.last_request.val = request.stringify()
      let name = match request {
        Object(obj) =>
          match obj.get("name") {
            Some(String(n)) => n
            _ => "?"
          }
        _ => "?"
      }
      let installed = fake.installed.val
      let mut known = false
      for entry in installed {
        if entry == name {
          known = true
        }
      }
      if known {
        @shared.send_json(ctx.conn, 200, fake.result.to_json())
      } else {
        @shared.send_json(
          ctx.conn,
          200,
          @shared.RunResult(
            stdout="",
            stderr="unknown function: \{name}",
            exit_code=127,
          ).to_json(),
        )
      }
    }),
  )
  router
}

///|
async test "HTTP trigger builds the event and returns stdout as 200" {
  let runner_port = fixture_listen_port()
  let gateway_port = fixture_listen_port()
  let data_root = @fs.tmpdir(prefix="moonless-gw-test-")
  let fake = FakeRunner(
    result=@shared.RunResult(stdout="hello from fn\n", exit_code=0),
    last_request=Ref(""),
    installed=Ref(["hello-fn"]),
  )
  @async.with_task_group(group => {
    let runner_server = @http.Server(
      @socket.Addr::parse("127.0.0.1:\{runner_port}"),
      reuse_addr=true,
    )
    let gateway_server = @http.Server(
      @socket.Addr::parse("127.0.0.1:\{gateway_port}"),
      reuse_addr=true,
    )
    let cfg : GatewayConfig = {
      data_root,
      builder_url: "http://127.0.0.1:65534",
      runner_url: "http://127.0.0.1:\{runner_port}",
      registry_lock: @async.Mutex::Mutex(),
    }
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(runner_server, fake_runner_router(fake))
    })
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(gateway_server, gateway_router(cfg))
    })
    let (response, _) = @http.post(
      "http://127.0.0.1:\{gateway_port}/fn/hello-fn?x=1",
      "payload-body",
    )
    assert_eq(response.code, 200)
    // The runner saw the http event with method, path, query, and body.
    let seen = fake.last_request.val
    assert_true(seen.contains("\"name\":\"hello-fn\""))
    assert_true(seen.contains("\"source\":\"http\""))
    assert_true(seen.contains("\"method\":\"POST\""))
    assert_true(seen.contains("\"path\":\"/fn/hello-fn\""))
    assert_true(seen.contains("\"query\":\"x=1\""))
    assert_true(seen.contains("\"body\":\"payload-body\""))
    // GET works too (any method is routed).
    fake.result = @shared.RunResult(stdout="got GET\n", exit_code=0)
    let (response, body) = @http.get(
      "http://127.0.0.1:\{gateway_port}/fn/hello-fn",
    )
    assert_eq(response.code, 200)
    assert_eq(body.text(), "got GET\n")
    // Unknown functions map to 404 (the fake runner answers 127/unknown
    // for anything not installed).
    let (response, _) = @http.get("http://127.0.0.1:\{gateway_port}/fn/ghost")
    assert_eq(response.code, 404)
    runner_server.close()
    gateway_server.close()
  })
}

///|
async test "synthetic s3 and cron events dispatch to bound functions only" {
  let data_root = @fs.tmpdir(prefix="moonless-gw-test-")
  let cfg : GatewayConfig = {
    data_root,
    builder_url: "http://127.0.0.1:65534",
    runner_url: "http://127.0.0.1:65534",
    registry_lock: @async.Mutex::Mutex(),
  }
  // Three functions: bound to uploads/put, bound to another bucket, cron.
  registry_set(
    cfg,
    @shared.RegistryRecord(
      name="on-upload",
      manifest=@shared.Manifest(
        name="on-upload",
        triggers=@shared.ManifestTriggers(
          s3=@shared.S3Trigger(bucket="uploads", events=["put", "delete"]),
        ),
      ),
      build_id="b-1",
      updated_at="2026-10-03T00:00:00.000Z",
    ),
  )
  registry_set(
    cfg,
    @shared.RegistryRecord(
      name="on-other-bucket",
      manifest=@shared.Manifest(
        name="on-other-bucket",
        triggers=@shared.ManifestTriggers(
          s3=@shared.S3Trigger(bucket="archive", events=["put"]),
        ),
      ),
      build_id="b-2",
      updated_at="2026-10-03T00:00:00.000Z",
    ),
  )
  registry_set(
    cfg,
    @shared.RegistryRecord(
      name="nightly",
      manifest=@shared.Manifest(
        name="nightly",
        triggers=@shared.ManifestTriggers(cron="0 8 * * *"),
      ),
      build_id="b-3",
      updated_at="2026-10-03T00:00:00.000Z",
    ),
  )
  let dispatched : Array[String] = []
  let runner_port = fixture_listen_port()
  let gateway_port = fixture_listen_port()
  let runner = @shared.Router::new()
  runner.add(
    @shared.route(http_method=@http.Post, pattern="/run", handler=ctx => {
      let request = @shared.read_json_body(ctx)
      guard request is Object(obj) else { return }
      guard obj.get("name") is Some(String(name)) else { return }
      dispatched.push(name)
      @shared.send_json(
        ctx.conn,
        200,
        @shared.RunResult(stdout="ran \{name}\n", exit_code=0).to_json(),
      )
    }),
  )
  @async.with_task_group(group => {
    let runner_server = @http.Server(
      @socket.Addr::parse("127.0.0.1:\{runner_port}"),
      reuse_addr=true,
    )
    let gateway_server = @http.Server(
      @socket.Addr::parse("127.0.0.1:\{gateway_port}"),
      reuse_addr=true,
    )
    group.spawn_bg(no_wait=true, () => @shared.serve_on(runner_server, runner))
    let gateway_cfg : GatewayConfig = {
      data_root,
      builder_url: "http://127.0.0.1:65534",
      runner_url: "http://127.0.0.1:\{runner_port}",
      registry_lock: @async.Mutex::Mutex(),
    }
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(gateway_server, gateway_router(gateway_cfg))
    })
    // A put on uploads fires only on-upload.
    let s3_event : Json = {
      "source": "s3",
      "event": "put",
      "bucket": "uploads",
      "key": "report.csv",
    }
    let response = @shared.http_post_json(
      "http://127.0.0.1:\{gateway_port}/api/events",
      s3_event,
    )
    assert_true(response.stringify().contains("on-upload"))
    assert_eq(dispatched.length(), 1)
    assert_eq(dispatched[0], "on-upload")
    // A cron event fires only the cron-bound function.
    dispatched.clear()
    let cron_event : Json = {
      "source": "cron",
      "schedule": "0 8 * * *",
      "time": "2026-10-03T08:00:00Z",
    }
    let response = @shared.http_post_json(
      "http://127.0.0.1:\{gateway_port}/api/events",
      cron_event,
    )
    assert_true(response.stringify().contains("nightly"))
    assert_eq(dispatched.length(), 1)
    assert_eq(dispatched[0], "nightly")
    // A put on the unbound bucket triggers nothing.
    dispatched.clear()
    let s3_event : Json = {
      "source": "s3",
      "event": "put",
      "bucket": "unwatched",
      "key": "x",
    }
    let response = @shared.http_post_json(
      "http://127.0.0.1:\{gateway_port}/api/events",
      s3_event,
    )
    assert_eq(response.stringify(), "[]")
    assert_eq(dispatched.length(), 0)
    runner_server.close()
    gateway_server.close()
  })
}

///|
async test "broken deploy surfaces the reason; a good deploy is callable" {
  let data_root = @fs.tmpdir(prefix="moonless-gw-test-")
  let fake_builder = FakeBuilder(
    result=@shared.BuildResult(
      ok=false,
      error_tail="Error: unresolved identifier totally_broken (main.mbt:3)",
    ),
    seen_names=[],
  )
  let fake_runner = FakeRunner(
    result=@shared.RunResult(stdout="hello from fn\n", exit_code=0),
    last_request=Ref(""),
    installed=Ref([]),
  )
  let pkg_dir = @fs.tmpdir(prefix="moonless-gw-fixture-")
  let archive = write_test_package(pkg_dir)
  let builder_port = fixture_listen_port()
  let runner_port = fixture_listen_port()
  let gateway_port = fixture_listen_port()
  @async.with_task_group(group => {
    let builder_server = @http.Server(
      @socket.Addr::parse("127.0.0.1:\{builder_port}"),
      reuse_addr=true,
    )
    let runner_server = @http.Server(
      @socket.Addr::parse("127.0.0.1:\{runner_port}"),
      reuse_addr=true,
    )
    let gateway_server = @http.Server(
      @socket.Addr::parse("127.0.0.1:\{gateway_port}"),
      reuse_addr=true,
    )
    let cfg : GatewayConfig = {
      data_root,
      builder_url: "http://127.0.0.1:\{builder_port}",
      runner_url: "http://127.0.0.1:\{runner_port}",
      registry_lock: @async.Mutex::Mutex(),
    }
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(builder_server, fake_builder_router(fake_builder))
    })
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(runner_server, fake_runner_router(fake_runner))
    })
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(gateway_server, gateway_router(cfg))
    })
    let payload : Json = {
      "name": "hello-fn",
      "archive": @base64.encode(archive[:]),
    }
    // Broken build: the reason propagates and nothing is registered.
    let response = @shared.http_post_json(
      "http://127.0.0.1:\{gateway_port}/api/deploy",
      payload,
    )
    let text = response.stringify()
    assert_true(text.contains("\"ok\":false"))
    assert_true(text.contains("totally_broken"))
    let not_callable = @shared.http_get(
      "http://127.0.0.1:\{gateway_port}/fn/hello-fn",
    )
    assert_eq(not_callable.status, 404)
    // Good build: registered and callable through the trigger. The runner
    // now knows the function (the builder stored its module).
    fake_builder.result = @shared.BuildResult(
      ok=true,
      build_id="b-3001",
      wasm_path="/var/lib/moonless/functions/hello-fn/b-3001/func.wasm",
    )
    fake_runner.installed.val = ["hello-fn"]
    let response = @shared.http_post_json(
      "http://127.0.0.1:\{gateway_port}/api/deploy",
      payload,
    )
    assert_true(response.stringify().contains("\"ok\":true"))
    let callable = @shared.http_get(
      "http://127.0.0.1:\{gateway_port}/fn/hello-fn",
    )
    assert_eq(callable.status, 200)
    assert_eq(callable.body, "hello from fn\n")
    builder_server.close()
    runner_server.close()
    gateway_server.close()
  })
}
