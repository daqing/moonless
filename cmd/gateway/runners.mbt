///|
priv struct RunnerNode {
  id : String
  mut url : String
  // Epoch ms of the last registration; nodes that stop renewing are pruned so
  // a stale URL (e.g. after MOONLESS_RUNNER_PUBLIC_URL changes) cannot keep
  // taking round-robin turns.
  mut last_seen_ms : Int64
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
// A node re-registers every 30 s. Three missed rounds (~90 s) with no
// heartbeat means it is gone; drop it so placement stops choosing it.
const RUNNER_TTL_MS : Int64 = 90_000

///|
// Drops nodes whose last registration is older than the TTL. Caller holds the
// registry lock. Keeps `next` inert by re-scanning from scratch, so pruning
// never leaves the round-robin cursor past the end.
fn prune_stale_nodes(registry : RunnerRegistry, now_ms : Int64) -> Unit {
  let alive : Array[RunnerNode] = []
  for node in registry.nodes {
    if now_ms - node.last_seen_ms <= RUNNER_TTL_MS {
      alive.push(node)
    }
  }
  if alive.length() != registry.nodes.length() {
    registry.nodes.clear()
    for node in alive {
      registry.nodes.push(node)
    }
    if registry.next >= registry.nodes.length() + 1 {
      registry.next = 0
    }
  }
}

///|
async fn select_runner(cfg : GatewayConfig) -> (String, Bool) {
  let registry = cfg.runner_registry
  registry.lock.acquire()
  defer registry.lock.release()
  prune_stale_nodes(registry, @async.now())
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
  let now_ms = @async.now()
  prune_stale_nodes(registry, now_ms)
  let mut found = false
  for node in registry.nodes {
    if node.id == id {
      node.url = url
      node.last_seen_ms = now_ms
      found = true
    }
  }
  if !found {
    registry.nodes.push({ id, url, last_seen_ms: now_ms, })
  }
  @shared.log_info(
    service="gateway",
    message="registered runner \{id} at \{url}",
  )
  let response : Json = { "ok": true, "runners": registry.nodes.length() }
  @shared.send_json(ctx.conn, 200, response)
}

///|
// Uploads the build to a remote node. Returns None on success, or Some(reason)
// describing the first failure (unreadable build, or the /modules call) so the
// caller can surface it instead of a generic marker.
async fn ensure_runner_module(
  cfg : GatewayConfig,
  runner_url : String,
  name : String,
  build_id : String,
) -> String? {
  let path = cfg.data_root +
    "/functions/" +
    name +
    "/" +
    build_id +
    "/func.wasm"
  let wasm = @fs.read_file(path).binary() catch {
    _ => return Some("build not readable on gateway: \{path}")
  }
  let policy = match path.rev_split_once("/") {
    Some((dir, _)) =>
      @fs.read_file(dir + "/policy.json").text() catch {
        _ => ""
      }
    None => ""
  }
  let upload = @shared.ModuleUpload(
    name~,
    build_id~,
    wasm=@base64.encode(wasm[:]),
    policy~,
  )
  ignore(
    @shared.http_post_json(
      runner_url + "/modules",
      upload.to_json(),
      timeout_ms=30_000,
    ) catch {
      err =>
        return Some(
          "POST \{runner_url}/modules failed: \{@debug.to_string(err)}",
        )
    },
  )
  None
}
