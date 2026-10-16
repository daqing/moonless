///|
// Append-only per-function log store. Records land in day files named
// <YYYY-MM-DD>.<NNNNNN>.log (zero-padded sequence from 000000, so lexical
// order is chronological order); when an append would push the active file
// past the size cap the store opens the next sequence, and only the newest
// `keep` files are retained per function.

///|
pub struct LogStore {
  dir : String
  max_bytes : Int32 // per-file cap; <= 0 disables size rotation
  keep : Int32 // files retained per function; <= 0 keeps everything
}

///|
pub fn LogStore::new(
  dir~ : String,
  max_bytes~ : Int32 = 16 * 1024 * 1024,
  keep~ : Int32 = 14,
) -> LogStore {
  { dir, max_bytes, keep, }
}

///|
pub async fn LogStore::append(self : LogStore, text : String) -> Unit {
  @fs.mkdir(self.dir, recursive=true, allow_exist=true) catch {
    _ => ()
  }
  let today = format_timestamp(@async.now())[:10].to_owned()
  let todays = self.list_files(prefix=today)
  let mut active = match todays.last() {
    Some(name) => name
    None => "\{today}.000000.log"
  }
  if self.max_bytes > 0 {
    let current = @fs.file_size(self.dir + "/" + active) catch { _ => 0L }
    let incoming = @utf8.encode(text).length().to_int64()
    if current > 0 && current + incoming > self.max_bytes.to_int64() {
      active = next_part_name(today, active)
    }
  }
  @fs.write_file(
    self.dir + "/" + active,
    text,
    append=true,
    create_mode=OpenOrCreate,
  )
  self.prune()
}

///|
// All .log files in the store (optionally one day's), sorted ascending —
// with the naming scheme above, lexical order is chronological order.
async fn LogStore::list_files(
  self : LogStore,
  prefix~ : String = "",
) -> Array[String] {
  let entries = @fs.readdir(self.dir) catch { _ => return [] }
  let out = []
  for entry in entries {
    if entry.has_suffix(".log") && (prefix == "" || entry.has_prefix(prefix)) {
      out.push(entry)
    }
  }
  out.sort()
  out
}

///|
// The next rotation target after `active`: "<date>.000007.log" ->
// "<date>.000008.log". A legacy bare "<date>.log" rotates to ".000001.log".
fn next_part_name(today : String, active : String) -> String {
  let seq = if active == "\{today}.log" {
    0
  } else {
    let mid = active[today.length() + 1:active.length() - 4]
    @string.parse_int(mid) catch {
      _ => 0
    }
  }
  let mut padded = (seq + 1).to_string()
  while padded.length() < 6 {
    padded = "0" + padded
  }
  "\{today}.\{padded}.log"
}

///|
async fn LogStore::prune(self : LogStore) -> Unit {
  if self.keep <= 0 {
    return
  }
  let files = self.list_files()
  let excess = files.length() - self.keep
  if excess <= 0 {
    return
  }
  for i in 0..<excess {
    @fs.remove(self.dir + "/" + files[i]) catch {
      _ => ()
    }
  }
}

///|
// One record per invocation, stored as a single JSON line so rotated files
// stay machine-queryable (T8.2/T8.3). `render` produces the human-readable
// form the logs API returns.
pub struct RunLogRecord {
  ts : String // ISO-8601 UTC, format_timestamp output
  name : String
  source : String // http | cron | s3
  event : Event
  exit_code : Int32
  duration_ms : Int32
  truncated : Bool
  stderr : String
} derive(Debug)

///|
pub extend RunLogRecord with Debug::{to_repr}

///|
pub fn RunLogRecord::RunLogRecord(
  ts~ : String,
  name~ : String,
  event~ : Event,
  exit_code~ : Int32,
  duration_ms~ : Int32,
  truncated~ : Bool,
  stderr~ : String,
) -> RunLogRecord {
  {
    ts,
    name,
    source: event.source_name(),
    event,
    exit_code,
    duration_ms,
    truncated,
    stderr,
  }
}

///|
pub fn RunLogRecord::to_json(self : RunLogRecord) -> Json {
  let json : Json = {
    "ts": self.ts,
    "name": self.name,
    "source": self.source,
    "event": self.event.to_json(),
    "exitCode": self.exit_code,
    "durationMs": self.duration_ms,
    "truncated": self.truncated,
    "stderr": self.stderr,
  }
  json
}

///|
pub fn RunLogRecord::from_json(json : Json) -> RunLogRecord raise SharedError {
  guard json is Object(obj) else {
    raise InvalidJson("run log record expected an object")
  }
  guard json_field(obj, "event") is Some(event_json) else {
    raise InvalidJson("run log record has no event")
  }
  let event = Event::from_json(event_json)
  let source = json_field_string(obj, "source")
  if source != event.source_name() {
    raise InvalidJson("run log record source disagrees with the event")
  }
  {
    ts: json_field_string(obj, "ts"),
    name: json_field_string(obj, "name"),
    source,
    event,
    exit_code: json_field_int(obj, "exitCode"),
    duration_ms: json_field_int(obj, "durationMs"),
    truncated: json_field_bool(obj, "truncated"),
    stderr: json_field_string(obj, "stderr"),
  }
}

///|
// The stored JSONL form: one line per record (stringify escapes the
// newlines inside stderr).
pub fn RunLogRecord::to_line(self : RunLogRecord) -> String {
  self.to_json().stringify() + "\n"
}

///|
// Parses one stored line; unparseable lines (e.g. pre-JSONL records) are
// skipped by returning None.
pub fn parse_run_log_line(line : String) -> RunLogRecord? {
  let json = try @json.parse(line) catch {
    _ => return None
  } noraise {
    j => j
  }
  try RunLogRecord::from_json(json) catch {
    _ => None
  } noraise {
    r => Some(r)
  }
}

///|
pub fn RunLogRecord::render(self : RunLogRecord) -> String {
  "\{self.ts} event=\{self.event.to_json().stringify()} exit=\{self.exit_code} dur=\{self.duration_ms}ms truncated=\{self.truncated}\n\{self.stderr}\n"
}

///|
// Every stored record for one function, oldest first. `since` is an
// ISO-8601 UTC lower bound compared lexically against record timestamps
// (a bare date matches that whole day); `source` matches exactly. Files
// whose day predates `since` are skipped without reading.
pub async fn read_run_log_records(
  dir : String,
  since~ : String = "",
  source~ : String = "",
) -> Array[RunLogRecord] {
  let files = log_files(dir)
  let since_day = if since.length() >= 10 { since[:10] } else { since[:] }
  let records : Array[RunLogRecord] = []
  for file in files {
    if since_day != "" && file[:10] < since_day {
      continue
    }
    let content = (@fs.read_file(dir + "/" + file) catch { _ => continue }).text() catch {
      _ => continue
    }
    for line in content.split("\n") {
      if line == "" {
        continue
      }
      match parse_run_log_line(line.to_owned()) {
        Some(record) =>
          if (since == "" || record.ts >= since) &&
            (source == "" || record.source == source) {
            records.push(record)
          }
        None => ()
      }
    }
  }
  records
}

///|
async fn log_files(dir : String) -> Array[String] {
  let entries = @fs.readdir(dir) catch { _ => return [] }
  let out = []
  for entry in entries {
    if entry.has_suffix(".log") {
      out.push(entry)
    }
  }
  out.sort()
  out
}
