///|
test "event round-trips all three variants" {
  let events : Array[@shared.Event] = [
    @shared.Event::Http(
      @shared.HttpEventData(
        http_method="POST",
        path="/fn/hello",
        query="a=1&b=2",
        body="{\"n\":3}",
      ),
    ),
    @shared.Event::Cron(
      @shared.CronEventData(schedule="0 8 * * *", time="2026-10-02T08:00:00Z"),
    ),
    @shared.Event::S3(
      @shared.S3EventData(event="put", bucket="uploads", key="report.csv"),
    ),
  ]
  for event in events {
    let back = @shared.Event::from_json(event.to_json())
    assert_eq(back.to_json().stringify(), event.to_json().stringify())
  }
}

///|
test "event encode matches the README JSON shape" {
  let event = @shared.Event::Http(
    @shared.HttpEventData(
      http_method="POST",
      path="/fn/hello",
      query="",
      body="hi",
    ),
  )
  assert_eq(
    event.to_json().stringify(),
    "{\"source\":\"http\",\"method\":\"POST\",\"path\":\"/fn/hello\",\"query\":\"\",\"body\":\"hi\"}",
  )
}

///|
test "event decode tolerates omitted optional fields" {
  // The README's local-debug example omits query and body entirely.
  let json : Json = @json.parse(
    "{\"source\":\"http\",\"method\":\"GET\",\"path\":\"/fn/hello\"}",
  )
  let event = @shared.Event::from_json(json)
  let expected = @shared.Event::Http(
    @shared.HttpEventData(
      http_method="GET",
      path="/fn/hello",
      query="",
      body="",
    ),
  )
  assert_eq(event.to_json().stringify(), expected.to_json().stringify())
}

///|
test "event decode rejects unknown sources" {
  let json : Json = @json.parse("{\"source\":\"kafka\"}")
  try @shared.Event::from_json(json) catch {
    @shared.InvalidEvent(_) => ()
    _ => fail("expected InvalidEvent")
  } noraise {
    _ => fail("expected unknown source to be rejected")
  }
}
