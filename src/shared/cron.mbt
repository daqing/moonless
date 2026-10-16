///|
// Cron scheduling on top of lijunjie860/moonbit_cron: five-field parsing
// plus next-fire-time computation in epoch milliseconds. All times are
// UTC (the scheduler container's clock, per the timezone convention).

///|
pub struct CronSchedule {
  name : String
  expression : String
  spec : @cron.CronExpr
}

///|
pub fn CronSchedule::CronSchedule(
  name~ : String,
  expression~ : String,
) -> CronSchedule raise SharedError {
  let spec = match @cron.parse(expression) {
    Ok(spec) => spec
    Err(message) =>
      raise InvalidManifest("invalid cron expression \{expression}: \{message}")
  }
  { name, expression, spec, }
}

///|
// Next fire time strictly after after_ms, in epoch milliseconds.
pub fn CronSchedule::next_fire_ms(
  self : CronSchedule,
  after_ms : Int64,
) -> Int64 raise SharedError {
  let from = epoch_ms_to_time(after_ms)
  let next = match self.spec.next(from) {
    Ok(t) => t
    Err(message) =>
      raise InvalidManifest(
        "cannot compute next fire time for \{self.expression}: \{message}",
      )
  }
  let next_ms = time_to_epoch_ms(next)
  if next_ms <= after_ms {
    // Guard against a library next() that is not strictly increasing.
    let bumped = @cron.add_minute(next)
    time_to_epoch_ms(bumped)
  } else {
    next_ms
  }
}

///|
// Renders epoch milliseconds as the @cron library's Time (UTC).
pub fn epoch_ms_to_time(ms : Int64) -> @cron.Time {
  let secs = ms / 1000
  let days = (secs / 86400).to_int()
  let secs_of_day = (secs % 86400).to_int()
  let (year, month, day) = civil_from_days(days)
  {
    year,
    month,
    day,
    hour: secs_of_day / 3600,
    minute: secs_of_day % 3600 / 60,
    weekday: 0,
  }
}

///|
// Inverse of civil_from_days (Howard Hinnant's days_from_civil).
pub fn days_from_civil(year : Int, month : Int, day : Int) -> Int {
  let y = if month <= 2 { year - 1 } else { year }
  let era = (if y >= 0 { y } else { y - 399 }) / 400
  let yoe = y - era * 400
  let mp = month + (if month > 2 { -3 } else { 9 })
  let doy = (153 * mp + 2) / 5 + day - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146097 + doe - 719468
}

///|
pub fn time_to_epoch_ms(t : @cron.Time) -> Int64 {
  let days = days_from_civil(t.year, t.month, t.day)
  (
    days.to_int64() * 86_400L +
    t.hour.to_int64() * 3600L +
    t.minute.to_int64() * 60L
  ) *
  1000L
}
