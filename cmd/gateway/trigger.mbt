///|
// HTTP trigger intake: /fn/<name> (any method) only dispatches functions
// whose manifest enables the http trigger, then builds the http event and
// applies the optional stdout response header.

///|
async fn handle_trigger(
  ctx : @shared.RequestContext,
  cfg : GatewayConfig,
) -> Unit {
  let name = ctx.params["name"]
  let record = match registry_all(cfg).get(name) {
    Some(record) => record
    None =>
      return @shared.send_text(ctx.conn, 404, "unknown function \{name}\n")
  }
  if !record.manifest.triggers.http_enabled {
    return @shared.send_text(
      ctx.conn,
      403,
      "function \{name} does not have an http trigger\n",
    )
  }
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
  let result = dispatch_run(cfg, name, event)
  if result.exit_code == 127 &&
    (
      result.stderr.contains("runner unreachable") ||
      result.stderr.contains("failed to upload module")
    ) {
    return @shared.send_text(ctx.conn, 502, result.stderr)
  }
  if result.exit_code == 127 && result.stderr.contains("unknown function") {
    return @shared.send_text(ctx.conn, 404, "unknown function \{name}\n")
  }
  let output = parse_function_response(result.stdout)
  @shared.send_response(
    ctx.conn,
    output.status,
    output.body,
    headers=output.headers,
  )
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
