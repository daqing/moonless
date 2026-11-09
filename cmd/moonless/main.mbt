///|
// The moonless CLI: deploy and operate functions through a running gateway.

///|
#derive(Debug)
priv suberror CliError {
  CliError(String)
}

///|
async fn main {
  cli_main(@env.args()) catch {
    CliError(message) =>
      @stdio.stderr.write("error: \{message}\n(run 'moonless' for usage)\n")
  }
}

///|
async fn cli_main(
  args : Array[String],
  out~ : CliOut = CliOut::stdout(),
) -> Unit raise CliError {
  // args[0] is the executable; the rest are the user's command line.
  let rest : Array[String] = []
  for i in 1..<args.length() {
    rest.push(args[i])
  }
  if rest.length() == 0 {
    print_usage(out~)
    return
  }
  let command = rest[0]
  let flags : Array[String] = []
  for i in 1..<rest.length() {
    flags.push(rest[i])
  }
  let server = resolve_server(flags)
  match command {
    "deploy" => cli_deploy(server, out~)
    "list" => cli_list(flags, server, out~)
    "show" => cli_show(flags, server, out~)
    "delete" => cli_delete(flags, server, out~)
    "logs" => cli_logs(flags, server, out~)
    "runs" => cli_runs(flags, server, out~)
    "rollback" => cli_rollback(flags, server, out~)
    "help" | "--help" | "-h" => print_usage(out~)
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
async fn print_usage(out~ : CliOut = CliOut::stdout()) -> Unit noraise {
  out.write("moonless — deploy and operate serverless MoonBit functions\n")
  out.write("\n")
  out.write("Usage:\n")
  out.write(
    "  moonless deploy [--server URL]     package the current project and deploy it\n",
  )
  out.write("  moonless list   [-q] [--server URL]\n")
  out.write(
    "                                     list deployed functions (-q hides the header)\n",
  )
  out.write("  moonless show <name> [--server URL]\n")
  out.write(
    "                                     show a function's manifest and build details\n",
  )
  out.write("  moonless delete <name>... [--server URL]\n")
  out.write("                                     remove deployed functions\n")
  out.write(
    "  moonless logs <name> [--tail N] [--source http|cron|s3] [--since TS] [--follow] [--server URL]\n",
  )
  out.write(
    "                                     show the last runs of a function\n",
  )
  out.write("  moonless runs <name> [--tail N] [--server URL]\n")
  out.write(
    "                                     show recent invocations (source, exit, duration)\n",
  )
  out.write("  moonless rollback <name> [--server URL]\n")
  out.write(
    "                                     switch to the previous build\n",
  )
  out.write("\n")
  out.write("Environment:\n")
  out.write(
    "  MOONLESS_SERVER  gateway base URL (default http://127.0.0.1:8080)\n",
  )
}
