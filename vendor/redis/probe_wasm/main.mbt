///|
async fn main {
  let client = @redis.connect("127.0.0.1", port=6399)
  let _ = client.set("moonless:wasm-probe", "hello-from-wasm")
  match client.get("moonless:wasm-probe") {
    Ok(v) => println("GET roundtrip OK: \{v}")
    Err(_) => println("GET failed")
  }
  client.close()
}
