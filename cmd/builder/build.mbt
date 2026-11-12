///|
// The build pipeline: decode the uploaded archive, unpack it into an
// isolated work dir, validate the project, then hand off to the toolchain.

///|
fn builder_data_dir() -> String {
  @env.get_env_var("MOONLESS_DATA").unwrap_or("/var/lib/moonless")
}

///|
fn build_failed(message : String) -> @shared.BuildResult {
  @shared.BuildResult(ok=false, error_tail=message)
}

///|
async fn run_build(
  name : String,
  archive_b64 : String,
  data_root : String,
) -> @shared.BuildResult {
  build_steps(name, archive_b64, data_root) catch {
    @shared.InvalidArchive(message) => build_failed(message)
    @shared.InvalidManifest(message) => build_failed(message)
    err => build_failed(@debug.to_string(err))
  }
}

///|
async fn build_steps(
  name : String,
  archive_b64 : String,
  data_root : String,
) -> @shared.BuildResult raise @shared.SharedError {
  let build_id = "b-" + @async.now().to_string()
  let src_dir = data_root + "/builds/" + build_id + "/src"
  let archive = @base64.decode(archive_b64[:]) catch {
    _ => raise @shared.InvalidArchive("archive is not valid base64")
  }
  let files = extract_tar_gz(archive, src_dir)
  if !has_entry(files, "moonless.toml") {
    raise @shared.InvalidArchive("package is missing moonless.toml")
  }
  let manifest_source = (@fs.read_file(src_dir + "/moonless.toml") catch {
    err =>
      raise @shared.InvalidArchive(
        "failed to read moonless.toml: \{@debug.to_string(err)}",
      )
  }).text() catch {
    _ => raise @shared.InvalidArchive("moonless.toml is not UTF-8 text")
  }
  let manifest = @shared.parse_manifest(manifest_source)
  if manifest.name != name {
    raise @shared.InvalidArchive(
      "manifest name \{manifest.name} does not match deploy name \{name}",
    )
  }
  if !has_entry(files, "moon.mod") {
    raise @shared.InvalidArchive("package is missing moon.mod")
  }
  let (code, _, stderr) = @process.collect_output(
    "moon",
    ["build", "--target", "wasm"],
    cwd=src_dir[:],
  ) catch {
    err =>
      raise @shared.InvalidArchive(
        "failed to run moon: \{@debug.to_string(err)}",
      )
  }
  if code != 0 {
    let output = stderr.text() catch { _ => "" }
    return @shared.BuildResult(ok=false, error_tail=tail(output, 2000))
  }
  let source_path = find_wasm_module(src_dir)
  store_artifact(
    data_root,
    name,
    build_id,
    source_path,
    policy_path=match manifest.sandbox {
      Some(path) => src_dir + "/" + path
      None => ""
    },
  )
}

///|
async fn store_artifact(
  data_root : String,
  name : String,
  build_id : String,
  source_path : String,
  policy_path~ : String,
) -> @shared.BuildResult raise @shared.SharedError {
  let artifact_dir = data_root + "/functions/" + name + "/" + build_id
  mkdir_recursive(artifact_dir)
  let artifact = artifact_dir + "/func.wasm"
  let bytes = (@fs.read_file(source_path) catch {
    err =>
      raise @shared.InvalidArchive(
        "failed to read function artifact: \{@debug.to_string(err)}",
      )
  }).binary()
  @fs.write_file(artifact, bytes[:]) catch {
    err =>
      raise @shared.InvalidArchive(
        "failed to store artifact: \{@debug.to_string(err)}",
      )
  }
  if policy_path != "" {
    let policy = (@fs.read_file(policy_path) catch {
      err =>
        raise @shared.InvalidArchive(
          "failed to read sandbox policy: \{@debug.to_string(err)}",
        )
    }).text() catch {
      _ => raise @shared.InvalidArchive("sandbox policy is not UTF-8 text")
    }
    let parsed = @json.parse(policy) catch {
      _ => raise @shared.InvalidArchive("sandbox policy is not valid JSON")
    }
    if !(parsed is Object(_)) {
      raise @shared.InvalidArchive("sandbox policy must be a JSON object")
    }
    @fs.write_file(artifact_dir + "/policy.json", policy) catch {
      err =>
        raise @shared.InvalidArchive(
          "failed to store sandbox policy: \{@debug.to_string(err)}",
        )
    }
  }
  let result = @shared.BuildResult(ok=true, build_id~, wasm_path=artifact)
  @fs.write_file(artifact_dir + "/build.json", result.to_json().stringify()) catch {
    err =>
      raise @shared.InvalidArchive(
        "failed to write build metadata: \{@debug.to_string(err)}",
      )
  }
  result
}

///|
// Returns the last at-most-max characters, so CLI-visible build errors stay
// readable even when the toolchain scrolls for hundreds of lines.
fn tail(text : String, max : Int32) -> String {
  let len = text.length()
  if len <= max {
    text
  } else {
    text[len - max:].to_owned()
  }
}

///|
// Locates the first .wasm module under the project's _build/wasm tree.
async fn find_wasm_module(src_dir : String) -> String raise @shared.SharedError {
  let build_root = src_dir + "/_build/wasm"
  let build_exists = @fs.exists(build_root) catch { _ => false }
  if !build_exists {
    raise @shared.InvalidArchive("moon build produced no _build/wasm output")
  }
  let found : Array[String] = []
  @fs.walk(build_root, (dir, entries) => {
    for entry in entries {
      if entry.has_suffix(".wasm") && found.length() == 0 {
        found.push(dir + "/" + entry)
      }
    }
  }) catch {
    err =>
      raise @shared.InvalidArchive(
        "failed to scan build output: \{@debug.to_string(err)}",
      )
  }
  if found.length() == 0 {
    raise @shared.InvalidArchive("no .wasm module found in build output")
  }
  found[0]
}

///|
fn has_entry(files : Array[String], path : String) -> Bool {
  for file in files {
    if file == path {
      return true
    }
  }
  false
}
