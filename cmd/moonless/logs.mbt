///|
// `moonless logs <name> [--tail N] [--source http|cron|s3] [--since TS]
// [--follow]`: print recent logs, then poll once per second when following.

///|
async fn cli_logs(
  flags : Array[String],
  server : String,
  out~ : CliOut = CliOut::stdout(),
) -> Unit raise CliError {
  let parsed = parse_logs_args(flags)
  let url = logs_url(parsed, server)
  let response = @shared.http_get(url, timeout_ms=30_000) catch {
    _ =>
      raise CliError(
        "cannot reach the moonless server at \{server}\n(hint: is the stack running? try 'docker compose up -d')",
      )
  }
  if response.status == 200 {
    out.write(response.body + "\n")
  } else if !parsed.follow || response.status != 404 {
    raise CliError(
      "no logs for function '\{parsed.name}'\n(hint: check the name with 'moonless list', or trigger it first: curl \{server}/fn/\{parsed.name})",
    )
  }
  if parsed.follow {
    let mut previous = if response.status == 200 { response.body } else { "" }
    for ;; {
      @async.sleep(1000)
      let next = @shared.http_get(url, timeout_ms=30_000) catch {
        _ => continue
      }
      if next.status != 200 {
        continue
      }
      let delta = follow_delta(previous, next.body)
      if delta != "" {
        out.write(delta)
      }
      previous = next.body
    }
  }
}

///|
fn logs_url(parsed : LogsArgs, server : String) -> String {
  let mut url = server +
    "/api/functions/\{parsed.name}/logs?tail=\{parsed.tail}"
  if parsed.source != "" {
    url += "&source=\{parsed.source}"
  }
  if parsed.since != "" {
    url += "&since=\{parsed.since}"
  }
  url
}

///|
// Returns only the new suffix between two tail responses. The largest overlap
// handles both an unchanged tail and records leaving the sliding window.
fn follow_delta(previous : String, current : String) -> String {
  if previous == "" {
    return current
  }
  if current == "" || previous == current {
    return ""
  }
  let mut overlap = if previous.length() < current.length() {
    previous.length()
  } else {
    current.length()
  }
  while overlap > 0 {
    let start = previous.length() - overlap
    let mut matches = true
    for i in 0..<overlap {
      if previous[start + i] != current[i] {
        matches = false
        break
      }
    }
    if matches {
      return current[overlap:].to_owned()
    }
    overlap -= 1
  }
  current
}

///|
priv struct LogsArgs {
  name : String
  tail : Int32
  source : String
  since : String
  follow : Bool
}

///|
// Positional name plus filtering and --follow; --server flags are skipped here.
fn parse_logs_args(flags : Array[String]) -> LogsArgs raise CliError {
  let mut name = ""
  let mut tail = 50
  let mut source = ""
  let mut since = ""
  let mut follow = false
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
    if flag == "--follow" {
      follow = true
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
    if flag == "--source" {
      if i + 1 >= flags.length() {
        raise CliError("--source needs http, cron, or s3")
      }
      source = parse_source_flag(flags[i + 1])
      i += 2
      continue
    }
    if flag.has_prefix("--source=") {
      source = parse_source_flag(flag[9:])
      i += 1
      continue
    }
    if flag == "--since" {
      if i + 1 >= flags.length() {
        raise CliError("--since needs an ISO-8601 timestamp argument")
      }
      since = flags[i + 1]
      i += 2
      continue
    }
    if flag.has_prefix("--since=") {
      since = flag[8:].to_owned()
      i += 1
      continue
    }
    if name == "" {
      name = flag
      i += 1
      continue
    }
    raise CliError("unexpected argument '\{flag}' for logs")
  }
  if name == "" {
    raise CliError(
      "usage: moonless logs <name> [--tail N] [--source http|cron|s3] [--since TS] [--follow]",
    )
  }
  { name, tail, source, since, follow, }
}

///|
fn parse_source_flag(value : StringView) -> String raise CliError {
  let source = value.to_owned()
  if source == "http" || source == "cron" || source == "s3" {
    source
  } else {
    raise CliError("--source must be http, cron, or s3 (got '\{source}')")
  }
}
