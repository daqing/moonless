///|
// Subcommand placeholders; T6.2–T6.4 fill them in.

///|
fn cli_deploy(server : String) -> Unit raise CliError {
  ignore(server)
  raise CliError("deploy is not implemented yet")
}

///|
fn cli_list(server : String) -> Unit raise CliError {
  ignore(server)
  raise CliError("list is not implemented yet")
}

///|
fn cli_logs(flags : Array[String], server : String) -> Unit raise CliError {
  ignore(flags)
  ignore(server)
  raise CliError("logs is not implemented yet")
}
