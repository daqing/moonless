///|
// `moonless deploy`: validate the project, make sure dependencies are
// vendored, pack a tar.gz (sources + .mooncakes, no _build or dotfiles),
// upload it, and report the server-side build outcome.

///|
async fn cli_deploy(
  server : String,
  dir~ : String = "",
  out~ : CliOut = CliOut::stdout(),
) -> Unit raise CliError {
  let dir = if dir == "" {
    match @env.current_dir() {
      Some(d) => d
      None => raise CliError("cannot determine the current directory")
    }
  } else {
    dir
  }
  let has_mod = @fs.exists(dir + "/moon.mod") catch { _ => false }
  let has_manifest = @fs.exists(dir + "/moonless.toml") catch { _ => false }
  if !has_mod && !has_manifest {
    raise CliError(
      "not a MoonBit project: no moon.mod in \{dir}\n(hint: use a MoonBit project or set binary explicitly)",
    )
  }
  let manifest_source = read_text_file(dir + "/moonless.toml") catch {
    _ =>
      raise CliError(
        "missing moonless.toml in \{dir}\n(hint: add one at the function project root, e.g. name = \"hello-fn\")",
      )
  }
  let manifest = @shared.parse_manifest(manifest_source) catch {
    @shared.InvalidManifest(message) =>
      raise CliError("invalid moonless.toml: \{message}")
    err => raise CliError("invalid moonless.toml: \{@debug.to_string(err)}")
  }
  if manifest.binary is None {
    if !has_mod {
      raise CliError(
        "not a MoonBit project: no moon.mod in \{dir}\n(hint: use a MoonBit project or set binary explicitly)",
      )
    }
    ensure_vendored_deps(dir, out~)
  }
  out.write("packaging \{manifest.name} ...\n")
  let archive = pack_project(dir)
  out.write("uploading to \{server} ...\n")
  let payload = @shared.DeployRequest(
    name=manifest.name,
    archive=@base64.encode(archive[:]),
  ).to_json()
  let response = @shared.http_post_json(
    server + "/api/deploy",
    payload,
    timeout_ms=300_000,
  ) catch {
    _ =>
      raise CliError(
        "cannot reach the moonless server at \{server}\n(hint: is the stack running? try 'docker compose up -d')",
      )
  }
  let result = @shared.BuildResult::from_json(response) catch {
    _ => raise CliError("the server sent an unreadable build result")
  }
  if result.ok {
    out.write("deployed \{manifest.name} (build \{result.build_id})\n")
    if manifest.triggers.http_enabled {
      out.write("trigger over HTTP at \{server}/fn/\{manifest.name}\n")
    }
  } else {
    raise CliError("build failed on the server:\n\{result.error_tail}")
  }
}

///|
// R2: dependencies must travel inside the package so the builder never
// needs network. If moon.mod declares imports but .mooncakes is absent,
// resolve them locally first (moon check fetches into .mooncakes).
async fn ensure_vendored_deps(
  dir : String,
  out~ : CliOut = CliOut::stdout(),
) -> Unit raise CliError {
  let has_mooncakes = @fs.exists(dir + "/.mooncakes") catch { _ => false }
  if has_mooncakes {
    return
  }
  let moon_mod = read_text_file(dir + "/moon.mod") catch { _ => "" }
  if !moon_mod.contains("import") {
    return
  }
  out.write("resolving dependencies locally (moon check) ...\n")
  let (code, _, stderr) = @process.collect_output("moon", ["check"], cwd=dir[:]) catch {
    _ => raise CliError("failed to run 'moon check' locally")
  }
  if code != 0 {
    let output = stderr.text() catch { _ => "" }
    raise CliError(
      "dependency resolution failed (moon check exited \{code}):\n\{output}",
    )
  }
}

///|
// Packs the project with the system tar: everything except _build/ and
// dotfiles — .mooncakes stays, it is the vendored dependency cache. The
// generated README.md symlink is omitted; the builder accepts only regular
// files and directories, and never follows symlinks.
async fn pack_project(dir : String) -> Bytes raise CliError {
  let out_dir = @fs.tmpdir(prefix="moonless-deploy-") catch {
    _ => raise CliError("cannot create a temp directory")
  }
  let tgz = out_dir + "/package.tar.gz"
  let args : Array[String] = ["--format=ustar", "-czf", tgz]
  let entries = @fs.readdir(dir) catch {
    _ => raise CliError("cannot list \{dir}")
  }
  for entry in entries {
    if entry.has_prefix(".") && entry != ".mooncakes" {
      args.push("--exclude=./" + entry)
    }
  }
  args.push("--exclude=./_build")
  let readme_kind = @fs.kind(dir + "/README.md", follow_symlink=false) catch {
    _ => @fs.FileKind::Unknown
  }
  if readme_kind == @fs.FileKind::SymLink {
    args.push("--exclude=./README.md")
  }
  args.push("-C")
  args.push(dir)
  args.push(".")
  let (code, _, stderr) = @process.collect_output("tar", args) catch {
    _ => raise CliError("failed to run tar for packaging")
  }
  if code != 0 {
    let output = stderr.text() catch { _ => "" }
    raise CliError("packaging failed (tar exited \{code}):\n\{output}")
  }
  read_bytes_file(tgz) catch {
    _ => raise CliError("packaged archive is unreadable")
  }
}

///|
async fn read_text_file(path : String) -> String raise CliError {
  let content = read_bytes_file(path) catch {
    _ => raise CliError("cannot read \{path}")
  }
  @utf8.decode_lossy(content[:])
}

///|
async fn read_bytes_file(path : String) -> Bytes raise CliError {
  (@fs.read_file(path) catch { _ => raise CliError("cannot read \{path}") }).binary()
}
