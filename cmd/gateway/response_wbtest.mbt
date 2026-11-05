///|
test "function response parser keeps ordinary stdout unchanged" {
  for text in ["hello", "{\"status\":\"ok\"}\nbody", "not json\nbody"] {
    let parsed = parse_function_response(text)
    assert_eq(parsed.status, 200)
    assert_eq(parsed.body, text)
    assert_true(parsed.headers.is_empty())
  }
}

///|
test "function response parser reads status, headers, and body" {
  let parsed = parse_function_response(
    "{\"status\":201,\"headers\":{\"Content-Type\":\"application/json\",\"X-Test\":\"yes\"}}\n{\"ok\":true}\n",
  )
  assert_eq(parsed.status, 201)
  assert_eq(parsed.body, "{\"ok\":true}\n")
  assert_eq(parsed.headers["Content-Type"], "application/json")
  assert_eq(parsed.headers["X-Test"], "yes")
  let filtered = parse_function_response(
    "{\"headers\":{\"Content-Length\":\"1\",\"X-Test\":\"yes\"}}\nbody",
  )
  assert_eq(filtered.headers.length(), 1)
  assert_eq(filtered.body, "body")
}

///|
async test "HTTP trigger sends the function's status and headers" {
  let runner_port = fixture_listen_port()
  let gateway_port = fixture_listen_port()
  let data_root = @fs.tmpdir(prefix="moonless-gw-response-")
  let fake = FakeRunner(
    result=@shared.RunResult(
      stdout="{\"status\":202,\"headers\":{\"X-Moonless\":\"works\"}}\naccepted\n",
      exit_code=0,
    ),
    last_request=Ref(""),
    installed=Ref(["response-fn"]),
  )
  @async.with_task_group(group => {
    let runner_server = @http.Server(
      @socket.Addr::parse("127.0.0.1:\{runner_port}"),
      reuse_addr=true,
    )
    let gateway_server = @http.Server(
      @socket.Addr::parse("127.0.0.1:\{gateway_port}"),
      reuse_addr=true,
    )
    let cfg : GatewayConfig = {
      data_root,
      builder_url: "http://127.0.0.1:65534",
      runner_url: "http://127.0.0.1:\{runner_port}",
      registry_lock: @async.Mutex::Mutex(),
    }
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(runner_server, fake_runner_router(fake))
    })
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(gateway_server, gateway_router(cfg))
    })
    let (response, body) = @http.get(
      "http://127.0.0.1:\{gateway_port}/fn/response-fn",
    )
    assert_eq(response.code, 202)
    assert_eq(body.text(), "accepted\n")
    assert_eq(
      response.headers.get(@http.CaseInsensitiveString("X-Moonless")),
      Some("works"),
    )
    runner_server.close()
    gateway_server.close()
  })
}
