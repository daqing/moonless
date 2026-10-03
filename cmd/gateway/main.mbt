///|
// The gateway service: management API, HTTP trigger intake, and event
// dispatch, fronting the builder and runner.

///|
async fn main {
  let cfg = load_gateway_config()
  @shared.log_info(
    service="gateway",
    message="listening on 0.0.0.0:8080 (builder \{cfg.builder_url}, runner \{cfg.runner_url})",
  )
  @shared.serve("0.0.0.0:8080", gateway_router(cfg))
}

///|
fn gateway_router(cfg : GatewayConfig) -> @shared.Router {
  let router = @shared.Router::new()
  router.add(
    @shared.route(http_method=@http.Get, pattern="/healthz", handler=ctx => {
      @shared.send_text(ctx.conn, 200, "ok")
    }),
  )
  router.add(
    @shared.route(http_method=@http.Post, pattern="/api/deploy", handler=ctx => {
      handle_deploy(ctx, cfg)
    }),
  )
  router.add(
    @shared.route(http_method=@http.Get, pattern="/api/functions", handler=ctx => {
      handle_list(ctx, cfg)
    }),
  )
  router.add(
    @shared.route(http_method=@http.Get, pattern="/api/functions/:name", handler=ctx => {
      handle_get(ctx, cfg)
    }),
  )
  router.add(
    @shared.route(http_method=@http.Get, pattern="/api/functions/:name/logs", handler=ctx => {
      handle_logs(ctx, cfg)
    }),
  )
  router.add(
    @shared.route_any(pattern="/fn/:name", handler=ctx => {
      handle_trigger(ctx, cfg)
    }),
  )
  router
}
