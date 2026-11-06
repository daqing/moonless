///|
// The smallest moonless function: greet and show the trigger context.
fn main {
  match @env.get_env_var("MOONLESS_EVENT") {
    Some(event) => println("hello! triggered by: \{event}")
    None => println("hello!")
  }
}
