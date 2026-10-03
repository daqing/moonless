///|
// The builder service: accepts a function package (tar.gz, base64 in a
// DeployRequest), validates it, compiles it to wasm with the pinned moon
// toolchain, and stores the artifact under the shared volume.

///|
async fn main {
  @shared.log_info(service="builder", message="listening on 0.0.0.0:8081")
  @shared.serve("0.0.0.0:8081", builder_router())
}

///|
fn builder_router() -> @shared.Router {
  let router = @shared.Router::new()
  router.add(
    @shared.route(
      http_method=@http.Post,
      pattern="/build",
      handler=handle_build,
    ),
  )
  router
}

///|
async fn handle_build(ctx : @shared.RequestContext) -> Unit {
  let request = @shared.DeployRequest::from_json(@shared.read_json_body(ctx))
  @shared.log_info(
    service="builder",
    message="build requested for \{request.name}",
  )
  let result = run_build(request.name, request.archive, builder_data_dir())
  @shared.send_json(ctx.conn, 200, result.to_json())
}
