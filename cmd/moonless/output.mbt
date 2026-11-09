///|
// CLI output is injected so tests can capture it instead of writing to
// stdout, which the MoonBit test driver reserves for its result events.
priv struct CliOut {
  live : Bool
  buffer : StringBuilder
}

///|
fn CliOut::stdout() -> CliOut {
  { live: true, buffer: StringBuilder(), }
}

///|
#warnings("-unused_value")
fn CliOut::capture() -> CliOut {
  { live: false, buffer: StringBuilder(), }
}

///|
async fn CliOut::write(self : CliOut, text : String) -> Unit noraise {
  if self.live {
    @stdio.stdout.write(text) catch {
      _ => ()
    }
  } else {
    self.buffer.write_string(text)
  }
}

///|
#warnings("-unused_value")
fn CliOut::text(self : CliOut) -> String {
  self.buffer.to_string()
}
