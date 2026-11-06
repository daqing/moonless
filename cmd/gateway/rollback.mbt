///|
async fn build_history(
  cfg : GatewayConfig,
  name : String,
  build_id : String,
) -> Array[String] {
  let history : Array[String] = []
  if registry_all(cfg).get(name) is Some(previous) {
    for id in previous.history {
      push_unique(history, id)
    }
    push_unique(history, previous.build_id)
  }
  push_unique(history, build_id)
  history
}

///|
fn push_unique(items : Array[String], value : String) -> Unit {
  if !has_event(items, value) {
    items.push(value)
  }
}

///|
fn previous_build(record : @shared.RegistryRecord) -> String {
  for i in 0..<record.history.length() {
    if record.history[i] == record.build_id && i > 0 {
      return record.history[i - 1]
    }
  }
  ""
}

///|
async fn handle_rollback(
  ctx : @shared.RequestContext,
  cfg : GatewayConfig,
) -> Unit {
  let name = ctx.params["name"]
  let payload = @shared.read_json_body(ctx)
  guard payload is Object(obj) else {
    return @shared.send_text(ctx.conn, 400, "rollback body must be an object\n")
  }
  let requested = @shared.json_field_string(obj, "buildId", default="")
  guard registry_all(cfg).get(name) is Some(record) else {
    return @shared.send_text(ctx.conn, 404, "unknown function \{name}\n")
  }
  let build_id = if requested == "" {
    previous_build(record)
  } else {
    requested
  }
  if build_id == "" {
    return @shared.send_text(ctx.conn, 400, "no earlier build for \{name}\n")
  }
  if !has_event(record.history, build_id) {
    return @shared.send_text(ctx.conn, 400, "unknown build \{build_id}\n")
  }
  let artifact = cfg.data_root +
    "/functions/" +
    name +
    "/" +
    build_id +
    "/func.wasm"
  if !(@fs.exists(artifact) catch { _ => false }) {
    return @shared.send_text(
      ctx.conn,
      400,
      "build artifact missing: \{build_id}\n",
    )
  }
  let updated = @shared.RegistryRecord(
    name=record.name,
    manifest=record.manifest,
    build_id~,
    updated_at=@shared.format_timestamp(@async.now()),
    history=record.history,
  )
  registry_set(cfg, updated)
  @shared.log_info(
    service="gateway",
    message="rolled back \{name} to build \{build_id}",
  )
  @shared.send_json(ctx.conn, 200, updated.to_json())
}
