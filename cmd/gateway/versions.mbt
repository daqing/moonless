///|
// POST /api/functions/:name/versions/clear: delete every saved build except
// the active one, then reset the history to the surviving build.

///|
async fn handle_clear_versions(
  ctx : @shared.RequestContext,
  cfg : GatewayConfig,
) -> Unit {
  let name = ctx.params["name"]
  guard registry_all(cfg).get(name) is Some(record) else {
    return @shared.send_text(ctx.conn, 404, "unknown function \{name}\n")
  }
  let active = record.build_id
  let removed : Array[String] = []
  for build_id in record.history {
    if build_id != active {
      remove_saved_build(cfg, name, build_id)
      push_unique(removed, build_id)
    }
  }
  let history : Array[String] = []
  if active != "" {
    history.push(active)
  }
  if removed.length() > 0 || history.length() != record.history.length() {
    registry_set(
      cfg,
      @shared.RegistryRecord(
        name=record.name,
        manifest=record.manifest,
        build_id=record.build_id,
        updated_at=record.updated_at,
        history~,
      ),
    )
  }
  @shared.log_info(
    service="gateway",
    message="cleared \{removed.length()} saved versions of \{name}, kept \{active}",
  )
  let response : Json = {
    "name": name,
    "buildId": active,
    "removed": Json::array(removed.map(build_id => Json::string(build_id))),
  }
  @shared.send_json(ctx.conn, 200, response)
}

///|
async fn remove_saved_build(
  cfg : GatewayConfig,
  name : String,
  build_id : String,
) -> Unit {
  if !safe_data_component(build_id) {
    @shared.log_warn(
      service="gateway",
      message="skipping unsafe build path while clearing \{name}: \{build_id}",
    )
    return
  }
  if safe_data_component(name) {
    remove_data_tree(cfg.data_root + "/functions/" + name + "/" + build_id)
  }
  cleanup_build_directory(cfg, build_id)
}
