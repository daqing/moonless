///|
// Subcommand entry points for list and logs; deploy lives in deploy.mbt.

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
