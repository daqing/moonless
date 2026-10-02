///|
async fn main {
  let router = @shared.Router::new()
  router.add(
    @shared.route(http_method=@http.Get, pattern="/healthz", handler=ctx => {
      @shared.send_text(ctx.conn, 200, "ok")
    }),
  )
  @shared.serve("0.0.0.0:8080", router)
}
