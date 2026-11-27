///|
// max_connection admits at most N concurrent HTTP clients per function. The
// first request holds the only slot while it runs; a second request is
// rejected with 429 without reaching the runner; once the first finishes, the
// slot is free again.
async test "max_connection rejects excess clients and releases the slot" {
  let (runner_server, runner_port) = fixture_server()
  let (gateway_server, gateway_port) = fixture_server()
  let data_root = @fs.tmpdir(prefix="moonless-gw-test-")
  let gate = @semaphore.Semaphore(1, initial_value=0)
  let entered = @semaphore.Semaphore(1, initial_value=0)
  let runs : Ref[Int32] = Ref(0)
  let runner = @shared.Router::new()
  runner.add(
    @shared.route(http_method=@http.Post, pattern="/run", handler=ctx => {
      let _ = @shared.read_json_body(ctx)
      runs.val = runs.val + 1
      entered.release()
      gate.acquire()
      gate.release()
      @shared.send_json(
        ctx.conn,
        200,
        @shared.RunResult(stdout="ok\n", exit_code=0).to_json(),
      )
    }),
  )
  @async.with_task_group(group => {
    let cfg : GatewayConfig = {
      data_root,
      builder_url: "http://127.0.0.1:65534",
      runner_url: "http://127.0.0.1:\{runner_port}",
      registry_lock: @async.Mutex::Mutex(),
      runner_registry: RunnerRegistry::RunnerRegistry(),
      connections: Map([]),
    }
    registry_set(
      cfg,
      @shared.RegistryRecord(
        name="limited-fn",
        manifest=@shared.Manifest(
          name="limited-fn",
          triggers=@shared.ManifestTriggers(http_enabled=true),
          limits=@shared.FunctionLimits(max_connection=Some(1)),
        ),
        build_id="b-1",
        updated_at="2026-11-25T00:00:00.000Z",
      ),
    )
    group.spawn_bg(no_wait=true, () => @shared.serve_on(runner_server, runner))
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(gateway_server, gateway_router(cfg))
    })
    let first_status : Ref[Int32] = Ref(0)
    let finished = @semaphore.Semaphore(1, initial_value=0)
    group.spawn_bg(() => {
      let (response, _) = @http.get(
        "http://127.0.0.1:\{gateway_port}/fn/limited-fn",
      )
      first_status.val = response.code
      finished.release()
    })
    // The first request is now inside the runner and owns the only slot.
    entered.acquire()
    let (rejected, body) = @http.get(
      "http://127.0.0.1:\{gateway_port}/fn/limited-fn",
    )
    assert_eq(rejected.code, 429)
    assert_true(body.text().contains("max_connection=1"))
    // The rejected request must never reach the runner.
    assert_eq(runs.val, 1)
    gate.release()
    finished.acquire()
    assert_eq(first_status.val, 200)
    // Let the gateway handler unwind so its deferred release has run.
    @async.sleep(20)
    let (admitted, _) = @http.get(
      "http://127.0.0.1:\{gateway_port}/fn/limited-fn",
    )
    assert_eq(admitted.code, 200)
    assert_eq(runs.val, 2)
    gateway_server.close()
    runner_server.close()
  })
}
