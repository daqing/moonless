///|
// Accepts a build pushed by the gateway before a remote run. Logs the
// interaction (this is the runner side of gateway -> runner module delivery)
// and reports the concrete cause on failure, so a rejected upload is
// diagnosable from the runner's own log instead of only as gateway "internal
// error".
async fn handle_module_upload(
  ctx : @shared.RequestContext,
  cfg : RunnerConfig,
) -> Unit {
  let upload = @shared.ModuleUpload::from_json(@shared.read_json_body(ctx)) catch {
    err => {
      @shared.log_warn(
        service="runner",
        message="node=\{cfg.node_id} rejected /modules: \{@debug.to_string(err)}",
      )
      return @shared.send_text(ctx.conn, 400, "invalid module upload payload\n")
    }
  }
  @shared.log_info(
    service="runner",
    message="node=\{cfg.node_id} gateway upload name=\{upload.name} build=\{upload.build_id} wasm=\{upload.wasm.length()}b policy=\{upload.policy.length()}b",
  )
  if !safe_module_segment(upload.name) || !safe_module_segment(upload.build_id) {
    @shared.log_warn(
      service="runner",
      message="node=\{cfg.node_id} rejected upload: unsafe name/build id (\{upload.name}, \{upload.build_id})",
    )
    return @shared.send_text(ctx.conn, 400, "invalid function or build id\n")
  }
  let wasm = @base64.decode(upload.wasm[:]) catch {
    _ => {
      @shared.log_warn(
        service="runner",
        message="node=\{cfg.node_id} rejected upload name=\{upload.name}: wasm is not valid base64",
      )
      return @shared.send_text(ctx.conn, 400, "wasm is not valid base64\n")
    }
  }
  let dir = cfg.data_root + "/functions/" + upload.name + "/" + upload.build_id
  try {
    @fs.mkdir(dir, recursive=true, allow_exist=true)
    @fs.write_file(dir + "/func.wasm", wasm[:])
    @fs.chmod(dir + "/func.wasm", 0o755)
    if upload.policy != "" {
      @fs.write_file(dir + "/policy.json", upload.policy)
    }
  } catch {
    err => {
      let reason = @debug.to_string(err)
      @shared.log_error(
        service="runner",
        message="node=\{cfg.node_id} failed to store upload name=\{upload.name} build=\{upload.build_id} at \{dir}: \{reason}",
      )
      return @shared.send_text(
        ctx.conn,
        500,
        "moonless: cannot store module at \{dir}: \{reason}\n",
      )
    }
  }
  @shared.log_info(
    service="runner",
    message="node=\{cfg.node_id} stored upload name=\{upload.name} build=\{upload.build_id} wasm=\{wasm.length()}b at \{dir}",
  )
  let response : Json = { "ok": true }
  @shared.send_json(ctx.conn, 200, response)
}

///|
fn safe_module_segment(value : String) -> Bool {
  value != "" &&
  value != "." &&
  value != ".." &&
  !value.contains("/") &&
  !value.contains("\\")
}
