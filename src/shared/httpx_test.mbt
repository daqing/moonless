///|
test "match_path captures params and rejects mismatches" {
  let params = @shared.match_path(
    "/api/functions/:name/logs", "/api/functions/hello/logs",
  )
  assert_true(params is Some(_))
  guard params is Some(p) else { fail("unreachable") }
  assert_eq(p["name"], "hello")
  assert_true(
    @shared.match_path("/api/functions/:name/logs", "/api/functions/hello")
    is None,
  )
  assert_true(
    @shared.match_path("/api/functions/:name", "/api/other/hello") is None,
  )
  assert_true(@shared.match_path("/healthz", "/healthz") is Some(_))
  assert_true(@shared.match_path("/healthz", "/ready") is None)
}

///|
async test "router serves requests end to end" {
  let router = @shared.Router::new()
  router.add(
    @shared.route(http_method=@http.Get, pattern="/healthz", handler=ctx => {
      @shared.send_text(ctx.conn, 200, "ok")
    }),
  )
  router.add(
    @shared.route_any(pattern="/fn/:name", handler=ctx => {
      @shared.send_text(ctx.conn, 200, "hello \{ctx.params["name"]}")
    }),
  )
  router.add(
    @shared.route(http_method=@http.Post, pattern="/echo", handler=ctx => {
      let json = @shared.read_json_body(ctx)
      @shared.send_json(ctx.conn, 200, json)
    }),
  )
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:18471"))
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => @shared.serve_on(server, router))
    let (response, body) = @http.get("http://127.0.0.1:18471/healthz")
    assert_eq(response.code, 200)
    assert_eq(body.text(), "ok")
    let (response, body) = @http.get("http://127.0.0.1:18471/fn/hello")
    assert_eq(response.code, 200)
    assert_eq(body.text(), "hello hello")
    let payload : Json = { "n": 3 }
    let (response, body) = @http.post(
      "http://127.0.0.1:18471/echo",
      payload.stringify(),
    )
    assert_eq(response.code, 200)
    assert_eq(body.text(), payload.stringify())
    let (response, _) = @http.get("http://127.0.0.1:18471/missing")
    assert_eq(response.code, 404)
    let no_headers : @http.Headers = Map([])
    let (response, _) = @http.request(
      "http://127.0.0.1:18471/healthz",
      @http.Delete,
      no_headers,
      "",
    )
    assert_eq(response.code, 405)
  })
}
