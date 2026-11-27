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
      manifest=@shared.Manifest(
        name="remote-fn",
        limits=@shared.FunctionLimits(
          timeout_ms=Some(2500),
          concurrency=Some(2),
        ),
      ),
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
  let (node_server, node_port) = fixture_server()
  let (gateway_server, gateway_port) = fixture_server()
  @async.with_task_group(group => {
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
    // Limits ride with the dispatch so remote nodes without the registry
    // volume still honor them.
    assert_true(run_request.val.contains("\"timeoutMs\":2500"))
    assert_true(run_request.val.contains("\"concurrency\":2"))
    node_server.close()
    gateway_server.close()
  })
}

///|
async test "a node that stops re-registering is pruned from placement" {
  let data_root = @fs.tmpdir(prefix="moonless-gw-runners-")
  let cfg = test_config(data_root, 65534)
  let registry = cfg.runner_registry
  registry.lock.acquire()
  // One live node and one whose heartbeat is well past the TTL.
  registry.nodes.push({
    id: "http://live:8082",
    url: "http://live:8082",
    last_seen_ms: @async.now(),
  })
  registry.nodes.push({
    id: "http://stale:8082",
    url: "http://stale:8082",
    last_seen_ms: @async.now() - 200_000L,
  })
  registry.lock.release()
  // The first selection should prune the stale entry, leaving only the live
  // node alongside the implicit node 0.
  let (url, remote) = select_runner(cfg)
  ignore(url)
  ignore(remote)
  registry.lock.acquire()
  defer registry.lock.release()
  assert_eq(registry.nodes.length(), 1)
  assert_eq(registry.nodes[0].id, "http://live:8082")
}
