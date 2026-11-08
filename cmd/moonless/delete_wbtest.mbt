///|
test "parse_delete_names handles server flags and rejects missing names" {
  assert_eq(parse_delete_names(["hello"]), ["hello"])
  assert_eq(parse_delete_names(["hello", "world"]), ["hello", "world"])
  assert_eq(parse_delete_names(["--server", "http://x:1", "hello"]), ["hello"])
  assert_eq(parse_delete_names(["hello", "--server=http://x:1"]), ["hello"])
  try parse_delete_names([]) catch {
    CliError(message) => assert_true(message.contains("usage: moonless delete"))
  } noraise {
    _ => fail("expected usage error for missing name")
  }
}

///|
async test "delete calls the management API and reports unknown functions" {
  let deleted : Array[String] = []
  let router = @shared.Router::new()
  router.add(
    @shared.route(http_method=@http.Delete, pattern="/api/functions/:name", handler=ctx => {
      let name = ctx.params["name"]
      if name == "ghost" {
        @shared.send_text(ctx.conn, 404, "unknown function\n")
      } else {
        deleted.push(name)
        @shared.send_json(ctx.conn, 200, { "name": name })
      }
    }),
  )
  let port = fixture_listen_port()
  let server = @http.Server(
    @socket.Addr::parse("127.0.0.1:\{port}"),
    reuse_addr=true,
  )
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => @shared.serve_on(server, router))
    let base_url = "http://127.0.0.1:\{port}"
    cli_main(["moonless", "delete", "hello-fn", "bye-fn", "--server", base_url])
    let expected : Array[String] = ["hello-fn", "bye-fn"]
    assert_eq(deleted, expected)
    try cli_delete(["ghost"], base_url) catch {
      CliError(message) => {
        assert_true(message.contains("unknown function 'ghost'"))
        assert_true(message.contains("moonless list"))
      }
    } noraise {
      _ => fail("expected failure for unknown function")
    }
    server.close()
  })
}

///|
async test "delete reports an unreachable server" {
  try cli_delete(["hello"], "http://127.0.0.1:1") catch {
    CliError(message) => {
      assert_true(message.contains("cannot reach the moonless server"))
      assert_true(message.contains("hint"))
    }
  } noraise {
    _ => fail("expected failure for unreachable server")
  }
}
