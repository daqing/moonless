///|
async test "registered runner receives the module and selected build" {
  let data_root = @fs.tmpdir(prefix="moonless-gw-runners-")
  let cfg = test_config(data_root, 65534)
  let artifact = data_root + "/functions/remote-fn/b-remote"
  @fs.mkdir(artifact, recursive=true, allow_exist=true)
  @fs.write_file(artifact + "/func.wasm", "wasm-bytes")
  registry_set(
    cfg,
    @shared.RegistryRecord(
      name="remote-fn",
      manifest=@shared.Manifest(name="remote-fn"),
      build_id="b-remote",
      updated_at="2026-11-05T00:00:00.000Z",
      history=["b-remote"],
    ),
  )
  let uploaded = Ref("")
  let run_request = Ref("")
  let node = @shared.Router::new()
  node.add(
    @shared.route(http_method=@http.Post, pattern="/modules", handler=ctx => {
      uploaded.val = @shared.read_json_body(ctx).stringify()
      @shared.send_json(ctx.conn, 200, Json::object({ "ok": true }))
    }),
  )
  node.add(
    @shared.route(http_method=@http.Post, pattern="/run", handler=ctx => {
      run_request.val = @shared.read_json_body(ctx).stringify()
      @shared.send_json(
        ctx.conn,
        200,
        @shared.RunResult(stdout="remote ok\n", exit_code=0).to_json(),
      )
    }),
  )
  let node_port = fixture_listen_port()
  let gateway_port = fixture_listen_port()
  @async.with_task_group(group => {
    let node_server = @http.Server(
      @socket.Addr::parse("127.0.0.1:\{node_port}"),
      reuse_addr=true,
    )
    let gateway_server = @http.Server(
      @socket.Addr::parse("127.0.0.1:\{gateway_port}"),
      reuse_addr=true,
    )
    group.spawn_bg(no_wait=true, () => @shared.serve_on(node_server, node))
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(gateway_server, gateway_router(cfg))
    })
    let node_url = "http://127.0.0.1:\{node_port}"
    let registration : Json = { "id": "node-2", "url": node_url }
    let response = @shared.http_post_json(
      "http://127.0.0.1:\{gateway_port}/api/runners/register",
      registration,
    )
    assert_true(response.stringify().contains("\"runners\":1"))
    let event = @shared.Event::Http(
      @shared.HttpEventData(
        http_method="GET",
        path="/fn/remote-fn",
        query="",
        body="",
      ),
    )
    let first = dispatch_run(cfg, "remote-fn", event)
    assert_eq(first.exit_code, 127)
    let second = dispatch_run(cfg, "remote-fn", event)
    assert_eq(second.exit_code, 0)
    assert_eq(second.stdout, "remote ok\n")
    assert_true(uploaded.val.contains("b-remote"))
    assert_true(uploaded.val.contains("d2FzbS1ieXRlcw=="))
    assert_true(run_request.val.contains("\"buildId\":\"b-remote\""))
    node_server.close()
    gateway_server.close()
  })
}
