///|
// Function execution: resolve the stored module, run it under moonrun with
// the trigger event (and any injected env) in the environment, and report
// captured stdout/stderr, exit code, and duration.

///|
priv struct RunnerConfig {
  data_root : String
}

///|
fn load_runner_config() -> RunnerConfig {
  let data_root = @env.get_env_var("MOONLESS_DATA").unwrap_or(
    "/var/lib/moonless",
  )
  { data_root, }
}

///|
async fn run_function(
  cfg : RunnerConfig,
  request : @shared.RunRequest,
) -> @shared.RunResult {
  run_steps(cfg, request) catch {
    @shared.RunError(message) => run_failed(message)
    err => run_failed(@debug.to_string(err))
  }
}

///|
fn run_failed(message : String) -> @shared.RunResult {
  @shared.RunResult(stdout="", stderr=message, exit_code=127)
}

///|
async fn run_steps(
  cfg : RunnerConfig,
  request : @shared.RunRequest,
) -> @shared.RunResult raise @shared.SharedError {
  let module_path = resolve_module(cfg.data_root, request.name)
  let started = @async.now()
  let env : Map[String, String] = Map([])
  env["MOONLESS_EVENT"] = request.event.to_json().stringify()
  for key, value in request.env {
    env[key] = value
  }
  let (code, stdout, stderr) = @process.collect_output(
    "moonrun",
    [module_path],
    extra_env=env,
  ) catch {
    err =>
      raise @shared.RunError("failed to run moonrun: \{@debug.to_string(err)}")
  }
  @shared.RunResult(
    stdout=stdout.text() catch { _ => "" },
    stderr=stderr.text() catch { _ => "" },
    exit_code=code,
    duration_ms=(@async.now() - started).to_int(),
    truncated=false,
  )
}

///|
// Resolves <name> to the newest stored build: functions/<name>/ holds
// b-<epoch-ms> directories; the numerically largest build id wins.
async fn resolve_module(
  data_root : String,
  name : String,
) -> String raise @shared.SharedError {
  let functions_dir = data_root + "/functions/" + name
  let entries = @fs.readdir(functions_dir) catch {
    _ => raise @shared.RunError("unknown function: \{name}")
  }
  let mut newest_id = ""
  let mut newest_ms : Int64 = -1L
  for entry in entries {
    let has_module = @fs.exists(functions_dir + "/" + entry + "/func.wasm") catch {
      _ => false
    }
    if has_module && entry.has_prefix("b-") {
      let ms = @string.parse_int64(entry[2:]) catch { _ => -1L }
      if ms > newest_ms {
        newest_ms = ms
        newest_id = entry
      }
    }
  }
  if newest_id == "" {
    raise @shared.RunError("no build found for function: \{name}")
  }
  functions_dir + "/" + newest_id + "/func.wasm"
}
