///|
async fn main {
  match @env.get_env_var("MOONLESS_EVENT") {
    Some(event) => {
      eprintln("on-upload received: \{event}")
      let client = @s3.Client(
        @s3.Config(
          @env.get_env_var("AWS_REGION").unwrap(),
          @s3.Credentials(
            @env.get_env_var("AWS_ACCESS_KEY_ID").unwrap(),
            @env.get_env_var("AWS_SECRET_ACCESS_KEY").unwrap(),
          ),
          endpoint=@env.get_env_var("MOONLESS_S3_ENDPOINT").unwrap(),
        ),
      )
      let listed = client.list_objects_v2("uploads")
      eprintln("listed uploads: \{listed.contents.length()} objects")
    }
    None => eprintln("on-upload received no event")
  }
}
