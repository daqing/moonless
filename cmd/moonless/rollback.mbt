///|
// `moonless rollback <name>` switches a function to its previous build.
async fn cli_rollback(
  flags : Array[String],
  server : String,
  out~ : CliOut = CliOut::stdout(),
) -> Unit raise CliError {
  let name = parse_rollback_name(flags)
  let response = @shared.http_post_json(
    server + "/api/functions/\{name}/rollback",
    Json::object(Map([])),
    timeout_ms=30_000,
  ) catch {
    err =>
      raise CliError("rollback failed for '\{name}': \{@debug.to_string(err)}")
  }
  let record = @shared.RegistryRecord::from_json(response) catch {
    _ => raise CliError("the server sent an unreadable rollback response")
  }
  out.write("rolled back \{record.name} to \{record.build_id}\n")
}

///|
fn parse_rollback_name(flags : Array[String]) -> String raise CliError {
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
    raise CliError("unexpected argument '\{flags[i]}' for rollback")
  }
  if name == "" {
    raise CliError("usage: moonless rollback <name>")
  }
  name
}
