///|
// Per-function HTTP client admission: max_connection caps in-flight gateway
// requests, so excess clients are rejected instead of queued behind the
// runner's execution concurrency.
priv struct ConnectionCounter {
  limit : Int32
  active : Int32
}

///|
// Used when a function has no max_connection. The counter still tracks active
// requests, so adding a limit in a later deploy starts from the correct count.
let unlimited_connections : Int32 = 2_147_483_647

///|
fn acquire_connection(
  cfg : GatewayConfig,
  name : String,
  limit : Int32,
) -> Bool {
  let active = match cfg.connections.get(name) {
    Some(counter) => counter.active
    None => 0
  }
  if active >= limit {
    // Keep the active count when a redeploy lowers the limit.
    cfg.connections[name] = { limit, active, }
    return false
  }
  cfg.connections[name] = { limit, active: active + 1, }
  true
}

///|
fn release_connection(cfg : GatewayConfig, name : String) -> Unit {
  guard cfg.connections.get(name) is Some(counter) else { return }
  if counter.active > 0 {
    cfg.connections[name] = {
      limit: counter.limit,
      active: counter.active - 1,
    }
  }
}
