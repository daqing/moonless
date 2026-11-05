///|
async fn handle_module_upload(
  ctx : @shared.RequestContext,
  cfg : RunnerConfig,
) -> Unit {
  let upload = @shared.ModuleUpload::from_json(@shared.read_json_body(ctx))
  if !safe_module_segment(upload.name) || !safe_module_segment(upload.build_id) {
    return @shared.send_text(ctx.conn, 400, "invalid function or build id\n")
  }
  let wasm = @base64.decode(upload.wasm[:]) catch {
    _ => return @shared.send_text(ctx.conn, 400, "wasm is not valid base64\n")
  }
  let dir = cfg.data_root + "/functions/" + upload.name + "/" + upload.build_id
  @fs.mkdir(dir, recursive=true, allow_exist=true)
  @fs.write_file(dir + "/func.wasm", wasm[:])
  @fs.chmod(dir + "/func.wasm", 0o755)
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
