///|
fn main {
  match @env.get_env_var("MOONLESS_EVENT") {
    Some(event) => eprintln("nightly-cleanup received: \{event}")
    None => eprintln("nightly-cleanup received no event")
  }
}
