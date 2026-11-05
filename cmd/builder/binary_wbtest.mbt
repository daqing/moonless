///|
async test "binary packages skip moon and preserve executable permissions" {
  let fixture_dir = @fs.tmpdir(prefix="moonless-binary-fixture-")
  write_fixture_files(fixture_dir, [
    (
      "moonless.toml", "name = \"native-fn\"\nbinary = \"func\"\n\n[triggers]\nhttp = { enabled = true }\n",
    ),
  ])
  let executable = @fs.read_file("/bin/echo").binary()
  @fs.write_file(fixture_dir + "/func", executable[:])
  let archive = pack_tar_gz(fixture_dir)
  let data_root = @fs.tmpdir(prefix="moonless-builder-test-")
  let result = run_build("native-fn", @base64.encode(archive[:]), data_root)
  assert_true(result.ok)
  assert_true(@fs.exists(result.wasm_path))
  assert_true(@fs.can_execute(result.wasm_path))
  let stored = @fs.read_file(result.wasm_path).binary()
  assert_eq(stored.length(), executable.length())
}
