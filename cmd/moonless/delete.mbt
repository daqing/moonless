///|
// `moonless delete <name>...` removes deployed functions and their server data.
async fn cli_delete(
  flags : Array[String],
  server : String,
  out~ : CliOut = CliOut::stdout(),
) -> Unit raise CliError {
  for name in parse_delete_names(flags) {
    delete_function(name, server, out~)
  }
}

///|
async fn delete_function(
  name : String,
  server : String,
  out~ : CliOut = CliOut::stdout(),
) -> Unit raise CliError {
  let url = server + "/api/functions/\{name}"
  let headers : @http.Headers = Map([])
  let (response, body) = @async.with_timeout(
    30_000,
    () => @http.request(url, @http.Delete, headers, ""),
    error=CliError("delete request for '\{name}' timed out"),
  ) catch {
    CliError(_) as err => raise err
    _ =>
      raise CliError(
        "cannot reach the moonless server at \{server}\n(hint: is the stack running? try 'docker compose up -d')",
      )
  }
  let response_body = body.text() catch { _ => "" }
  if response.code == 404 {
    raise CliError(
      "unknown function '\{name}'\n(hint: run 'moonless list' to see deployed functions)",
    )
  }
  if response.code != 200 {
    raise CliError(
      "delete failed for '\{name}' (HTTP \{response.code}): \{response_body}",
    )
  }
  out.write("deleted \{name}\n")
}

///|
fn parse_delete_names(flags : Array[String]) -> Array[String] raise CliError {
  let names : Array[String] = []
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
    names.push(flags[i])
    i += 1
  }
  if names.length() == 0 {
    raise CliError("usage: moonless delete <name>...")
  }
  names
}
