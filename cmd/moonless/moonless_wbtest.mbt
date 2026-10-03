///|
// CLI deploy tests: validation errors, packaging rules, and the upload
// round-trip against a fake gateway.

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
    None => 18_477
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
fn good_project_files() -> Array[(String, String)] {
  [
    ("moon.mod", "name = \"cli/hello-fn\"\nversion = \"0.1.0\"\n"),
    ("moonless.toml", "name = \"hello-fn\"\n"),
    ("moon.pkg", "pkgtype(kind: \"executable\")\n"),
    ("main.mbt", "fn main {\n  println(\"hello\")\n}\n"),
  ]
}

///|
async test "deploy rejects non-projects and missing manifests" {
  let empty_dir = @fs.tmpdir(prefix="moonless-cli-fixture-")
  try cli_deploy("http://127.0.0.1:65534", dir=empty_dir) catch {
    CliError(message) => assert_true(message.contains("not a MoonBit project"))
  } noraise {
    _ => fail("expected failure for missing moon.mod")
  }
  let no_manifest_dir = @fs.tmpdir(prefix="moonless-cli-fixture-")
  write_fixture_files(no_manifest_dir, [
    ("moon.mod", "name = \"x\"\nversion = \"0.1.0\"\n"),
    ("main.mbt", "fn main {\n}\n"),
  ])
  try cli_deploy("http://127.0.0.1:65534", dir=no_manifest_dir) catch {
    CliError(message) => assert_true(message.contains("moonless.toml"))
  } noraise {
    _ => fail("expected failure for missing moonless.toml")
  }
}

///|
async test "pack_project keeps .mooncakes, drops _build and dotfiles" {
  let dir = @fs.tmpdir(prefix="moonless-cli-fixture-")
  write_fixture_files(dir, good_project_files())
  write_fixture_files(dir, [
    ("_build/junk/wasm.wasm", "junkjunk"),
    (".git/config", "[core]"),
    (".DS_Store", "junk"),
    (".mooncakes/somelib/lib.mbt", "pub fn x() -> Int { 1 }"),
  ])
  let archive = pack_project(dir)
  let names : Array[String] = []
  for entry in @shared.tar_entries(@shared.gunzip(archive)) {
    if !entry.is_dir {
      names.push(entry.path)
    }
  }
  assert_true(has_path(names, "moon.mod"))
  assert_true(has_path(names, "moonless.toml"))
  assert_true(has_path(names, ".mooncakes/somelib/lib.mbt"))
  assert_false(has_path(names, "_build/junk/wasm.wasm"))
  assert_false(has_path(names, ".git/config"))
  assert_false(has_path(names, ".DS_Store"))
}

///|
fn has_path(names : Array[String], path : String) -> Bool {
  for name in names {
    if name == path {
      return true
    }
  }
  false
}

///|
priv struct FakeGateway {
  deploy_result : @shared.BuildResult
  last_name : Ref[String]
}

///|
fn FakeGateway::FakeGateway(
  deploy_result~ : @shared.BuildResult,
  last_name~ : Ref[String],
) -> FakeGateway {
  { deploy_result, last_name, }
}

///|
fn fake_gateway_router(fake : FakeGateway) -> @shared.Router {
  let router = @shared.Router::new()
  router.add(
    @shared.route(http_method=@http.Post, pattern="/api/deploy", handler=ctx => {
      let request = @shared.DeployRequest::from_json(
        @shared.read_json_body(ctx),
      )
      fake.last_name.val = request.name
      @shared.send_json(ctx.conn, 200, fake.deploy_result.to_json())
    }),
  )
  router
}

///|
async test "deploy uploads the package and reports success" {
  let dir = @fs.tmpdir(prefix="moonless-cli-fixture-")
  write_fixture_files(dir, good_project_files())
  let fake = FakeGateway(
    deploy_result=@shared.BuildResult(ok=true, build_id="b-6001"),
    last_name=Ref(""),
  )
  let port = fixture_listen_port()
  @async.with_task_group(group => {
    let server = @http.Server(
      @socket.Addr::parse("127.0.0.1:\{port}"),
      reuse_addr=true,
    )
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(server, fake_gateway_router(fake))
    })
    cli_deploy("http://127.0.0.1:\{port}", dir~)
    assert_eq(fake.last_name.val, "hello-fn")
    server.close()
  })
}
