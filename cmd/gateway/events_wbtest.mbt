///|
async test "SeaweedFS webhook intake accepts concurrent payloads" {
  let data_root = @fs.tmpdir(prefix="moonless-gw-events-")
  let gateway_port = fixture_listen_port()
  @async.with_task_group(group => {
    let gateway_server = @http.Server(
      @socket.Addr::parse("127.0.0.1:\{gateway_port}"),
      reuse_addr=true,
    )
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(
        gateway_server,
        gateway_router(test_config(data_root, 65534)),
      )
    })
    let payload : Json = {
      "event_type": "create",
      "key": "/buckets/uploads/report.csv",
      "message": {},
    }
    @async.with_task_group(clients => {
      for _ in 0..<2 {
        clients.spawn_bg(() => {
          let response = @shared.http_post_json(
            "http://127.0.0.1:\{gateway_port}/api/events",
            payload,
          )
          assert_eq(response.stringify(), "[]")
        })
      }
    })
    gateway_server.close()
  })
}
