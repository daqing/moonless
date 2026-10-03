///|
// The scheduler service: polls the gateway for cron-triggered functions
// and keeps an in-memory schedule table (dispatch lands in T7.3).

///|
async fn main {
  let cfg = load_scheduler_config()
  @shared.log_info(
    service="scheduler",
    message="polling \{cfg.gateway_url} every \{cfg.poll_ms}ms",
  )
  let mut table : Map[String, ScheduleEntry] = Map([])
  for ;; {
    table = sync_table(cfg, table)
    @async.sleep(cfg.poll_ms)
  }
}
