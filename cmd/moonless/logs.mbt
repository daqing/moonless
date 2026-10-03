///|
// `moonless logs <name> [--tail N]`: the last runs of a function.
// --follow streaming is deferred (T12.4).

///|
async fn cli_logs(
  flags : Array[String],
  server : String,
) -> Unit raise CliError {
  let parsed = parse_logs_args(flags)
  let response = @shared.http_get(
    server + "/api/functions/\{parsed.name}/logs?tail=\{parsed.tail}",
    timeout_ms=30_000,
  ) catch {
    _ =>
      raise CliError(
        "cannot reach the moonless server at \{server}\n(hint: is the stack running? try 'docker compose up -d')",
      )
  }
  if response.status != 200 {
    raise CliError(
      "no logs for function '\{parsed.name}'\n(hint: check the name with 'moonless list', or trigger it first: curl \{server}/fn/\{parsed.name})",
    )
  }
  @stdio.stdout.write(response.body + "\n") catch {
    _ => ()
  }
}

///|
priv struct LogsArgs {
  name : String
  tail : Int
}

///|
// Positional name plus --tail N; --server flags were consumed by the
// dispatcher and are skipped here.
fn parse_logs_args(flags : Array[String]) -> LogsArgs raise CliError {
  let mut name = ""
  let mut tail = 50
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
    raise CliError("unexpected argument '\{flag}' for logs")
  }
  if name == "" {
    raise CliError("usage: moonless logs <name> [--tail N]")
  }
  { name, tail, }
}
