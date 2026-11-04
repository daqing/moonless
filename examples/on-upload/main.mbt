///|
fn main {
  match @env.get_env_var("MOONLESS_EVENT") {
    Some(event) => eprintln("on-upload received: \{event}")
    None => eprintln("on-upload received no event")
  }
}
