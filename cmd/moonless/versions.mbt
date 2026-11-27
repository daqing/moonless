///|
// `moonless versions <list|clear> <name>` views or prunes a function's saved
// builds.

///|
async fn cli_versions(
  flags : Array[String],
  server : String,
  out~ : CliOut = CliOut::stdout(),
) -> Unit raise CliError {
  let (action, name) = parse_versions_args(flags)
  match action {
    "list" => cli_versions_list(name, server, out~)
    "clear" => cli_versions_clear(name, server, out~)
    other =>
      raise CliError(
        "unknown versions command '\{other}'\n(hint: use 'moonless versions list|clear <name>')",
      )
  }
}

///|
async fn cli_versions_list(
  name : String,
  server : String,
  out~ : CliOut = CliOut::stdout(),
) -> Unit raise CliError {
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
      "cannot list versions of '\{name}': the server returned \{response.status}",
    )
  }
  let json = @json.parse(response.body) catch {
    _ => raise CliError("the server sent an unreadable function record")
  }
  let record = match decode_record(json) {
    Some(record) => record
    None => raise CliError("the server sent an unreadable function record")
  }
  out.write(render_versions(record))
}

///|
async fn cli_versions_clear(
  name : String,
  server : String,
  out~ : CliOut = CliOut::stdout(),
) -> Unit raise CliError {
  let response = @shared.http_post_json(
    server + "/api/functions/\{name}/versions/clear",
    Json::object(Map([])),
    timeout_ms=30_000,
  ) catch {
    err =>
      raise CliError(
        "cannot clear versions of '\{name}': \{@debug.to_string(err)}",
      )
  }
  guard response is Object(obj) else {
    raise CliError("the server sent an unreadable clear response")
  }
  let removed = @shared.json_field_string_array(obj, "removed") catch {
    _ => raise CliError("the server sent an unreadable clear response")
  }
  let kept = @shared.json_field_string(obj, "buildId") catch {
    _ => raise CliError("the server sent an unreadable clear response")
  }
  if removed.length() == 0 {
    out.write("no saved versions to clear for \{name}\n")
    return
  }
  let noun = if removed.length() == 1 { "version" } else { "versions" }
  if kept == "" {
    out.write("cleared \{removed.length()} saved \{noun} of \{name}\n")
  } else {
    out.write(
      "cleared \{removed.length()} saved \{noun} of \{name} (kept \{kept})\n",
    )
  }
}

///|
fn parse_versions_args(
  flags : Array[String],
) -> (String, String) raise CliError {
  let mut action = ""
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
    if action == "" {
      action = flags[i]
    } else if name == "" {
      name = flags[i]
    } else {
      raise CliError("unexpected argument '\{flags[i]}' for versions")
    }
    i += 1
  }
  if action == "" || name == "" {
    raise CliError("usage: moonless versions <list|clear> <name>")
  }
  (action, name)
}

///|
fn render_versions(record : @shared.RegistryRecord) -> String {
  let builds : Array[String] = []
  for build_id in record.history {
    push_build(builds, build_id)
  }
  if record.build_id != "" {
    push_build(builds, record.build_id)
  }
  if builds.length() == 0 {
    return "no versions saved\n"
  }
  let mut out = "\{pad("BUILD", 20)} CREATED\n"
  for i in 0..<builds.length() {
    let build_id = builds[builds.length() - 1 - i]
    out += "\{pad(build_id, 20)} \{build_created_at(build_id)}\n"
  }
  out
}

///|
fn push_build(builds : Array[String], build_id : String) -> Unit {
  for existing in builds {
    if existing == build_id {
      return
    }
  }
  builds.push(build_id)
}

///|
// Build ids are "b-<epoch milliseconds>"; render that instant as a short,
// UTC wall-clock time. Ids from other sources show "-".
fn build_created_at(build_id : String) -> String {
  guard build_id.has_prefix("b-") else { return "-" }
  let ms = @string.parse_int64(build_id[2:]) catch { _ => return "-" }
  let iso = @shared.format_timestamp(ms)
  iso[:10].to_owned() + " " + iso[11:19].to_owned()
}
