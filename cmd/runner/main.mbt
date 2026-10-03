///|
// The runner service: executes stored wasm modules under moonrun with the
// trigger event in the environment, bounded by timeout, concurrency, and
// output caps.

///|
async fn main {
  @shared.log_info(service="runner", message="listening on 0.0.0.0:8082")
  @shared.serve("0.0.0.0:8082", runner_router(load_runner_config()))
}

///|
fn runner_router(cfg : RunnerConfig) -> @shared.Router {
  let router = @shared.Router::new()
  router.add(
    @shared.route(http_method=@http.Post, pattern="/run", handler=ctx => {
      handle_run(ctx, cfg)
    }),
  )
  router
}

///|
async fn handle_run(ctx : @shared.RequestContext, cfg : RunnerConfig) -> Unit {
  let request = @shared.RunRequest::from_json(@shared.read_json_body(ctx))
  @shared.log_info(
    service="runner",
    message="run requested for \{request.name}",
  )
  let result = run_function(cfg, request)
  @shared.send_json(ctx.conn, 200, result.to_json())
}
