///|
async fn main {
  let url = @env.get_env_var("MOONLESS_REDIS_URL").unwrap_or(
    "redis://127.0.0.1:6379",
  )
  let client = @redis.connect_with_url(url)
  let result = client.incr("moonless:example:counter")
  client.close()
  match result {
    Ok(count) => println(count)
    Err(message) => fail("Redis INCR failed: \{message}")
  }
}
