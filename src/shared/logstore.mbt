///|
// Append-only per-function log store. Records land in day files named
// <YYYY-MM-DD>.log; when an append would push the active file past the size
// cap, the store rotates to <YYYY-MM-DD>.<NNNNNN>.log (the zero-padded
// sequence keeps lexical order chronological), and only the newest `keep`
// files are retained per function.

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
    None => "\{today}.log"
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
// The next rotation target after `active`: "<date>.log" -> ".000001.log",
// "<date>.000007.log" -> ".000008.log".
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
