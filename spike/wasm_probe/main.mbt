///|
fn main {
  match @env.get_env_var("MOONLESS_EVENT") {
    Some(event) => println("got event: \{event}")
    None => println("no event")
  }
}
