///|
// `moonless list`: a table of deployed functions with their triggers and
// the current build.

///|
async fn cli_list(server : String) -> Unit raise CliError {
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
  @stdio.stdout.write(render_function_table(records)) catch {
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
fn render_function_table(records : Array[@shared.RegistryRecord]) -> String {
  if records.length() == 0 {
    return "no functions deployed\n"
  }
  let header = "\{pad("NAME", 20)} \{pad("TRIGGERS", 24)} \{pad("BUILD", 16)} UPDATED\n"
  let mut out = header
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
fn pad(text : String, width : Int) -> String {
  let mut out = text
  while out.length() < width {
    out += " "
  }
  out
}
