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
    "\{today}.log",
    "\{today}.000001.log",
    "\{today}.000002.log",
  ])
  // 4 records exactly fill the cap; the overflow record opens the next part.
  assert_eq(@fs.file_size(dir + "/\{today}.log"), 200L)
  assert_eq(@fs.file_size(dir + "/\{today}.000001.log"), 200L)
  assert_eq(@fs.file_size(dir + "/\{today}.000002.log"), 100L)
  // The rotated-away records stay readable in order.
  let first = @fs.read_file(dir + "/\{today}.log").text() catch { _ => "" }
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
  assert_eq(sorted_log_files(dir), ["\{today}.log"])
  let content = @fs.read_file(dir + "/\{today}.log").text() catch { _ => "" }
  assert_eq(
    content,
    log_payload(20, "r0") + log_payload(20, "r1") + log_payload(20, "r2"),
  )
}
