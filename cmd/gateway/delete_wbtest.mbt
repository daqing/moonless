///|
async test "delete unregisters a function and removes only its data" {
  let data_root = @fs.tmpdir(prefix="moonless-gw-delete-")
  let cfg = test_config(data_root, 65534)
  registry_set(
    cfg,
    @shared.RegistryRecord(
      name="doomed",
      manifest=@shared.Manifest(name="doomed"),
      build_id="b-2001",
      updated_at="2026-11-08T00:00:00.000Z",
      history=["b-1001", "b-2001"],
    ),
  )
  registry_set(
    cfg,
    @shared.RegistryRecord(
      name="keeper",
      manifest=@shared.Manifest(name="keeper"),
      build_id="b-3001",
      updated_at="2026-11-08T00:00:00.000Z",
      history=["b-3001"],
    ),
  )
  write_fixture_files(data_root, [
    ("functions/doomed/b-1001/func.wasm", "old"),
    ("functions/doomed/b-2001/func.wasm", "current"),
    ("functions/keeper/b-3001/func.wasm", "keep"),
    ("logs/doomed/2026-11-08.000000.log", "delete me"),
    ("logs/keeper/2026-11-08.000000.log", "keep me"),
    ("builds/b-1001/src/main.mbt", "old"),
    ("builds/b-2001/src/main.mbt", "current"),
    ("builds/b-3001/src/main.mbt", "keep"),
  ])
  let gateway_port = fixture_listen_port()
  @async.with_task_group(group => {
    let gateway_server = @http.Server(
      @socket.Addr::parse("127.0.0.1:\{gateway_port}"),
      reuse_addr=true,
    )
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(gateway_server, gateway_router(cfg))
    })
    let base_url = "http://127.0.0.1:\{gateway_port}"
    let headers : @http.Headers = Map([])
    let (response, body) = @http.request(
      base_url + "/api/functions/doomed",
      @http.Delete,
      headers,
      "",
    )
    assert_eq(response.code, 200)
    assert_true(body.text().contains("\"name\":\"doomed\""))
    assert_true(registry_all(cfg).get("doomed") is None)
    assert_true(registry_all(cfg).get("keeper") is Some(_))
    let records = @shared.http_get_json(base_url + "/api/functions")
    assert_false(records.stringify().contains("doomed"))
    assert_true(records.stringify().contains("keeper"))
    let detail = @shared.http_get(base_url + "/api/functions/doomed")
    assert_eq(detail.status, 404)
    assert_false(@fs.exists(data_root + "/functions/doomed"))
    assert_false(@fs.exists(data_root + "/logs/doomed"))
    assert_false(@fs.exists(data_root + "/builds/b-1001"))
    assert_false(@fs.exists(data_root + "/builds/b-2001"))
    assert_true(@fs.exists(data_root + "/functions/keeper/b-3001/func.wasm"))
    assert_true(@fs.exists(data_root + "/logs/keeper/2026-11-08.000000.log"))
    assert_true(@fs.exists(data_root + "/builds/b-3001/src/main.mbt"))
    let (missing, _) = @http.request(
      base_url + "/api/functions/doomed",
      @http.Delete,
      headers,
      "",
    )
    assert_eq(missing.code, 404)
    gateway_server.close()
  })
}

///|
test "delete cleanup accepts only safe path components" {
  assert_true(safe_data_component("hello-fn"))
  assert_true(safe_data_component("b-1234"))
  assert_false(safe_data_component(""))
  assert_false(safe_data_component("."))
  assert_false(safe_data_component(".."))
  assert_false(safe_data_component("functions/other"))
  assert_false(safe_data_component("..\\other"))
}
