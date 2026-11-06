///|
test "deploy request and build result round-trip" {
  let deploy = @shared.DeployRequest(
    name="hello",
    archive="SGVsbG8gdGFyLmd6IGJ5dGVz",
  )
  let back = @shared.DeployRequest::from_json(deploy.to_json())
  assert_eq(back.to_json().stringify(), deploy.to_json().stringify())
  let ok = @shared.BuildResult(
    ok=true,
    build_id="b-20261003-1",
    wasm_path="/var/lib/moonless/functions/hello/b-20261003-1/func.wasm",
  )
  let back = @shared.BuildResult::from_json(ok.to_json())
  assert_eq(back.to_json().stringify(), ok.to_json().stringify())
  let failed = @shared.BuildResult(
    ok=false,
    error_tail="Error: Failed to resolve the module dependency graph",
  )
  let back = @shared.BuildResult::from_json(failed.to_json())
  assert_eq(back.to_json().stringify(), failed.to_json().stringify())
}

///|
test "run request and run result round-trip" {
  let env : Map[String, String] = Map([])
  env["MOONLESS_REDIS_URL"] = "redis://redis.internal:6379"
  let request = @shared.RunRequest(
    name="counter",
    event=@shared.Event::Http(
      @shared.HttpEventData(
        http_method="POST",
        path="/fn/counter",
        query="",
        body="",
      ),
    ),
    env~,
  )
  let back = @shared.RunRequest::from_json(request.to_json())
  assert_eq(back.to_json().stringify(), request.to_json().stringify())
  let result = @shared.RunResult(
    stdout="42",
    stderr="noise",
    exit_code=0,
    duration_ms=173,
    truncated=true,
  )
  let back = @shared.RunResult::from_json(result.to_json())
  assert_eq(back.to_json().stringify(), result.to_json().stringify())
}

///|
test "registry record round-trips through JSON including the manifest" {
  let record = @shared.RegistryRecord(
    name="resize-images",
    manifest=@shared.Manifest(
      name="resize-images",
      triggers=@shared.ManifestTriggers(
        http_enabled=true,
        cron="0 8 * * *",
        s3=@shared.S3Trigger(bucket="uploads", events=["put", "delete"]),
      ),
      toolchain="0.10.11",
    ),
    build_id="b-20261003-2",
    updated_at="2026-10-03T09:00:00.000Z",
  )
  let back = @shared.RegistryRecord::from_json(record.to_json())
  assert_eq(back.to_json().stringify(), record.to_json().stringify())
  // Minimal manifest: defaults survive the round trip too.
  let minimal = @shared.RegistryRecord(
    name="hello",
    manifest=@shared.Manifest(name="hello"),
    build_id="b-1",
    updated_at="2026-10-03T09:00:00.000Z",
  )
  let back = @shared.RegistryRecord::from_json(minimal.to_json())
  assert_eq(back.to_json().stringify(), minimal.to_json().stringify())
}

///|
test "protocol decode rejects non-objects and missing events" {
  try @shared.DeployRequest::from_json(Json::string("oops")) catch {
    @shared.InvalidJson(_) => ()
    _ => fail("expected InvalidJson")
  } noraise {
    _ => fail("expected non-object to be rejected")
  }
  let json : Json = @json.parse("{\"name\":\"f\"}")
  try @shared.RunRequest::from_json(json) catch {
    @shared.InvalidJson(_) => ()
    _ => fail("expected InvalidJson")
  } noraise {
    _ => fail("expected missing event to be rejected")
  }
}
