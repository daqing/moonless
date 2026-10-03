///|
// Function execution: resolve the stored module, run it under moonrun with
// the trigger event (and any injected env) in the environment, and report
// captured stdout/stderr, exit code, and duration.

///|
priv struct RunnerConfig {
  data_root : String
  timeout_ms : Int
  output_cap : Int
  sem : @semaphore.Semaphore
}

///|
fn env_int(name : String, default : Int) -> Int {
  match @env.get_env_var(name) {
    Some(value) => @string.parse_int(value) catch { _ => default }
    None => default
  }
}

///|
fn make_runner_config(
  data_root : String,
  timeout_ms : Int,
  max_concurrency : Int,
  output_cap : Int,
) -> RunnerConfig {
  {
    data_root,
    timeout_ms,
    output_cap,
    sem: @semaphore.Semaphore(max_concurrency),
  }
}

///|
fn load_runner_config() -> RunnerConfig {
  let data_root = @env.get_env_var("MOONLESS_DATA").unwrap_or(
    "/var/lib/moonless",
  )
  let timeout_ms = env_int("MOONLESS_RUN_TIMEOUT_MS", 60_000)
  let max_concurrency = env_int("MOONLESS_MAX_CONCURRENCY", 8)
  let output_cap = env_int("MOONLESS_OUTPUT_LIMIT", 10 * 1024 * 1024)
  make_runner_config(data_root, timeout_ms, max_concurrency, output_cap)
}

///|
async fn run_function(
  cfg : RunnerConfig,
  request : @shared.RunRequest,
) -> @shared.RunResult {
  let result = run_steps(cfg, request) catch {
    @shared.RunError(message) => run_failed(message)
    err => run_failed(@debug.to_string(err))
  }
  append_run_log(cfg, request, result)
  result
}

///|
// One record per invocation under logs/<name>/<YYYY-MM-DD>.log: the event
// JSON, outcome summary, and the function's stderr for gateway-side queries.
async fn append_run_log(
  cfg : RunnerConfig,
  request : @shared.RunRequest,
  result : @shared.RunResult,
) -> Unit {
  let timestamp = @shared.format_timestamp(@async.now())
  let date = timestamp[:10].to_owned()
  let dir = cfg.data_root + "/logs/" + request.name
  let record = "\{timestamp} event=\{request.event.to_json().stringify()} exit=\{result.exit_code} dur=\{result.duration_ms}ms truncated=\{result.truncated}\n\{result.stderr}\n"
  @fs.mkdir(dir, recursive=true, allow_exist=true) catch {
    _ => ()
  }
  @fs.write_file(dir + "/\{date}.log", record, append=true) catch {
    _ =>
      @shared.log_warn(
        service="runner",
        message="failed to append run log for \{request.name}",
      )
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
  // Concurrency cap: at most max_concurrency forks at once; excess runs
  // queue here instead of overloading the host.
  cfg.sem.acquire()
  defer cfg.sem.release()
  let started = @async.now()
  let env : Map[String, String] = Map([])
  env["MOONLESS_EVENT"] = request.event.to_json().stringify()
  for key, value in request.env {
    env[key] = value
  }
  // Streamed execution: both pipes are drained concurrently, each capped —
  // bytes past the cap are read and discarded, so an infinitely chatty
  // function can neither block on a full pipe nor grow runner memory. A
  // watchdog cancels the child at the deadline.
  let stdout_capture = StreamCapture(cap=cfg.output_cap)
  let stderr_capture = StreamCapture(cap=cfg.output_cap)
  let timed_out : Ref[Bool] = Ref(false)
  let code = @async.with_task_group(group => {
    let (stdout_read, stdout_write) = @process.read_from_process()
    let (stderr_read, stderr_write) = @process.read_from_process()
    group.spawn_bg(() => drain_capped(stdout_read, stdout_capture))
    group.spawn_bg(() => drain_capped(stderr_read, stderr_capture))
    let proc = @process.spawn(
      group,
      "moonrun",
      [module_path],
      extra_env=env,
      stdout=stdout_write,
      stderr=stderr_write,
      cancel_handler=@process.graceful_cancel(timeout=2000),
    )
    // no_wait: the watchdog must not hold the group open after the child
    // exits; a stray fire on a dead process is a no-op.
    group.spawn_bg(no_wait=true, () => {
      @async.sleep(cfg.timeout_ms)
      timed_out.val = true
      proc.cancel()
    })
    proc.wait() catch {
      _ => -1
    }
  }) catch {
    err =>
      raise @shared.RunError("failed to run moonrun: \{@debug.to_string(err)}")
  }
  let truncated = stdout_capture.truncated || stderr_capture.truncated
  if timed_out.val && code != 0 {
    return @shared.RunResult(
      stdout=stdout_capture.text(),
      stderr="moonless: function timed out after \{cfg.timeout_ms}ms\n",
      exit_code=124,
      duration_ms=(@async.now() - started).to_int(),
      truncated~,
    )
  }
  @shared.RunResult(
    stdout=stdout_capture.text(),
    stderr=stderr_capture.text(),
    exit_code=code,
    duration_ms=(@async.now() - started).to_int(),
    truncated~,
  )
}

///|
// Per-stream byte capture bounded by the output cap; keeps reading (and
// discarding) past the cap so the child never blocks on a full pipe.
priv struct StreamCapture {
  buf : @buffer.Buffer
  cap : Int
  mut total : Int
  mut truncated : Bool
}

///|
fn StreamCapture::StreamCapture(cap~ : Int) -> StreamCapture {
  { buf: @buffer.Buffer::Buffer(), cap, total: 0, truncated: false, }
}

///|
fn StreamCapture::push(self : StreamCapture, chunk : Bytes) -> Unit {
  self.total += chunk.length()
  if self.total > self.cap {
    self.truncated = true
  }
  let remaining = self.cap - self.buf.length()
  if remaining > 0 {
    if chunk.length() <= remaining {
      self.buf.write_bytesview(chunk[:])
    } else {
      self.buf.write_bytesview(chunk[:remaining])
    }
  }
}

///|
fn StreamCapture::text(self : StreamCapture) -> String {
  @utf8.decode_lossy(self.buf.to_bytes()[:])
}

///|
async fn drain_capped(
  reader : @process.ReadFromProcess,
  capture : StreamCapture,
) -> Unit {
  for ;; {
    let chunk = reader.read_some() catch { _ => None }
    guard chunk is Some(bytes) else { break }
    capture.push(bytes)
  }
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
