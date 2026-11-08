///|
// `moonless delete <name>` removes a deployed function and its server data.
async fn cli_delete(
  flags : Array[String],
  server : String,
) -> Unit raise CliError {
  let name = parse_delete_name(flags)
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
  println("deleted \{name}")
}

///|
fn parse_delete_name(flags : Array[String]) -> String raise CliError {
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
    raise CliError("unexpected argument '\{flags[i]}' for delete")
  }
  if name == "" {
    raise CliError("usage: moonless delete <name>")
  }
  name
}
