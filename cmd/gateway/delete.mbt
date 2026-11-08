///|
async fn handle_delete(
  ctx : @shared.RequestContext,
  cfg : GatewayConfig,
) -> Unit {
  let name = ctx.params["name"]
  let record = registry_remove(cfg, name) catch {
    err =>
      return @shared.send_text(
        ctx.conn,
        500,
        "failed to delete function \{name}: \{@debug.to_string(err)}\n",
      )
  }
  guard record is Some(record) else {
    return @shared.send_text(ctx.conn, 404, "unknown function \{name}\n")
  }
  cleanup_deleted_function(cfg, record)
  @shared.log_info(service="gateway", message="deleted function \{name}")
  @shared.send_json(ctx.conn, 200, record.to_json())
}

///|
async fn cleanup_deleted_function(
  cfg : GatewayConfig,
  record : @shared.RegistryRecord,
) -> Unit {
  if safe_data_component(record.name) {
    remove_data_tree(cfg.data_root + "/functions/" + record.name)
    remove_data_tree(cfg.data_root + "/logs/" + record.name)
  } else {
    @shared.log_warn(
      service="gateway",
      message="skipping unsafe data path for deleted function \{record.name}",
    )
  }
  for build_id in record.history {
    cleanup_build_directory(cfg, build_id)
  }
  if !has_event(record.history, record.build_id) {
    cleanup_build_directory(cfg, record.build_id)
  }
}

///|
async fn cleanup_build_directory(
  cfg : GatewayConfig,
  build_id : String,
) -> Unit {
  if safe_data_component(build_id) {
    remove_data_tree(cfg.data_root + "/builds/" + build_id)
  } else {
    @shared.log_warn(
      service="gateway",
      message="skipping unsafe build data path for \{build_id}",
    )
  }
}

///|
fn safe_data_component(value : String) -> Bool {
  value != "" &&
  value != "." &&
  value != ".." &&
  !value.contains("/") &&
  !value.contains("\\")
}

///|
async fn remove_data_tree(path : String) -> Unit {
  if !(@fs.exists(path) catch { _ => false }) {
    return
  }
  @fs.rmdir(path, recursive=true) catch {
    err =>
      @shared.log_warn(
        service="gateway",
        message="failed to remove \{path}: \{@debug.to_string(err)}",
      )
  }
}
