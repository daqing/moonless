///|
// HTTP trigger intake: /fn/<name> (any method) builds the http event,
// dispatches to the runner, and returns the function's stdout as a 200.

///|
async fn handle_trigger(
  ctx : @shared.RequestContext,
  cfg : GatewayConfig,
) -> Unit {
  let name = ctx.params["name"]
  let body = ctx.body.read_all().text() catch { _ => "" }
  let query = match ctx.request.path.split_once("?") {
    Some((_, q)) => q.to_owned()
    None => ""
  }
  let path = match ctx.request.path.split_once("?") {
    Some((head, _)) => head.to_owned()
    None => ctx.request.path
  }
  let event = @shared.Event::Http(
    @shared.HttpEventData(
      http_method=request_method_name(ctx.request.meth),
      path~,
      query~,
      body~,
    ),
  )
  let response = @shared.http_post_json(
    cfg.runner_url + "/run",
    @shared.RunRequest(name~, event~).to_json(),
    timeout_ms=70_000,
  ) catch {
    _ => return @shared.send_text(ctx.conn, 502, "runner unreachable\n")
  }
  let result = @shared.RunResult::from_json(response) catch {
    _ => return @shared.send_text(ctx.conn, 502, "runner protocol error\n")
  }
  if result.exit_code == 127 && result.stderr.contains("unknown function") {
    return @shared.send_text(ctx.conn, 404, "unknown function \{name}\n")
  }
  @shared.send_text(ctx.conn, 200, result.stdout)
}

///|
fn request_method_name(meth : @http.RequestMethod) -> String {
  match meth {
    Get => "GET"
    Head => "HEAD"
    Post => "POST"
    Put => "PUT"
    Delete => "DELETE"
    Connect => "CONNECT"
    Options => "OPTIONS"
    Trace => "TRACE"
    Patch => "PATCH"
  }
}
