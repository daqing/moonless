///|
// `moonless list`: a table of deployed functions with their triggers and
// the current build.

///|
async fn cli_list(
  flags : Array[String],
  server : String,
) -> Unit raise CliError {
  let quiet = parse_list_quiet(flags)
  let response = @shared.http_get_json(
    server + "/api/functions",
    timeout_ms=30_000,
  ) catch {
    _ =>
      raise CliError(
        "cannot reach the moonless server at \{server}\n(hint: is the stack running? try 'docker compose up -d')",
      )
  }
  guard response is Array(items) else {
    raise CliError("the server sent an unreadable function list")
  }
  let records : Array[@shared.RegistryRecord] = []
  for item in items {
    match decode_record(item) {
      Some(r) => records.push(r)
      None => ()
    }
  }
  @stdio.stdout.write(render_function_table(records, quiet~)) catch {
    _ => ()
  }
}

///|
fn decode_record(item : Json) -> @shared.RegistryRecord? {
  try @shared.RegistryRecord::from_json(item) catch {
    _ => None
  } noraise {
    r => Some(r)
  }
}

///|
fn parse_list_quiet(flags : Array[String]) -> Bool raise CliError {
  let mut quiet = false
  let mut i = 0
  while i < flags.length() {
    if flags[i] == "--server" {
      i += 2
      continue
    }
    if flags[i].has_prefix("--server=") {
      i += 1
      continue
    }
    if flags[i] == "-q" {
      quiet = true
      i += 1
      continue
    }
    raise CliError("unexpected argument '\{flags[i]}' for list")
  }
  quiet
}

///|
fn render_function_table(
  records : Array[@shared.RegistryRecord],
  quiet~ : Bool = false,
) -> String {
  if records.length() == 0 {
    return if quiet { "" } else { "no functions deployed\n" }
  }
  let header = "\{pad("NAME", 20)} \{pad("TRIGGERS", 24)} \{pad("BUILD", 16)} UPDATED\n"
  let mut out = if quiet { "" } else { header }
  for record in records {
    let row = "\{pad(record.name, 20)} \{pad(trigger_summary(record), 24)} \{pad(record.build_id, 16)} \{record.updated_at}\n"
    out += row
  }
  out
}

///|
fn trigger_summary(record : @shared.RegistryRecord) -> String {
  let parts : Array[String] = []
  let triggers = record.manifest.triggers
  if triggers.http_enabled {
    parts.push("http")
  }
  match triggers.cron {
    Some(expr) => parts.push("cron(\{expr})")
    None => ()
  }
  match triggers.s3 {
    Some(s3) => {
      let mut events = ""
      for i in 0..<s3.events.length() {
        if i > 0 {
          events += ","
        }
        events += s3.events[i]
      }
      parts.push("s3(\{s3.bucket}:\{events})")
    }
    None => ()
  }
  if parts.length() == 0 {
    return "-"
  }
  let mut joined = ""
  for i in 0..<parts.length() {
    if i > 0 {
      joined += " "
    }
    joined += parts[i]
  }
  joined
}

///|
// Pads to at least width; long cells overflow instead of truncating so
// trigger details stay visible.
fn pad(text : String, width : Int32) -> String {
  let mut out = text
  while out.length() < width {
    out += " "
  }
  out
}
