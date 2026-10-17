///|
// The scheduler's in-memory schedule table: one entry per function with a
// cron trigger, refreshed from the gateway on every poll.

///|
priv struct ScheduleEntry {
  schedule : @shared.CronSchedule
  next_fire_ms : Int64
}

///|
priv struct SchedulerConfig {
  gateway_url : String
  poll_ms : Int32
}

///|
fn scheduler_env_int(name : String, default : Int32) -> Int32 {
  match @env.get_env_var(name) {
    Some(value) => @string.parse_int(value) catch { _ => default }
    None => default
  }
}

///|
fn load_scheduler_config() -> SchedulerConfig {
  let gateway_url = @env.get_env_var("MOONLESS_GATEWAY_URL").unwrap_or(
    "http://gateway:8080",
  )
  let poll_ms = scheduler_env_int("MOONLESS_POLL_INTERVAL_MS", 30_000)
  { gateway_url, poll_ms, }
}

///|
// Pulls the function list from the gateway and rebuilds the schedule
// table with the cron-triggered functions. Entries whose expression is
// unchanged keep their pending fire time (if still in the future);
// anything else is recomputed from now. On gateway errors the previous
// table survives (skip-if-late, T7.4).
async fn sync_table(
  cfg : SchedulerConfig,
  previous : Map[String, ScheduleEntry],
) -> Map[String, ScheduleEntry] {
  let now = @async.now()
  let response = @shared.http_get_json(
    cfg.gateway_url + "/api/functions",
    timeout_ms=15_000,
  ) catch {
    _ => {
      @shared.log_warn(
        service="scheduler",
        message="cannot reach the gateway; keeping the previous schedule",
      )
      return previous
    }
  }
  guard response is Array(items) else { return previous }
  let fresh : Map[String, ScheduleEntry] = Map([])
  for item in items {
    let record = try @shared.RegistryRecord::from_json(item) catch {
      _ => None
    } noraise {
      r => Some(r)
    }
    guard record is Some(r) else { continue }
    let expr = r.manifest.triggers.cron
    guard expr is Some(expression) else { continue }
    let sched = try @shared.CronSchedule(name=r.name, expression~) catch {
      _ => None
    } noraise {
      s => Some(s)
    }
    match sched {
      Some(schedule) => {
        let carry_over = previous.get(r.name)
        // Keep the pending fire time for unchanged expressions, with a
        // grace window: a fire time that just passed must survive the sync
        // so the dispatch step can still see it (the loop wakes exactly on
        // the boundary). Beyond the grace the entry is recomputed from
        // now — skip-if-late (T7.4).
        let grace_ms : Int64 = 60_000
        let next = if carry_over is Some(old) &&
          old.schedule.expression == expression &&
          old.next_fire_ms > now - grace_ms {
          old.next_fire_ms
        } else {
          schedule.next_fire_ms(now) catch {
            _ => now + 60_000
          }
        }
        fresh[r.name] = { schedule, next_fire_ms: next, }
      }
      None =>
        @shared.log_warn(
          service="scheduler",
          message="skipping \{r.name}: invalid cron expression",
        )
    }
  }
  fresh
}

///|
// Fires every due entry: assembles the cron event (schedule + scheduled
// fire time) and POSTs it to the gateway's /api/events. Entries are then
// rescheduled from `now` — a late wake-up fires once and skips the missed
// periods (skip-if-late, T7.4).
async fn dispatch_due(
  cfg : SchedulerConfig,
  table : Map[String, ScheduleEntry],
  now : Int64,
) -> Map[String, ScheduleEntry] {
  let updated : Map[String, ScheduleEntry] = Map([])
  for name, entry in table {
    if entry.next_fire_ms <= now {
      let event : Json = {
        "source": "cron",
        "schedule": entry.schedule.expression,
        "time": @shared.format_timestamp(entry.next_fire_ms),
      }
      let _ = @shared.http_post_json(
        cfg.gateway_url + "/api/events",
        event,
        timeout_ms=30_000,
      ) catch {
        _ => {
          @shared.log_warn(
            service="scheduler",
            message="event dispatch failed for \{name}",
          )
          Json::null()
        }
      }
      @shared.log_info(
        service="scheduler",
        message="fired \{name} (\{entry.schedule.expression})",
      )
      let next = entry.schedule.next_fire_ms(now) catch { _ => now + 60_000 }
      updated[name] = { schedule: entry.schedule, next_fire_ms: next, }
    } else {
      updated[name] = entry
    }
  }
  updated
}
