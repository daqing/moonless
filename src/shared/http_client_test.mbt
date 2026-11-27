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
  let (server, port) = test_server()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => @shared.serve_on(server, router))
    let response = @shared.http_get("http://127.0.0.1:\{port}/answer")
    assert_eq(response.status, 200)
    assert_eq(response.body, "{\"n\":42}")
    let json = @shared.http_get_json("http://127.0.0.1:\{port}/answer")
    assert_eq(json.stringify(), "{\"n\":42}")
    let payload : Json = { "n": 21 }
    let json = @shared.http_post_json(
      "http://127.0.0.1:\{port}/double",
      payload,
    )
    assert_eq(json.stringify(), "{\"doubled\":42}")
  })
}

///|
async test "http client reports status and body when a reply is not JSON" {
  let router = @shared.Router::new()
  router.add(
    @shared.route(http_method=@http.Post, pattern="/plain", handler=ctx => {
      @shared.send_text(ctx.conn, 500, "internal error\n")
    }),
  )
  let (server, port) = test_server()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => @shared.serve_on(server, router))
    let payload : Json = { "n": 1 }
    try
      @shared.http_post_json("http://127.0.0.1:\{port}/plain", payload)
    catch {
      @shared.HttpError(message) => {
        // The status and body must be visible, not just "non-JSON".
        assert_true(message.contains("500"))
        assert_true(message.contains("internal error"))
      }
      _ => fail("expected HttpError")
    } noraise {
      _ => fail("expected a non-JSON body to raise")
    }
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
  let (server, port) = test_server()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => @shared.serve_on(server, router))
    try @shared.http_get("http://127.0.0.1:\{port}/slow", timeout_ms=80) catch {
      @shared.HttpError(message) => assert_true(message.contains("timed out"))
      _ => fail("expected HttpError")
    } noraise {
      _ => fail("expected the slow request to time out")
    }
  })
}
