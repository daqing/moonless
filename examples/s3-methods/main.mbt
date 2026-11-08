///|
// Log the S3 trigger event so the demo script can wait for each method.
fn main {
  match @env.get_env_var("MOONLESS_EVENT") {
    Some(event) => eprintln("s3-methods received: \{event}")
    None => eprintln("s3-methods received no event")
  }
}
