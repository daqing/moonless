///|
// Internal event intake: POST /api/events accepts any trigger event,
// matches it against the registry's declared triggers, and dispatches
// every match to the runner (cron scheduler, SeaweedFS webhooks, ...).

///|
async fn handle_event(
  ctx : @shared.RequestContext,
  cfg : GatewayConfig,
) -> Unit {
  let payload = @shared.read_json_body(ctx)
  let event : @shared.Event? = if payload is Object(obj) &&
    obj.get("event_type") is Some(_) {
    @shared.log_info(
      service="gateway",
      message="received SeaweedFS filer event: \{payload.stringify()}",
    )
    adapt_seaweedfs_event(payload)
  } else {
    Some(@shared.Event::from_json(payload))
  }
  guard event is Some(event) else {
    return @shared.send_json(ctx.conn, 200, Json::array([]))
  }
  let target_function = if payload is Object(obj) &&
    obj.get("function") is Some(String(name)) {
    Some(name)
  } else {
    None
  }
  let records = registry_all(cfg)
  let dispatches = []
  for name, record in records {
    if target_function is Some(target) && target != name {
      continue
    }
    if trigger_matches(record.manifest.triggers, event) {
      @shared.log_info(
        service="gateway",
        message="dispatching event to \{name}",
      )
      let result = dispatch_run(cfg, name, event)
      let entry : Map[String, Json] = Map([])
      entry["name"] = Json::string(name)
      entry["result"] = result.to_json()
      dispatches.push(Json::object(entry))
    }
  }
  @shared.send_json(ctx.conn, 200, Json::array(dispatches))
}

///|
async fn dispatch_run(
  cfg : GatewayConfig,
  name : String,
  event : @shared.Event,
) -> @shared.RunResult {
  let (build_id, native_binary) = match registry_all(cfg).get(name) {
    Some(record) => (record.build_id, record.manifest.binary is Some(_))
    None => ("", false)
  }
  let (runner_url, upload_required) = select_runner(cfg)
  if upload_required &&
    build_id != "" &&
    !ensure_runner_module(cfg, runner_url, name, build_id) {
    return @shared.RunResult(
      stdout="",
      stderr="moonless: failed to upload module to runner",
      exit_code=127,
    )
  }
  let response = @shared.http_post_json(
    runner_url + "/run",
    @shared.RunRequest(name~, event~, build_id~, native_binary~).to_json(),
    timeout_ms=70_000,
  ) catch {
    _ =>
      return @shared.RunResult(
        stdout="",
        stderr="moonless: runner unreachable",
        exit_code=127,
      )
  }
  @shared.RunResult::from_json(response) catch {
    _ =>
      @shared.RunResult(
        stdout="",
        stderr="moonless: runner protocol error",
        exit_code=127,
      )
  }
}

///|
fn trigger_matches(
  triggers : @shared.ManifestTriggers,
  event : @shared.Event,
) -> Bool {
  match event {
    Http(_) => triggers.http_enabled
    Cron(_) => triggers.cron is Some(_)
    S3(e) =>
      match triggers.s3 {
        Some(s3) => s3.bucket == e.bucket && has_event(s3.events, e.event_name)
        None => false
      }
  }
}

///|
fn has_event(events : Array[String], name : String) -> Bool {
  for event in events {
    if event == name {
      return true
    }
  }
  false
}
