///|
async test "rollback switches to the previous or requested historical build" {
  let data_root = @fs.tmpdir(prefix="moonless-gw-rollback-")
  let cfg = test_config(data_root, 65534)
  for build_id in ["b-1001", "b-2001"] {
    let dir = data_root + "/functions/rollback-test/" + build_id
    @fs.mkdir(dir, recursive=true, allow_exist=true)
    @fs.write_file(dir + "/func.wasm", build_id)
  }
  registry_set(
    cfg,
    @shared.RegistryRecord(
      name="rollback-test",
      manifest=@shared.Manifest(name="rollback-test"),
      build_id="b-2001",
      updated_at="2026-11-05T00:00:00.000Z",
      history=["b-1001", "b-2001"],
    ),
  )
  let gateway_port = fixture_listen_port()
  @async.with_task_group(group => {
    let gateway_server = @http.Server(
      @socket.Addr::parse("127.0.0.1:\{gateway_port}"),
      reuse_addr=true,
    )
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(gateway_server, gateway_router(cfg))
    })
    let url = "http://127.0.0.1:\{gateway_port}/api/functions/rollback-test/rollback"
    let response = @shared.http_post_json(url, Json::object(Map([])))
    assert_true(response.stringify().contains("\"buildId\":\"b-1001\""))
    assert_eq(registry_all(cfg)["rollback-test"].build_id, "b-1001")
    let (no_earlier, _) = @http.post(url, "{}")
    assert_eq(no_earlier.code, 400)
    let response = @shared.http_post_json(
      url,
      Json::object({ "buildId": Json::string("b-2001") }),
    )
    assert_true(response.stringify().contains("\"buildId\":\"b-2001\""))
    assert_eq(registry_all(cfg)["rollback-test"].build_id, "b-2001")
    gateway_server.close()
  })
}

///|
async test "deploy history is cumulative and deduplicated" {
  let data_root = @fs.tmpdir(prefix="moonless-gw-history-")
  let cfg = test_config(data_root, 65534)
  registry_set(
    cfg,
    @shared.RegistryRecord(
      name="history-test",
      manifest=@shared.Manifest(name="history-test"),
      build_id="b-1001",
      updated_at="2026-11-05T00:00:00.000Z",
    ),
  )
  assert_eq(build_history(cfg, "history-test", "b-2001"), ["b-1001", "b-2001"])
  assert_eq(build_history(cfg, "history-test", "b-2001"), ["b-1001", "b-2001"])
}
