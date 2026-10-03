///|
// Subcommand entry point for logs; deploy lives in deploy.mbt and list in
// listing.mbt.

///|
fn cli_logs(flags : Array[String], server : String) -> Unit raise CliError {
  ignore(flags)
  ignore(server)
  raise CliError("logs is not implemented yet")
}
