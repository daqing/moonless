///|
// Scheduler tests: registry sync against a fake gateway, dispatch with a
// fake clock, and the skip-if-late policy.

///|
// moon test runs test files in parallel worker processes, so fixed listen
// ports collide across runs; pick a random port instead.
fn fixture_listen_port() -> Int {
  match @env.rand(2) {
    Some(bytes) =>
      20_000 + (bytes[0].to_int() * 256 + bytes[1].to_int()) % 30_000
    None => 18_478
  }
}

///|
priv struct FakeGateway {
  mut functions : Json
  events : Array[Json]
}

///|
fn FakeGateway::FakeGateway(
  functions~ : Json,
  events~ : Array[Json],
) -> FakeGateway {
  { functions, events, }
}

///|
fn fake_gateway_router(fake : FakeGateway) -> @shared.Router {
  let router = @shared.Router::new()
  router.add(
    @shared.route(http_method=@http.Get, pattern="/api/functions", handler=ctx => {
      @shared.send_json(ctx.conn, 200, fake.functions)
    }),
  )
  router.add(
    @shared.route(http_method=@http.Post, pattern="/api/events", handler=ctx => {
      fake.events.push(@shared.read_json_body(ctx))
      @shared.send_json(ctx.conn, 200, Json::array([]))
    }),
  )
  router
}

///|
fn config(port : Int) -> SchedulerConfig {
  { gateway_url: "http://127.0.0.1:\{port}", poll_ms: 30_000, }
}

///|
fn registry_json(records : Array[(String, String?)]) -> Json {
  let items = []
  for pair in records {
    let (name, cron) = pair
    let manifest : Map[String, Json] = Map([])
    manifest["name"] = Json::string(name)
    let triggers : Map[String, Json] = Map([])
    match cron {
      Some(expr) => triggers["cron"] = Json::string(expr)
      None => ()
    }
    manifest["triggers"] = Json::object(triggers)
    let record : Map[String, Json] = Map([])
    record["name"] = Json::string(name)
    record["manifest"] = Json::object(manifest)
    record["buildId"] = Json::string("b-1")
    record["updatedAt"] = Json::string("2026-10-03T00:00:00.000Z")
    items.push(Json::object(record))
  }
  Json::array(items)
}

///|
async test "sync_table picks up cron functions within a poll" {
  let port = fixture_listen_port()
  let fake = FakeGateway(
    functions=registry_json([
      ("nightly", Some("0 8 * * *")),
      ("http-only", None),
      ("every-minute", Some("* * * * *")),
    ]),
    events=[],
  )
  @async.with_task_group(group => {
    let server = @http.Server(
      @socket.Addr::parse("127.0.0.1:\{port}"),
      reuse_addr=true,
    )
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(server, fake_gateway_router(fake))
    })
    let empty : Map[String, ScheduleEntry] = Map([])
    let table = sync_table(config(port), empty)
    // Only cron-triggered functions enter the schedule table.
    assert_eq(table.length(), 2)
    guard table.get("nightly") is Some(nightly) else { fail("nightly missing") }
    assert_eq(nightly.schedule.expression, "0 8 * * *")
    // Next fire is in the future.
    assert_true(nightly.next_fire_ms > @async.now())
    guard table.get("every-minute") is Some(minute) else {
      fail("every-minute missing")
    }
    // Within one poll cycle of a fresh deploy, the entry exists and fires
    // within a minute.
    assert_true(minute.next_fire_ms - @async.now() <= 60_000)
    // A second sync keeps the pending fire time of unchanged entries.
    let before = nightly.next_fire_ms
    let table = sync_table(config(port), table)
    guard table.get("nightly") is Some(again) else { fail("nightly gone") }
    assert_eq(again.next_fire_ms, before)
    // Removing a function drops it from the table.
    fake.functions = registry_json([("nightly", Some("0 8 * * *"))])
    let table = sync_table(config(port), table)
    assert_eq(table.length(), 1)
    assert_true(table.get("every-minute") is None)
    server.close()
  })
}

///|
async test "dispatch_due fires due entries once and reschedules forward" {
  let port = fixture_listen_port()
  let fake = FakeGateway(functions=Json::array([]), events=[])
  @async.with_task_group(group => {
    let server = @http.Server(
      @socket.Addr::parse("127.0.0.1:\{port}"),
      reuse_addr=true,
    )
    group.spawn_bg(no_wait=true, () => {
      @shared.serve_on(server, fake_gateway_router(fake))
    })
    let now = @async.now()
    let overdue = {
      schedule: @shared.CronSchedule(
        name="every-minute",
        expression="* * * * *",
      ),
      // Overdue by many periods: skip-if-late must fire it exactly once.
      next_fire_ms: now - 300_000,
    }
    let future = {
      schedule: @shared.CronSchedule(name="nightly", expression="0 8 * * *"),
      next_fire_ms: now + 3_600_000,
    }
    let table : Map[String, ScheduleEntry] = Map([])
    table["every-minute"] = overdue
    table["nightly"] = future
    let updated = dispatch_due(config(port), table, now)
    // One cron event was dispatched with schedule and scheduled time.
    assert_eq(fake.events.length(), 1)
    let event = fake.events[0].stringify()
    assert_true(event.contains("\"source\":\"cron\""))
    assert_true(event.contains("\"schedule\":\"* * * * *\""))
    // The overdue entry fired once and rescheduled into the future; the
    // future entry is untouched.
    guard updated.get("every-minute") is Some(rescheduled) else {
      fail("entry lost")
    }
    assert_true(rescheduled.next_fire_ms > now)
    guard updated.get("nightly") is Some(kept) else { fail("nightly lost") }
    assert_eq(kept.next_fire_ms, now + 3_600_000)
    server.close()
  })
}
