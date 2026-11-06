///|
async test "native binary opt-in executes directly with the function event" {
  let fixture_dir = @fs.tmpdir(prefix="moonless-native-fixture-")
  let source = fixture_dir + "/main.c"
  let executable = fixture_dir + "/func"
  @fs.write_file(
    source, "#include <stdio.h>\n#include <stdlib.h>\nint main(void) { printf(\"native:%s\\n\", getenv(\"MOONLESS_EVENT\")); return 0; }\n",
  )
  let (code, _, stderr) = @process.collect_output("cc", [
    "-o", executable, source,
  ])
  if code != 0 {
    fail("cc failed: \{stderr.text()}")
  }
  let data_root = @fs.tmpdir(prefix="moonless-runner-test-")
  let wasm = @fs.read_file(executable).binary()
  install_function(data_root, "native-fn", "b-native", wasm)
  @fs.chmod(data_root + "/functions/native-fn/b-native/func.wasm", 0o755)
  let result = run_function(
    test_config(data_root),
    @shared.RunRequest(
      name="native-fn",
      event=@shared.Event::Http(
        @shared.HttpEventData(
          http_method="GET",
          path="/fn/native-fn",
          query="",
          body="",
        ),
      ),
      build_id="b-native",
      native_binary=true,
    ),
  )
  assert_eq(result.exit_code, 0)
  assert_true(result.stdout.contains("native:"))
  assert_true(result.stdout.contains("native-fn"))
}
