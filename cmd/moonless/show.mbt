///|
// `moonless show <name>` prints a function's manifest, build, and history.

///|
async fn cli_show(
  flags : Array[String],
  server : String,
  out~ : CliOut = CliOut::stdout(),
) -> Unit raise CliError {
  let name = parse_show_name(flags)
  let response = @shared.http_get(
    server + "/api/functions/\{name}",
    timeout_ms=30_000,
  ) catch {
    _ =>
      raise CliError(
        "cannot reach the moonless server at \{server}\n(hint: is the stack running? try 'docker compose up -d')",
      )
  }
  if response.status == 404 {
    raise CliError(
      "no function '\{name}'\n(hint: check the name with 'moonless list')",
    )
  }
  if response.status != 200 {
    raise CliError(
      "cannot show '\{name}': the server returned \{response.status}",
    )
  }
  let json = @json.parse(response.body) catch {
    _ => raise CliError("the server sent an unreadable function record")
  }
  let record = match decode_record(json) {
    Some(record) => record
    None => raise CliError("the server sent an unreadable function record")
  }
  out.write(render_function_detail(record, server))
}

///|
fn parse_show_name(flags : Array[String]) -> String raise CliError {
  let mut name = ""
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
    if name == "" {
      name = flags[i]
      i += 1
      continue
    }
    raise CliError("unexpected argument '\{flags[i]}' for show")
  }
  if name == "" {
    raise CliError("usage: moonless show <name>")
  }
  name
}

///|
fn render_function_detail(
  record : @shared.RegistryRecord,
  server : String,
) -> String {
  let manifest = record.manifest
  let mut out = ""
  out += "name:      \{record.name}\n"
  out += "build:     \{record.build_id}\n"
  out += "updated:   \{record.updated_at}\n"
  match manifest.toolchain {
    Some(value) => out += "toolchain: \{value}\n"
    None => ()
  }
  match manifest.sandbox {
    Some(value) => out += "sandbox:   \{value}\n"
    None => ()
  }
  out += render_detail_triggers(manifest.triggers, server, record.name)
  out += render_detail_limits(manifest.limits)
  if record.history.length() > 0 {
    out += "history:   \{record.history.join(" ")}\n"
  }
  out
}

///|
fn render_detail_triggers(
  triggers : @shared.ManifestTriggers,
  server : String,
  name : String,
) -> String {
  let lines : Array[String] = []
  if triggers.http_enabled {
    lines.push("  http: enabled (\{server}/fn/\{name})")
  }
  match triggers.cron {
    Some(expression) => lines.push("  cron: \{expression}")
    None => ()
  }
  match triggers.s3 {
    Some(s3) =>
      lines.push("  s3: bucket=\{s3.bucket} methods=\{s3.methods.join(",")}")
    None => ()
  }
  if lines.length() == 0 {
    return "triggers:  none\n"
  }
  let mut out = "triggers:\n"
  for line in lines {
    out += line + "\n"
  }
  out
}

///|
fn render_detail_limits(limits : @shared.FunctionLimits) -> String {
  let parts : Array[String] = []
  match limits.timeout_ms {
    Some(value) => parts.push("timeout_ms=\{value}")
    None => ()
  }
  match limits.concurrency {
    Some(value) => parts.push("concurrency=\{value}")
    None => ()
  }
  if parts.length() == 0 {
    return ""
  }
  let mut out = "limits:\n"
  for part in parts {
    out += "  \{part}\n"
  }
  out
}
