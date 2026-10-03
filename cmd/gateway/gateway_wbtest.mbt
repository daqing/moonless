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
  result : @shared.BuildResult
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
