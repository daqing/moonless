///|
// `moonless runs <name> [--tail N]`: recent invocations of a function with
// their trigger source, exit code, and duration (T8.3).

///|
async fn cli_runs(
  flags : Array[String],
  server : String,
) -> Unit raise CliError {
  let parsed = parse_runs_args(flags)
  let response = @shared.http_get(
    server + "/api/functions/\{parsed.name}/runs?tail=\{parsed.tail}",
    timeout_ms=30_000,
  ) catch {
    _ =>
      raise CliError(
        "cannot reach the moonless server at \{server}\n(hint: is the stack running? try 'docker compose up -d')",
      )
  }
  if response.status != 200 {
    raise CliError(
      "no runs for function '\{parsed.name}'\n(hint: check the name with 'moonless list', or trigger it first: curl \{server}/fn/\{parsed.name})",
    )
  }
  let json = @json.parse(response.body) catch {
    _ => raise CliError("the server sent an unreadable run list")
  }
  guard json is Array(items) else {
    raise CliError("the server sent an unreadable run list")
  }
  @stdio.stdout.write(render_runs_table(items)) catch {
    _ => ()
  }
}

///|
priv struct RunsArgs {
  name : String
  tail : Int32
}

///|
fn parse_runs_args(flags : Array[String]) -> RunsArgs raise CliError {
  let mut name = ""
  let mut tail = 20
  let mut i = 0
  while i < flags.length() {
    let flag = flags[i]
    if flag == "--server" {
      i += 2
      continue
    }
    if flag.has_prefix("--server=") {
      i += 1
      continue
    }
    if flag == "--tail" {
      if i + 1 >= flags.length() {
        raise CliError("--tail needs a number argument")
      }
      tail = @string.parse_int(flags[i + 1]) catch {
        _ => raise CliError("--tail needs a number argument")
      }
      i += 2
      continue
    }
    if flag.has_prefix("--tail=") {
      tail = @string.parse_int(flag[7:]) catch {
        _ => raise CliError("--tail needs a number argument")
      }
      i += 1
      continue
    }
    if name == "" {
      name = flag
      i += 1
      continue
    }
    raise CliError("unexpected argument '\{flag}' for runs")
  }
  if name == "" {
    raise CliError("usage: moonless runs <name> [--tail N]")
  }
  { name, tail, }
}

///|
fn render_runs_table(items : Array[Json]) -> String {
  if items.length() == 0 {
    return "no runs recorded\n"
  }
  let header = "\{pad("TIME", 26)} \{pad("SOURCE", 8)} \{pad("EXIT", 6)} \{pad("DURATION", 10)} TRUNCATED\n"
  let mut out = header
  for item in items {
    guard item is Object(run) else { continue }
    let ts = json_string(run, "ts")
    let source = json_string(run, "source")
    let exit_code = json_string(run, "exitCode")
    let duration = json_string(run, "durationMs")
    let truncated = json_string(run, "truncated")
    out += "\{pad(ts, 26)} \{pad(source, 8)} \{pad(exit_code, 6)} \{pad(duration + "ms", 10)} \{truncated}\n"
  }
  out
}

///|
// Renders a JSON scalar as plain text; missing fields become "-".
fn json_string(obj : Map[String, Json], key : String) -> String {
  match obj.get(key) {
    Some(String(s)) => s
    Some(Number(n, ..)) => n.to_int().to_string()
    Some(True) => "true"
    Some(False) => "false"
    _ => "-"
  }
}
