///|
// CLI deploy tests: validation errors, packaging rules, and the upload
// round-trip against a fake gateway.

///|
#derive(Debug)
priv suberror FixtureError {
  FixtureError(String)
}

///|
// Bind an ephemeral port so concurrent tests never collide.
async fn fixture_server() -> (@http.Server, Int32) {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"), reuse_addr=true)
  (server, server.addr.port())
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
  try
    cli_deploy("http://127.0.0.1:65534", dir=empty_dir, out=CliOut::capture())
  catch {
    CliError(message) => assert_true(message.contains("not a MoonBit project"))
  } noraise {
    _ => fail("expected failure for missing moon.mod")
  }
  let no_manifest_dir = @fs.tmpdir(prefix="moonless-cli-fixture-")
  write_fixture_files(no_manifest_dir, [
    ("moon.mod", "name = \"x\"\nversion = \"0.1.0\"\n"),
    ("main.mbt", "fn main {\n}\n"),
  ])
  try
    cli_deploy(
      "http://127.0.0.1:65534",
      dir=no_manifest_dir,
      out=CliOut::capture(),
    )
  catch {
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
    ("README.mbt.md", "# fixture"),
  ])
  @fs.symlink(target="README.mbt.md", dir + "/README.md")
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
  assert_false(has_path(names, "README.md"))
  assert_true(has_path(names, "README.mbt.md"))
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
  let (server, port) = fixture_server()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(server, fake_gateway_router(fake))
    })
    let out = CliOut::capture()
    cli_deploy("http://127.0.0.1:\{port}", dir~, out~)
    assert_true(out.text().contains("deployed hello-fn"))
    assert_eq(fake.last_name.val, "hello-fn")
    server.close()
  })
}

///|
test "render_function_table matches registry state" {
  let records : Array[@shared.RegistryRecord] = [
    @shared.RegistryRecord(
      name="hello",
      manifest=@shared.Manifest(
        name="hello",
        triggers=@shared.ManifestTriggers(http_enabled=true),
      ),
      build_id="b-100",
      updated_at="2026-10-03T01:00:00.000Z",
    ),
    @shared.RegistryRecord(
      name="resize",
      manifest=@shared.Manifest(
        name="resize",
        triggers=@shared.ManifestTriggers(
          cron="0 8 * * *",
          s3=@shared.S3Trigger(bucket="uploads", events=["put", "delete"]),
        ),
      ),
      build_id="b-200",
      updated_at="2026-10-03T02:00:00.000Z",
    ),
  ]
  let table = render_function_table(records)
  assert_true(table.has_prefix("NAME"))
  assert_true(table.contains("hello"))
  assert_true(table.contains("http"))
  assert_true(table.contains("resize"))
  assert_true(table.contains("cron(0 8 * * *)"))
  assert_true(table.contains("s3(uploads:put,delete)"))
  assert_true(table.contains("b-100"))
  assert_true(table.contains("b-200"))
  let quiet_table = render_function_table(records, quiet=true)
  assert_false(quiet_table.contains("NAME"))
  assert_true(quiet_table.has_prefix("hello"))
  assert_true(quiet_table.contains("resize"))
  assert_eq(render_function_table([]), "no functions deployed\n")
  assert_eq(render_function_table([], quiet=true), "")
}

///|
test "parse_list_quiet handles q and server flags" {
  assert_false(parse_list_quiet([]))
  assert_true(parse_list_quiet(["-q"]))
  assert_true(parse_list_quiet(["--server", "http://x:1", "-q"]))
  try parse_list_quiet(["--unknown"]) catch {
    CliError(message) => assert_true(message.contains("unexpected argument"))
  } noraise {
    _ => fail("expected failure for an unknown list flag")
  }
}

///|
test "parse_logs_args handles name, tail, and server flags" {
  let parsed = parse_logs_args(["hello", "--tail", "10"])
  assert_eq(parsed.name, "hello")
  assert_eq(parsed.tail, 10)
  let parsed = parse_logs_args(["--server", "http://x:1", "hello", "--tail=5"])
  assert_eq(parsed.name, "hello")
  assert_eq(parsed.tail, 5)
  let parsed = parse_logs_args(["hello"])
  assert_eq(parsed.tail, 50)
  assert_eq(parsed.source, "")
  assert_eq(parsed.since, "")
  let parsed = parse_logs_args([
    "hello", "--source", "cron", "--since=2026-10-16T08:00:00Z",
  ])
  assert_eq(parsed.source, "cron")
  assert_eq(parsed.since, "2026-10-16T08:00:00Z")
  let parsed = parse_logs_args(["--source=s3", "hello"])
  assert_eq(parsed.source, "s3")
  assert_false(parsed.follow)
  let parsed = parse_logs_args(["hello", "--follow"])
  assert_true(parsed.follow)
  try parse_logs_args(["hello", "--source", "ftp"]) catch {
    CliError(message) => assert_true(message.contains("--source must be"))
  } noraise {
    _ => fail("expected error for an unknown source")
  }
  try parse_logs_args(["--tail", "10"]) catch {
    CliError(message) => assert_true(message.contains("usage"))
  } noraise {
    _ => fail("expected usage error for missing name")
  }
  try parse_logs_args(["a", "b"]) catch {
    CliError(message) => assert_true(message.contains("unexpected argument"))
  } noraise {
    _ => fail("expected error for extra positional")
  }
}

///|
test "follow_delta emits only newly appended log records" {
  assert_eq(follow_delta("", "first\n"), "first\n")
  assert_eq(follow_delta("first\n", "first\n"), "")
  assert_eq(follow_delta("first\n", "first\nsecond\n"), "second\n")
  assert_eq(follow_delta("old\nshared\n", "shared\nnew\n"), "new\n")
  assert_eq(follow_delta("same\ntext\n", ""), "")
}

///|
test "parse_runs_args handles name and tail" {
  let parsed = parse_runs_args(["hello"])
  assert_eq(parsed.name, "hello")
  assert_eq(parsed.tail, 20)
  let parsed = parse_runs_args(["hello", "--tail", "5"])
  assert_eq(parsed.tail, 5)
  let parsed = parse_runs_args(["--tail=7", "hello"])
  assert_eq(parsed.tail, 7)
  try parse_runs_args(["--tail", "5"]) catch {
    CliError(message) => assert_true(message.contains("usage"))
  } noraise {
    _ => fail("expected usage error for missing name")
  }
  try parse_runs_args(["a", "b"]) catch {
    CliError(message) => assert_true(message.contains("unexpected argument"))
  } noraise {
    _ => fail("expected error for extra positional")
  }
}

///|
test "render_runs_table shows run metadata in columns" {
  let items : Array[Json] = [
    {
      "ts": "2026-10-16T09:00:00.000Z",
      "name": "hello",
      "source": "cron",
      "exitCode": 1,
      "durationMs": 870,
      "truncated": false,
    },
    {
      "ts": "2026-10-17T08:00:00.000Z",
      "name": "hello",
      "source": "http",
      "exitCode": 0,
      "durationMs": 12,
      "truncated": true,
    },
  ]
  let table = render_runs_table(items)
  assert_true(table.contains("TIME"))
  assert_true(table.contains("SOURCE"))
  assert_true(table.contains("2026-10-16T09:00:00.000Z"))
  assert_true(table.contains("cron"))
  assert_true(table.contains("870ms"))
  assert_true(table.contains("2026-10-17T08:00:00.000Z"))
  assert_true(table.contains("http"))
  assert_eq(render_runs_table([]), "no runs recorded\n")
}

///|
async test "error UX: server unreachable prints an actionable hint" {
  // Port 1 on localhost refuses connections quickly; the project must be
  // valid so the failure comes from the upload step.
  let project_dir = @fs.tmpdir(prefix="moonless-cli-fixture-")
  write_fixture_files(project_dir, good_project_files())
  try
    cli_deploy("http://127.0.0.1:1", dir=project_dir, out=CliOut::capture())
  catch {
    CliError(message) => {
      assert_true(message.contains("cannot reach the moonless server"))
      assert_true(message.contains("hint"))
    }
  } noraise {
    _ => fail("expected failure for unreachable server")
  }
  try cli_list([], "http://127.0.0.1:1", out=CliOut::capture()) catch {
    CliError(message) => assert_true(message.contains("cannot reach"))
  } noraise {
    _ => fail("expected failure for unreachable server")
  }
}

///|
async test "error UX: validation errors carry hints, not stack traces" {
  let empty_dir = @fs.tmpdir(prefix="moonless-cli-fixture-")
  try
    cli_deploy("http://127.0.0.1:1", dir=empty_dir, out=CliOut::capture())
  catch {
    CliError(message) => {
      assert_true(message.contains("not a MoonBit project"))
      assert_true(message.contains("hint"))
      assert_false(message.contains("Error: ["))
    }
  } noraise {
    _ => fail("expected failure for non-project")
  }
  let no_manifest = @fs.tmpdir(prefix="moonless-cli-fixture-")
  write_fixture_files(no_manifest, [
    ("moon.mod", "name = \"x\"\nversion = \"0.1.0\"\n"),
  ])
  try
    cli_deploy("http://127.0.0.1:1", dir=no_manifest, out=CliOut::capture())
  catch {
    CliError(message) => {
      assert_true(message.contains("missing moonless.toml"))
      assert_true(message.contains("hint"))
    }
  } noraise {
    _ => fail("expected failure for missing manifest")
  }
}

///|
async test "logs follow waits when no logs exist yet" {
  let (server, port) = fixture_server()
  let requests = Ref(0)
  @async.with_task_group(group => {
    let router = @shared.Router::new()
    router.add(
      @shared.route(
        http_method=@http.Get,
        pattern="/api/functions/:name/logs",
        handler=ctx => {
          requests.val += 1
          if requests.val == 1 {
            @shared.send_text(ctx.conn, 404, "no logs")
          } else {
            @shared.send_text(ctx.conn, 200, "first log\n")
          }
        },
      ),
    )
    group.spawn_bg(no_wait=true, () => @shared.serve_on(server, router))
    let out = CliOut::capture()
    try
      @async.with_timeout(
        2500,
        () => cli_logs(["hello", "--follow"], "http://127.0.0.1:\{port}", out~),
        error=FixtureError("follow timeout"),
      )
    catch {
      FixtureError(_) => ()
      CliError(message) => fail("follow exited early: \{message}")
      _ => fail("follow failed unexpectedly")
    } noraise {
      _ => fail("follow exited without new logs")
    }
    assert_true(requests.val >= 2)
    assert_true(out.text().contains("first log"))
    server.close()
  })
}

///|
async test "error UX: unknown function hints at list and trigger" {
  let (server, port) = fixture_server()
  @async.with_task_group(group => {
    let router = @shared.Router::new()
    router.add(
      @shared.route(
        http_method=@http.Get,
        pattern="/api/functions/:name/logs",
        handler=ctx => @shared.send_text(ctx.conn, 404, "no logs"),
      ),
    )
    group.spawn_bg(no_wait=true, () => @shared.serve_on(server, router))
    try
      cli_logs(["ghost"], "http://127.0.0.1:\{port}", out=CliOut::capture())
    catch {
      CliError(message) => {
        assert_true(message.contains("no logs for function 'ghost'"))
        assert_true(message.contains("moonless list"))
      }
    } noraise {
      _ => fail("expected failure for unknown function")
    }
    server.close()
  })
}
