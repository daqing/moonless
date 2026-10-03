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
  for required in ["moon.mod", "moonless.toml"] {
    if !has_entry(files, required) {
      raise @shared.InvalidArchive("package is missing \{required}")
    }
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
  // T3.3 invokes the toolchain here; until then a valid package passes.
  @shared.BuildResult(ok=true, build_id~, wasm_path="")
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
