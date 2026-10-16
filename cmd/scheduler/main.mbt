///|
// The scheduler service: polls the gateway for cron-triggered functions
// and dispatches due fire times to the gateway's event intake.

///|
async fn main {
  let cfg = load_scheduler_config()
  @shared.log_info(
    service="scheduler",
    message="polling \{cfg.gateway_url} every \{cfg.poll_ms}ms",
  )
  let mut table : Map[String, ScheduleEntry] = Map([])
  for ;; {
    let now = @async.now()
    table = sync_table(cfg, table)
    table = dispatch_due(cfg, table, @async.now())
    // Sleep until the nearest fire time or the next poll, whichever is
    // first; a small floor avoids a busy loop on rounding.
    let mut wait = cfg.poll_ms
    for _, entry in table {
      let until = (entry.next_fire_ms - now).to_int()
      if until < wait {
        wait = until
      }
    }
    if wait < 200 {
      wait = 200
    }
    @async.sleep(wait)
  }
}
