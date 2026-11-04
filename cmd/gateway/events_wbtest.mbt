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

///|
async fn recorded_filer_event(name : String) -> Json {
  let source = @fs.read_file("cmd/gateway/testdata/seaweedfs_\{name}.json").text()
  @json.parse(source)
}

///|
async test "SeaweedFS adapter maps recorded object events" {
  let cases = [
    ("create", "put", "webhook/T9.4-nested.txt"),
    ("update", "put", "T9.3-verified.txt"),
    ("delete", "delete", "T9.3-verified.txt"),
  ]
  for case in cases {
    let (name, event_name, key) = case
    let event = adapt_seaweedfs_event(recorded_filer_event(name))
    guard event is Some(@shared.Event::S3(data)) else {
      fail("expected an s3 event for \{name}")
    }
    assert_eq(data.event_name, event_name)
    assert_eq(data.bucket, "moonless-smoke")
    assert_eq(data.key, key)
  }
}

///|
async test "SeaweedFS adapter ignores directories and non-S3 paths" {
  assert_true(adapt_seaweedfs_event(recorded_filer_event("directory")) is None)
  let non_s3 : Json = {
    "event_type": "create",
    "key": "/documents/report.csv",
    "message": { "new_entry": { "is_directory": false } },
  }
  assert_true(adapt_seaweedfs_event(non_s3) is None)
  let bucket_root : Json = {
    "event_type": "create",
    "key": "/buckets/uploads",
    "message": {},
  }
  assert_true(adapt_seaweedfs_event(bucket_root) is None)
  let rename : Json = {
    "event_type": "rename",
    "key": "/buckets/uploads/old.csv",
    "message": {},
  }
  assert_true(adapt_seaweedfs_event(rename) is None)
}
