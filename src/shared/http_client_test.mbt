///|
async test "http client helpers against a local test server" {
  let router = @shared.Router::new()
  router.add(
    @shared.route(http_method=@http.Get, pattern="/answer", handler=ctx => {
      @shared.send_json(ctx.conn, 200, { "n": 42 })
    }),
  )
  router.add(
    @shared.route(http_method=@http.Post, pattern="/double", handler=ctx => {
      let json = @shared.read_json_body(ctx)
      guard json is Object(obj) && obj.get("n") is Some(Number(n, ..)) else {
        @shared.send_text(ctx.conn, 400, "expected {\"n\": <number>}")
      }
      @shared.send_json(ctx.conn, 200, { "doubled": n * 2 })
    }),
  )
  router.add(
    @shared.route_any(pattern="/slow", handler=ctx => {
      @async.sleep(300)
      @shared.send_text(ctx.conn, 200, "finally")
    }),
  )
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:18472"))
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => @shared.serve_on(server, router))
    let response = @shared.http_get("http://127.0.0.1:18472/answer")
    assert_eq(response.status, 200)
    assert_eq(response.body, "{\"n\":42}")
    let json = @shared.http_get_json("http://127.0.0.1:18472/answer")
    assert_eq(json.stringify(), "{\"n\":42}")
    let payload : Json = { "n": 21 }
    let json = @shared.http_post_json("http://127.0.0.1:18472/double", payload)
    assert_eq(json.stringify(), "{\"doubled\":42}")
  })
}

///|
async test "http client helper honors its timeout" {
  let router = @shared.Router::new()
  router.add(
    @shared.route_any(pattern="/slow", handler=ctx => {
      @async.sleep(500)
      @shared.send_text(ctx.conn, 200, "finally")
    }),
  )
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:18473"))
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => @shared.serve_on(server, router))
    try @shared.http_get("http://127.0.0.1:18473/slow", timeout_ms=80) catch {
      @shared.HttpError(message) => assert_true(message.contains("timed out"))
      _ => fail("expected HttpError")
    } noraise {
      _ => fail("expected the slow request to time out")
    }
  })
}
