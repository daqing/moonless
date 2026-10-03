///|
// Internal event intake: POST /api/events accepts any trigger event,
// matches it against the registry's declared triggers, and dispatches
// every match to the runner (cron scheduler, SeaweedFS webhooks, ...).

///|
async fn handle_event(
  ctx : @shared.RequestContext,
  cfg : GatewayConfig,
) -> Unit {
  let event = @shared.Event::from_json(@shared.read_json_body(ctx))
  let records = registry_all(cfg)
  let dispatches = []
  for name, record in records {
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
  let response = @shared.http_post_json(
    cfg.runner_url + "/run",
    @shared.RunRequest(name~, event~).to_json(),
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
