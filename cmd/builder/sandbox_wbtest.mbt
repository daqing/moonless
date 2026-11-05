///|
async test "sandbox policy is validated and stored with the build" {
  let fixture_dir = @fs.tmpdir(prefix="moonless-policy-fixture-")
  write_fixture_files(fixture_dir, [
    ("moon.mod", "name = \"fixture/policy-fn\"\nversion = \"0.1.0\"\n"),
    ("moonless.toml", "name = \"policy-fn\"\nsandbox = \"policy.json\"\n"),
    ("moon.pkg", "pkgtype(kind: \"executable\")\n"),
    ("main.mbt", "fn main {\n  println(\"ok\")\n}\n"),
    ("policy.json", "{\"env\":{}}\n"),
  ])
  let archive = pack_tar_gz(fixture_dir)
  let data_root = @fs.tmpdir(prefix="moonless-builder-test-")
  let result = run_build("policy-fn", @base64.encode(archive[:]), data_root)
  assert_true(result.ok)
  let policy_path = data_root +
    "/functions/policy-fn/" +
    result.build_id +
    "/policy.json"
  assert_true(@fs.exists(policy_path))
  let policy = @fs.read_file(policy_path).text()
  assert_true(policy.contains("\"env\""))
}
