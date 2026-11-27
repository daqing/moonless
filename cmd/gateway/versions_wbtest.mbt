///|
async test "versions clear removes older builds and keeps the active one" {
  let data_root = @fs.tmpdir(prefix="moonless-gw-versions-")
  let cfg = test_config(data_root, 65534)
  registry_set(
    cfg,
    @shared.RegistryRecord(
      name="hello-fn",
      manifest=@shared.Manifest(name="hello-fn"),
      build_id="b-2001",
      updated_at="2026-11-08T00:00:00.000Z",
      history=["b-1001", "b-1501", "b-2001"],
    ),
  )
  write_fixture_files(data_root, [
    ("functions/hello-fn/b-1001/func.wasm", "old"),
    ("functions/hello-fn/b-1501/func.wasm", "older"),
    ("functions/hello-fn/b-2001/func.wasm", "current"),
    ("builds/b-1001/src/main.mbt", "old"),
    ("builds/b-1501/src/main.mbt", "older"),
    ("builds/b-2001/src/main.mbt", "current"),
  ])
  let (gateway_server, gateway_port) = fixture_server()
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(gateway_server, gateway_router(cfg))
    })
    let base_url = "http://127.0.0.1:\{gateway_port}"
    let headers : @http.Headers = Map([])
    let (response, body) = @http.request(
      base_url + "/api/functions/hello-fn/versions/clear",
      @http.Post,
      headers,
      "",
    )
    assert_eq(response.code, 200)
    assert_true(body.text().contains("\"buildId\":\"b-2001\""))
    assert_true(body.text().contains("\"removed\":[\"b-1001\",\"b-1501\"]"))
    guard registry_all(cfg).get("hello-fn") is Some(record) else {
      fail("function disappeared")
    }
    assert_eq(record.build_id, "b-2001")
    assert_eq(record.history, ["b-2001"])
    assert_false(@fs.exists(data_root + "/functions/hello-fn/b-1001"))
    assert_false(@fs.exists(data_root + "/functions/hello-fn/b-1501"))
    assert_true(@fs.exists(data_root + "/functions/hello-fn/b-2001/func.wasm"))
    assert_false(@fs.exists(data_root + "/builds/b-1001"))
    assert_false(@fs.exists(data_root + "/builds/b-1501"))
    assert_true(@fs.exists(data_root + "/builds/b-2001/src/main.mbt"))
    let (again, again_body) = @http.request(
      base_url + "/api/functions/hello-fn/versions/clear",
      @http.Post,
      headers,
      "",
    )
    assert_eq(again.code, 200)
    assert_true(again_body.text().contains("\"removed\":[]"))
    let (missing, _) = @http.request(
      base_url + "/api/functions/ghost/versions/clear",
      @http.Post,
      headers,
      "",
    )
    assert_eq(missing.code, 404)
    gateway_server.close()
  })
}
