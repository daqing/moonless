///|
// Fixture helpers: lay out a function project in a temp dir and pack it
// with the system tar (ustar format), the same shape `moonless deploy`
// will upload.

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
          _ => ()
        }
      None => ()
    }
    @fs.write_file(full, content)
  }
}

///|
async fn pack_tar_gz(dir : String) -> Bytes {
  // Pack into a dedicated output dir: tmpdirs are siblings, so "<dir>/.."
  // is shared and parallel tests would clobber each other's archive.
  let out_dir = @fs.tmpdir(prefix="moonless-pkg-")
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
async test "run_build accepts a valid package and rejects missing files" {
  let data_root = @fs.tmpdir(prefix="moonless-builder-test-")
  let fixture_dir = @fs.tmpdir(prefix="moonless-fixture-")
  let good_files : Array[(String, String)] = [
    (
      "moon.mod",
      (
        #|name = "fixture/hello-fn"
        #|version = "0.1.0"
      ),
    ),
    (
      "moonless.toml",
      (
        #|name = "hello-fn"
        #|
        #|[triggers]
        #|http = { enabled = true }
      ),
    ),
    (
      "moon.pkg",
      (
        #|import {
        #|  "moonbitlang/core/env",
        #|}
        #|
        #|pkgtype(kind: "executable")
      ),
    ),
    (
      "main.mbt",
      (
        #|fn main {
        #|  match @env.get_env_var("MOONLESS_EVENT") {
        #|    Some(event) => println("hello! triggered by: \{event}")
        #|    None => println("hello!")
        #|  }
        #|}
      ),
    ),
  ]
  write_fixture_files(fixture_dir, good_files)
  let archive = pack_tar_gz(fixture_dir)
  let result = run_build("hello-fn", @base64.encode(archive[:]), data_root)
  assert_eq(result.ok, true)
  // The toolchain actually ran and the artifact is stored in the layout
  // the runner will read, with metadata next to it.
  assert_eq(
    result.wasm_path,
    data_root + "/functions/hello-fn/" + result.build_id + "/func.wasm",
  )
  assert_true(@fs.exists(result.wasm_path))
  let wasm_module = (@fs.read_file(result.wasm_path) catch {
    _ => raise FixtureError("wasm module unreadable")
  }).binary()
  assert_eq(wasm_module.length() > 4, true)
  assert_eq(wasm_module[0], b'\x00')
  assert_eq(wasm_module[1], b'a')
  assert_eq(wasm_module[2], b's')
  assert_eq(wasm_module[3], b'm')
  let metadata_path = data_root +
    "/functions/hello-fn/" +
    result.build_id +
    "/build.json"
  let metadata = (@fs.read_file(metadata_path) catch {
    _ => raise FixtureError("build.json missing")
  }).text() catch {
    _ => raise FixtureError("build.json not text")
  }
  assert_true(metadata.contains("\"ok\":true"))
  assert_true(metadata.contains("func.wasm"))

  // Same package without moonless.toml must be rejected.
  let broken_dir = @fs.tmpdir(prefix="moonless-fixture-")
  write_fixture_files(broken_dir, [good_files[0], good_files[2], good_files[3]])
  let archive = pack_tar_gz(broken_dir)
  let result = run_build("hello-fn", @base64.encode(archive[:]), data_root)
  assert_eq(result.ok, false)
  assert_true(result.error_tail.contains("moonless.toml"))

  // A package without moon.mod is rejected too.
  let no_mod_dir = @fs.tmpdir(prefix="moonless-fixture-")
  write_fixture_files(no_mod_dir, [good_files[1], good_files[3]])
  let archive = pack_tar_gz(no_mod_dir)
  let result = run_build("hello-fn", @base64.encode(archive[:]), data_root)
  assert_eq(result.ok, false)
  assert_true(result.error_tail.contains("moon.mod"))

  // Manifest name mismatch is rejected.
  let archive = pack_tar_gz(fixture_dir)
  let result = run_build("other-name", @base64.encode(archive[:]), data_root)
  assert_eq(result.ok, false)
  assert_true(result.error_tail.contains("does not match"))
}

///|
async test "POST /build answers over HTTP with a BuildResult" {
  let fixture_dir = @fs.tmpdir(prefix="moonless-fixture-")
  write_fixture_files(fixture_dir, [
    ("moon.mod", "name = \"fixture/echo-fn\"\nversion = \"0.1.0\"\n"),
    ("moonless.toml", "name = \"echo-fn\"\n"),
    ("moon.pkg", "pkgtype(kind: \"executable\")\n"),
    ("main.mbt", "fn main {\n  println(\"echo\")\n}\n"),
  ])
  let archive = pack_tar_gz(fixture_dir)
  let data_root = @fs.tmpdir(prefix="moonless-builder-test-")
  @async.with_task_group(group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:18474"))
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(server, builder_router())
    })
    // The handler reads MOONLESS_DATA for its root; the env var is process
    // wide, so point it at the test root before the request.
    @env.set_env_var("MOONLESS_DATA", data_root)
    let payload : Json = {
      "name": "echo-fn",
      "archive": @base64.encode(archive[:]),
    }
    let response = @shared.http_post_json(
      "http://127.0.0.1:18474/build", payload,
    )
    assert_true(response.stringify().contains("\"ok\":true"))
    @env.unset_env_var("MOONLESS_DATA")
    server.close()
  })
}
