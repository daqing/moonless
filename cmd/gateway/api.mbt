///|
// Management API handlers: deploy (forward to builder, then register),
// function listing/detail, and log tails.

///|
async fn handle_deploy(
  ctx : @shared.RequestContext,
  cfg : GatewayConfig,
) -> Unit {
  let request = @shared.DeployRequest::from_json(@shared.read_json_body(ctx))
  let manifest : @shared.Manifest = read_upload_manifest(request.archive) catch {
    @shared.InvalidManifest(message) =>
      return @shared.send_json(
        ctx.conn,
        400,
        @shared.BuildResult(ok=false, error_tail="invalid upload: \{message}").to_json(),
      )
    @shared.InvalidArchive(message) =>
      return @shared.send_json(
        ctx.conn,
        400,
        @shared.BuildResult(ok=false, error_tail="invalid upload: \{message}").to_json(),
      )
    err =>
      return @shared.send_json(
        ctx.conn,
        400,
        @shared.BuildResult(
          ok=false,
          error_tail="invalid upload: \{@debug.to_string(err)}",
        ).to_json(),
      )
  }
  if manifest.name != request.name {
    return @shared.send_json(
      ctx.conn,
      400,
      @shared.BuildResult(
        ok=false,
        error_tail="manifest name \{manifest.name} does not match deploy name \{request.name}",
      ).to_json(),
    )
  }
  let build = @shared.http_post_json(
    cfg.builder_url + "/build",
    request.to_json(),
    timeout_ms=180_000,
  ) catch {
    err =>
      return @shared.send_json(
        ctx.conn,
        200,
        @shared.BuildResult(
          ok=false,
          error_tail="builder unreachable: \{@debug.to_string(err)}",
        ).to_json(),
      )
  }
  let result = @shared.BuildResult::from_json(build)
  if result.ok {
    registry_set(
      cfg,
      @shared.RegistryRecord(
        name=request.name,
        manifest~,
        build_id=result.build_id,
        updated_at=@shared.format_timestamp(@async.now()),
      ),
    )
    @shared.log_info(
      service="gateway",
      message="registered \{request.name} at build \{result.build_id}",
    )
  }
  @shared.send_json(ctx.conn, 200, result.to_json())
}

///|
// Pulls moonless.toml out of the uploaded archive so the registry record
// carries the manifest without another builder round-trip.
async fn read_upload_manifest(
  archive_b64 : String,
) -> @shared.Manifest raise @shared.SharedError {
  let archive = @base64.decode(archive_b64[:]) catch {
    _ => raise @shared.InvalidArchive("archive is not valid base64")
  }
  let manifest_source = @shared.tar_gz_read_text(archive, "moonless.toml") catch {
    err =>
      raise @shared.InvalidArchive(
        "cannot read package archive: \{@debug.to_string(err)}",
      )
  }
  guard manifest_source is Some(source) else {
    raise @shared.InvalidArchive("package is missing moonless.toml")
  }
  @shared.parse_manifest(source)
}

///|
async fn handle_list(ctx : @shared.RequestContext, cfg : GatewayConfig) -> Unit {
  let records = registry_all(cfg)
  let items = []
  for _, record in records {
    items.push(record.to_json())
  }
  @shared.send_json(ctx.conn, 200, Json::array(items))
}

///|
async fn handle_get(ctx : @shared.RequestContext, cfg : GatewayConfig) -> Unit {
  let records = registry_all(cfg)
  match records.get(ctx.params["name"]) {
    Some(record) => @shared.send_json(ctx.conn, 200, record.to_json())
    None => @shared.send_text(ctx.conn, 404, "unknown function\n")
  }
}

///|
async fn handle_logs(ctx : @shared.RequestContext, cfg : GatewayConfig) -> Unit {
  let name = ctx.params["name"]
  let tail = match query_param(ctx.request.path, "tail") {
    Some(value) => @string.parse_int(value) catch { _ => 50 }
    None => 50
  }
  let logs_dir = cfg.data_root + "/logs/" + name
  let entries = @fs.readdir(logs_dir) catch {
    _ => return @shared.send_text(ctx.conn, 404, "no logs for function\n")
  }
  let mut latest = ""
  for entry in entries {
    if entry.has_suffix(".log") && entry > latest {
      latest = entry
    }
  }
  if latest == "" {
    return @shared.send_text(ctx.conn, 404, "no logs for function\n")
  }
  let content = (@fs.read_file(logs_dir + "/" + latest) catch {
    _ => return @shared.send_text(ctx.conn, 500, "log unreadable\n")
  }).text() catch {
    _ => ""
  }
  @shared.send_text(ctx.conn, 200, tail_lines(content, tail))
}

///|
// Last `tail` lines (or the whole text when tail <= 0).
fn tail_lines(text : String, tail : Int) -> String {
  if tail <= 0 {
    return text
  }
  let lines = []
  for line in text.split("\n") {
    lines.push(line.to_owned())
  }
  // A trailing newline yields one empty final element; drop it.
  let mut end = lines.length()
  if end > 0 && lines[end - 1] == "" {
    end -= 1
  }
  let start = if end - tail > 0 { end - tail } else { 0 }
  let mut out = ""
  for i in start..<end {
    out = out + lines[i] + "\n"
  }
  out
}

///|
// Extracts one key from the URL query string of "path?k=v&k2=v2".
fn query_param(path_with_query : String, key : String) -> String? {
  guard path_with_query.split_once("?") is Some((_, query)) else { return None }
  for pair in query.split("&") {
    guard pair.split_once("=") is Some((k, v)) else { continue }
    if k == key {
      return Some(v.to_owned())
    }
  }
  None
}
