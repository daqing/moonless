///|
// Structured stderr logging: ISO-8601 UTC timestamp, service name, level,
// message — one line per event, easy to grep and collect.

///|
pub enum LogLevel {
  Info
  Warn
  Error
} derive(Debug)

///|
pub extend LogLevel with Debug::{to_repr}

///|
pub async fn log(service : String, level : LogLevel, message : String) -> Unit {
  let line = "\{format_timestamp(@async.now())} [\{service}] \{level_name(level)} \{message}\n"
  @stdio.stderr.write(line) catch {
    _ => ()
  }
}

///|
pub async fn log_info(service~ : String, message~ : String) -> Unit {
  log(service, Info, message)
}

///|
pub async fn log_warn(service~ : String, message~ : String) -> Unit {
  log(service, Warn, message)
}

///|
pub async fn log_error(service~ : String, message~ : String) -> Unit {
  log(service, Error, message)
}

///|
fn level_name(level : LogLevel) -> String {
  match level {
    Info => "INFO"
    Warn => "WARN"
    Error => "ERROR"
  }
}

///|
// Renders epoch milliseconds as "YYYY-MM-DDTHH:MM:SS.mmmZ" in UTC.
pub fn format_timestamp(ms_since_epoch : Int64) -> String {
  let secs = ms_since_epoch / 1000
  let millis = (ms_since_epoch % 1000).to_int()
  let days = (secs / 86400).to_int()
  let secs_of_day = (secs % 86400).to_int()
  let (year, month, day) = civil_from_days(days)
  let hour = secs_of_day / 3600
  let minute = secs_of_day % 3600 / 60
  let second = secs_of_day % 60
  "\{year}-\{pad2(month)}-\{pad2(day)}T\{pad2(hour)}:\{pad2(minute)}:\{pad2(second)}.\{pad3(millis)}Z"
}

///|
// Howard Hinnant's civil_from_days: days since 1970-01-01 -> (y, m, d).
fn civil_from_days(days : Int) -> (Int, Int, Int) {
  let z = days + 719468
  let era = (if z >= 0 { z } else { z - 146096 }) / 146097
  let doe = z - era * 146097
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp = (5 * doy + 2) / 153
  let d = doy - (153 * mp + 2) / 5 + 1
  let m = mp + (if mp < 10 { 3 } else { -9 })
  let year = if m <= 2 { y + 1 } else { y }
  (year, m, d)
}

///|
fn pad2(n : Int) -> String {
  if n < 10 {
    "0\{n}"
  } else {
    "\{n}"
  }
}

///|
fn pad3(n : Int) -> String {
  if n < 10 {
    "00\{n}"
  } else if n < 100 {
    "0\{n}"
  } else {
    "\{n}"
  }
}
