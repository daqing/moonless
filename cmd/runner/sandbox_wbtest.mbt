///|
async test "sandbox policy controls host environment access" {
  let fixture_dir = @fs.tmpdir(prefix="moonless-runner-fixture-")
  let wasm = build_fixture_module(fixture_dir, echo_pkg(), echo_main())
  let data_root = @fs.tmpdir(prefix="moonless-runner-test-")
  install_function(data_root, "policy-fn", "b-deny", wasm)
  install_function(data_root, "policy-fn", "b-allow", wasm)
  @fs.write_file(
    data_root + "/functions/policy-fn/b-deny/policy.json",
    "{\"env\":{}}\n",
  )
  @fs.write_file(
    data_root + "/functions/policy-fn/b-allow/policy.json",
    "{\"env\":{\"from_host\":[\"MOONLESS_EVENT\"]}}\n",
  )
  let event = @shared.Event::Http(
    @shared.HttpEventData(
      http_method="GET",
      path="/fn/policy-fn",
      query="",
      body="",
    ),
  )
  let denied = run_function(
    test_config(data_root),
    @shared.RunRequest(name="policy-fn", event~, build_id="b-deny"),
  )
  assert_eq(denied.exit_code, 0)
  assert_eq(denied.stdout, "NOEVT\n")
  let allowed = run_function(
    test_config(data_root),
    @shared.RunRequest(name="policy-fn", event~, build_id="b-allow"),
  )
  assert_eq(allowed.exit_code, 0)
  assert_true(allowed.stdout.contains("EVT:"))
  assert_true(allowed.stdout.contains("policy-fn"))
}
