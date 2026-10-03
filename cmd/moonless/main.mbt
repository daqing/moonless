///|
// The moonless CLI: deploy, list, and logs against a running gateway.

///|
priv suberror CliError {
  CliError(String)
} derive(Debug)

///|
async fn main {
  cli_main(@env.args()) catch {
    CliError(message) =>
      @stdio.stderr.write("error: \{message}\n(run 'moonless' for usage)\n")
  }
}

///|
fn cli_main(args : Array[String]) -> Unit raise CliError {
  // args[0] is the executable; the rest are the user's command line.
  let rest : Array[String] = []
  for i in 1..<args.length() {
    rest.push(args[i])
  }
  if rest.length() == 0 {
    print_usage()
    return
  }
  let command = rest[0]
  let flags : Array[String] = []
  for i in 1..<rest.length() {
    flags.push(rest[i])
  }
  let server = resolve_server(flags)
  match command {
    "deploy" => cli_deploy(server)
    "list" => cli_list(server)
    "logs" => cli_logs(flags, server)
    "help" | "--help" | "-h" => print_usage()
    other => raise CliError("unknown command '\{other}'")
  }
}

///|
// --server <url> or --server=<url> override MOONLESS_SERVER.
fn resolve_server(flags : Array[String]) -> String raise CliError {
  let mut i = 0
  while i < flags.length() {
    if flags[i] == "--server" {
      if i + 1 >= flags.length() {
        raise CliError("--server needs a URL argument")
      }
      return flags[i + 1]
    }
    if flags[i].has_prefix("--server=") {
      return flags[i][9:].to_owned()
    }
    i += 1
  }
  @env.get_env_var("MOONLESS_SERVER").unwrap_or("http://127.0.0.1:8080")
}

///|
fn print_usage() -> Unit {
  println("moonless — deploy and operate serverless MoonBit functions")
  println("")
  println("Usage:")
  println(
    "  moonless deploy [--server URL]     package the current project and deploy it",
  )
  println("  moonless list   [--server URL]     list deployed functions")
  println("  moonless logs <name> [--tail N] [--server URL]")
  println(
    "                                     show the last runs of a function",
  )
  println("")
  println("Environment:")
  println("  MOONLESS_SERVER  gateway base URL (default http://127.0.0.1:8080)")
}
