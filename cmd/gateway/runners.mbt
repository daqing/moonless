///|
priv struct RunnerNode {
  id : String
  mut url : String
}

///|
priv struct RunnerRegistry {
  nodes : Array[RunnerNode]
  mut next : Int32
  lock : @async.Mutex
}

///|
fn RunnerRegistry::RunnerRegistry() -> RunnerRegistry {
  { nodes: [], next: 0, lock: @async.Mutex::Mutex(), }
}

///|
async fn select_runner(cfg : GatewayConfig) -> (String, Bool) {
  let registry = cfg.runner_registry
  registry.lock.acquire()
  defer registry.lock.release()
  let count = registry.nodes.length() + 1
  let selected = registry.next % count
  registry.next += 1
  if selected == 0 {
    (cfg.runner_url, false)
  } else {
    (registry.nodes[selected - 1].url, true)
  }
}

///|
async fn handle_runner_registration(
  ctx : @shared.RequestContext,
  cfg : GatewayConfig,
) -> Unit {
  let payload = @shared.read_json_body(ctx)
  guard payload is Object(obj) else {
    return @shared.send_text(
      ctx.conn,
      400,
      "runner registration expected an object\n",
    )
  }
  let id = @shared.json_field_string(obj, "id")
  let raw_url = @shared.json_field_string(obj, "url")
  if id == "" || raw_url == "" {
    return @shared.send_text(ctx.conn, 400, "runner id and url are required\n")
  }
  let url = if raw_url.has_suffix("/") {
    raw_url[:raw_url.length() - 1].to_owned()
  } else {
    raw_url
  }
  let registry = cfg.runner_registry
  registry.lock.acquire()
  defer registry.lock.release()
  let mut found = false
  for node in registry.nodes {
    if node.id == id {
      node.url = url
      found = true
    }
  }
  if !found {
    registry.nodes.push({ id, url, })
  }
  @shared.log_info(
    service="gateway",
    message="registered runner \{id} at \{url}",
  )
  let response : Json = { "ok": true, "runners": registry.nodes.length() }
  @shared.send_json(ctx.conn, 200, response)
}

///|
async fn ensure_runner_module(
  cfg : GatewayConfig,
  runner_url : String,
  name : String,
  build_id : String,
) -> Bool {
  let path = cfg.data_root +
    "/functions/" +
    name +
    "/" +
    build_id +
    "/func.wasm"
  let wasm = @fs.read_file(path).binary() catch { _ => return false }
  let upload = @shared.ModuleUpload(
    name~,
    build_id~,
    wasm=@base64.encode(wasm[:]),
  )
  ignore(
    @shared.http_post_json(
      runner_url + "/modules",
      upload.to_json(),
      timeout_ms=30_000,
    ) catch {
      _ => return false
    },
  )
  true
}
