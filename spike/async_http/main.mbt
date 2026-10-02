///|
async fn main {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:8899"))
  println("spike listening on http://127.0.0.1:8899")
  server.run_forever() <| ((request, body, conn) => {
    match (request.meth, request.path) {
      (Get, "/hello") =>
        conn
        ..send_response(200, "OK", extra_headers={
          "Content-Type": "text/plain",
        })
        ..write_string("hello from async http spike\n")
        .end_response()
      (Post, "/echo") => {
        let text = body.read_all().text()
        // a raise inside the handler yields an empty response to the client
        // (the server survives), so errors must be caught here
        let parsed : Json = @json.parse(text) catch { _ => "" }
        let n : Double? = match parsed {
          Object(obj) =>
            match obj.get("n") {
              Some(Number(v, ..)) => Some(v)
              _ => None
            }
          _ => None
        }
        match n {
          Some(n) => {
            // simulate a slow function body, to prove requests run concurrently
            @async.sleep(500)
            let payload : Json = { "doubled": n * 2 }
            conn
            ..send_response(200, "OK", extra_headers={
              "Content-Type": "application/json",
            })
            ..write_string(payload.stringify())
            .end_response()
          }
          None =>
            conn
            ..send_response(400, "Bad Request")
            ..write_string("expected {\"n\": <number>}\n")
            .end_response()
        }
      }
      _ =>
        conn
        ..send_response(404, "Not Found")
        ..write_string("not found\n")
        .end_response()
    }
  })
}
