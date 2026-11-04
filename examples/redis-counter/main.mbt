///|
fn redis_address(url : String) -> (String, Int32) raise {
  guard url.has_prefix("redis://") else {
    fail("MOONLESS_REDIS_URL must use the redis:// scheme")
  }
  let address = url[8:]
  match address.split_once(":") {
    Some((host, port)) =>
      (host.to_owned(), @string.parse_int(port) catch { _ => 6379 })
    None => (address.to_owned(), 6379)
  }
}

///|
async fn main {
  let url = @env.get_env_var("MOONLESS_REDIS_URL").unwrap_or(
    "redis://127.0.0.1:6379",
  )
  let (host, port) = redis_address(url)
  let client = @redis.connect(host, port~)
  let result = client.incr("moonless:example:counter")
  client.close()
  match result {
    Ok(count) => println(count)
    Err(message) => fail("Redis INCR failed: \{message}")
  }
}
