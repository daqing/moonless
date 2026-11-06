///|
// LogStore rotation and retention, driven by synthetic writes against a
// tiny size cap.

///|
// An exactly `len`-byes ASCII record (marker + padding + newline).
fn log_payload(len : Int32, marker : String) -> String {
  let mut s = marker
  while s.length() < len - 1 {
    s += "x"
  }
  s + "\n"
}

///|
async fn sorted_log_files(dir : String) -> Array[String] {
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

///|
async test "size cap rotates the active day file into numbered parts" {
  let dir = @fs.tmpdir(prefix="moonless-logstore-")
  let store = @shared.LogStore::new(dir~, max_bytes=200, keep=10)
  for i in 0..<10 {
    store.append(log_payload(50, "r\{i}"))
  }
  let today = @shared.format_timestamp(@async.now())[:10].to_owned()
  assert_eq(sorted_log_files(dir), [
    "\{today}.000000.log",
    "\{today}.000001.log",
    "\{today}.000002.log",
  ])
  // 4 records exactly fill the cap; the overflow record opens the next part.
  assert_eq(@fs.file_size(dir + "/\{today}.000000.log"), 200L)
  assert_eq(@fs.file_size(dir + "/\{today}.000001.log"), 200L)
  assert_eq(@fs.file_size(dir + "/\{today}.000002.log"), 100L)
  // The rotated-away records stay readable in order.
  let first = @fs.read_file(dir + "/\{today}.000000.log").text() catch {
    _ => ""
  }
  assert_true(first.contains("r0"))
  assert_true(first.contains("r3"))
  assert_false(first.contains("r4"))
}

///|
async test "retention keeps only the newest N files" {
  let dir = @fs.tmpdir(prefix="moonless-logstore-")
  let store = @shared.LogStore::new(dir~, max_bytes=60, keep=3)
  for i in 0..<10 {
    store.append(log_payload(50, "r\{i}"))
  }
  let today = @shared.format_timestamp(@async.now())[:10].to_owned()
  // One record per file: ten rotations, three survivors.
  assert_eq(sorted_log_files(dir), [
    "\{today}.000007.log",
    "\{today}.000008.log",
    "\{today}.000009.log",
  ])
  let newest = @fs.read_file(dir + "/\{today}.000009.log").text() catch {
    _ => ""
  }
  assert_eq(newest, log_payload(50, "r9"))
}

///|
async test "uncapped appends share a single day file" {
  let dir = @fs.tmpdir(prefix="moonless-logstore-")
  let store = @shared.LogStore::new(dir~, max_bytes=0, keep=0)
  for i in 0..<3 {
    store.append(log_payload(20, "r\{i}"))
  }
  let today = @shared.format_timestamp(@async.now())[:10].to_owned()
  assert_eq(sorted_log_files(dir), ["\{today}.000000.log"])
  let content = @fs.read_file(dir + "/\{today}.000000.log").text() catch {
    _ => ""
  }
  assert_eq(
    content,
    log_payload(20, "r0") + log_payload(20, "r1") + log_payload(20, "r2"),
  )
}

///|
fn test_run_record(
  ts : String,
  source_event : @shared.Event,
  stderr : String,
) -> @shared.RunLogRecord {
  @shared.RunLogRecord(
    ts~,
    name="fn",
    event=source_event,
    exit_code=0,
    duration_ms=7,
    truncated=false,
    stderr~,
  )
}

///|
fn http_event() -> @shared.Event {
  @shared.Event::Http(
    @shared.HttpEventData(http_method="GET", path="/fn/f", query="", body=""),
  )
}

///|
test "run log record survives the JSONL line round-trip" {
  let record = test_run_record(
    "2026-10-16T08:00:00.000Z",
    @shared.Event::S3(@shared.S3EventData(event="put", bucket="b", key="k")),
    "multi\nline\nstderr",
  )
  let line = record.to_line()
  assert_true(line.has_suffix("\n"))
  let mut newlines = 0
  for c in line {
    if c == '\n' {
      newlines += 1
    }
  }
  assert_eq(newlines, 1)
  guard @shared.parse_run_log_line(line[:line.length() - 1].to_owned())
    is Some(parsed) else {
    fail("record line did not parse")
  }
  assert_eq(parsed.ts, record.ts)
  assert_eq(parsed.name, "fn")
  assert_eq(parsed.source, "s3")
  assert_eq(parsed.exit_code, 0)
  assert_eq(parsed.duration_ms, 7)
  assert_eq(parsed.stderr, "multi\nline\nstderr")
  // The human rendering keeps the pre-JSONL shape.
  let rendered = parsed.render()
  assert_true(rendered.contains("event={\"source\":\"s3\""))
  assert_true(rendered.contains("exit=0 dur=7ms truncated=false"))
  assert_true(rendered.has_suffix("multi\nline\nstderr\n"))
  // Garbage and legacy free-text lines are skipped, never fatal.
  assert_true(@shared.parse_run_log_line("not json") is None)
  assert_true(@shared.parse_run_log_line("2026-10-16 event={} exit=0") is None)
}

///|
async test "read_run_log_records reads rotated files with filters" {
  let dir = @fs.tmpdir(prefix="moonless-logstore-")
  let cron = @shared.Event::Cron(
    @shared.CronEventData(schedule="0 8 * * *", time="t"),
  )
  let r1 = test_run_record("2026-10-15T08:00:00.000Z", http_event(), "one")
  let r2 = test_run_record("2026-10-16T08:00:00.000Z", cron, "two")
  let r2r = test_run_record("2026-10-16T09:00:00.000Z", http_event(), "rot")
  let r3 = test_run_record("2026-10-17T08:00:00.000Z", cron, "three")
  @fs.write_file(
    dir + "/2026-10-15.000000.log",
    "legacy free-text line\n" + r1.to_line(),
  )
  @fs.write_file(dir + "/2026-10-16.000000.log", r2.to_line())
  // A rotated part of the 16th is read after the day's first file.
  @fs.write_file(dir + "/2026-10-16.000001.log", r2r.to_line())
  @fs.write_file(dir + "/2026-10-17.000000.log", r3.to_line())
  let all = @shared.read_run_log_records(dir)
  assert_eq(all.map(fn(r) { r.stderr }), ["one", "two", "rot", "three"])
  let cron_only = @shared.read_run_log_records(dir, source="cron")
  assert_eq(cron_only.map(fn(r) { r.stderr }), ["two", "three"])
  let since = @shared.read_run_log_records(dir, since="2026-10-16")
  assert_eq(since.map(fn(r) { r.stderr }), ["two", "rot", "three"])
  let since_ts = @shared.read_run_log_records(
    dir,
    since="2026-10-16T08:30:00.000Z",
  )
  assert_eq(since_ts.map(fn(r) { r.stderr }), ["rot", "three"])
  let both = @shared.read_run_log_records(
    dir,
    since="2026-10-16T08:30:00.000Z",
    source="cron",
  )
  assert_eq(both.map(fn(r) { r.stderr }), ["three"])
}
