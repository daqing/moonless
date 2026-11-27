///|
// The runner service: executes stored wasm modules under moonrun with the
// trigger event in the environment, bounded by timeout, concurrency, and
// output caps.

///|
async fn main {
  let cfg = load_runner_config()
  let public_url = @env.get_env_var("MOONLESS_RUNNER_PUBLIC_URL").unwrap_or("")
  let advertised = if public_url == "" {
    "<unset: not registering>"
  } else {
    public_url
  }
  @shared.log_info(
    service="runner",
    message="listening on 0.0.0.0:8082 (advertising \{advertised})",
  )
  @async.with_task_group(group => {
    let gateway_url = @env.get_env_var("MOONLESS_GATEWAY_URL").unwrap_or("")
    if gateway_url != "" && public_url != "" {
      group.spawn_bg(() => register_runner_loop(gateway_url, public_url))
    }
    @shared.serve("0.0.0.0:8082", runner_router(cfg))
  })
}

///|
fn runner_router(cfg : RunnerConfig) -> @shared.Router {
  let router = @shared.Router::new()
  router.add(
    @shared.route(http_method=@http.Get, pattern="/healthz", handler=ctx => {
      @shared.send_text(ctx.conn, 200, "ok")
    }),
  )
  router.add(
    @shared.route(http_method=@http.Post, pattern="/run", handler=ctx => {
      handle_run(ctx, cfg)
    }),
  )
  router.add(
    @shared.route(http_method=@http.Post, pattern="/modules", handler=ctx => {
      handle_module_upload(ctx, cfg)
    }),
  )
  router
}

///|
async fn handle_run(ctx : @shared.RequestContext, cfg : RunnerConfig) -> Unit {
  let request = @shared.RunRequest::from_json(@shared.read_json_body(ctx)) catch {
    err => {
      @shared.log_warn(
        service="runner",
        message="node=\{cfg.node_id} rejected /run: \{@debug.to_string(err)}",
      )
      return @shared.send_text(ctx.conn, 400, "invalid run request\n")
    }
  }
  @shared.log_info(
    service="runner",
    message="node=\{cfg.node_id} gateway run request name=\{request.name} source=\{request.event.source_name()} build=\{request.build_id}",
  )
  let result = run_function(cfg, request)
  @shared.send_json(ctx.conn, 200, result.to_json())
}
