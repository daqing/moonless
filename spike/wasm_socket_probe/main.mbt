///|
async fn main {
  let conn = @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:9911"))
  conn.write("hello over tcp from a wasm module\n")
  if conn.read_some() is Some(reply) {
    println("wasm got reply: \{@utf8.decode(reply)}")
  } else {
    println("connection closed without reply")
  }
  conn.close()
}
