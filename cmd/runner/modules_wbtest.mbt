///|
async test "uploaded wasm executes by build id without a local registry" {
  let fixture_dir = @fs.tmpdir(prefix="moonless-runner-fixture-")
  let wasm = build_fixture_module(fixture_dir, echo_pkg(), echo_main())
  let data_root = @fs.tmpdir(prefix="moonless-runner-remote-")
  let port = fixture_listen_port()
  @async.with_task_group(group => {
    let server = @http.Server(
      @socket.Addr::parse("127.0.0.1:\{port}"),
      reuse_addr=true,
    )
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(server, runner_router(test_config(data_root)))
    })
    let base = "http://127.0.0.1:\{port}"
    let upload = @shared.ModuleUpload(
      name="remote-fn",
      build_id="b-remote",
      wasm=@base64.encode(wasm[:]),
    )
    let response = @shared.http_post_json(base + "/modules", upload.to_json())
    assert_true(response.stringify().contains("\"ok\":true"))
    let result = @shared.http_post_json(
      base + "/run",
      @shared.RunRequest(
        name="remote-fn",
        event=@shared.Event::Http(
          @shared.HttpEventData(
            http_method="GET",
            path="/fn/remote-fn",
            query="",
            body="",
          ),
        ),
        build_id="b-remote",
      ).to_json(),
    )
    let text = result.stringify()
    assert_true(text.contains("\"exitCode\":0"))
    assert_true(text.contains("EVT:"))
    assert_true(text.contains("remote-fn"))
    let (rejected, _) = @http.post(
      base + "/modules",
      "{\"name\":\"../escape\",\"buildId\":\"b\",\"wasm\":\"\"}",
    )
    assert_eq(rejected.code, 400)
    server.close()
  })
}
