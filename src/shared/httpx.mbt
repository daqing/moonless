///|
// A thin router on top of moonbitlang/async's http server: path matching
// with :params, method dispatch, JSON body reading, response helpers.
// Handler errors are converted to 500s here — an unhandled raise inside
// run_forever yields an empty response to the client instead.

///|
pub struct RequestContext {
  params : Map[String, String]
  request : @http.Request
  body : &@io.Reader
  conn : @http.ServerConnection
}

///|
fn RequestContext::RequestContext(
  params~ : Map[String, String],
  request~ : @http.Request,
  body~ : &@io.Reader,
  conn~ : @http.ServerConnection,
) -> RequestContext {
  { params, request, body, conn, }
}

///|
pub struct Route {
  http_method : @http.RequestMethod?
  pattern : String
  handler : async (RequestContext) -> Unit
}

///|
pub fn route(
  http_method~ : @http.RequestMethod,
  pattern~ : String,
  handler~ : async (RequestContext) -> Unit,
) -> Route {
  { http_method: Some(http_method), pattern, handler, }
}

///|
// Matches any HTTP method (used for /fn/<name> style triggers).
pub fn route_any(
  pattern~ : String,
  handler~ : async (RequestContext) -> Unit,
) -> Route {
  { http_method: None, pattern, handler, }
}

///|
pub struct Router {
  routes : Array[Route]
}

///|
pub fn Router::new() -> Router {
  { routes: [], }
}

///|
pub fn Router::add(self : Router, route : Route) -> Unit {
  self.routes.push(route)
}

///|
pub async fn serve(host_port : String, router : Router) -> Unit {
  let addr = @socket.Addr::parse(host_port)
  let server = @http.Server(addr)
  serve_on(server, router)
}

///|
// Attaches a router to an existing server; serve() wraps this for the
// common case. Exposed so callers keep the Server handle (to close it).
pub async fn serve_on(server : @http.Server, router : Router) -> Unit {
  server.run_forever() <| ((request, body, conn) => {
    dispatch(router, request, body, conn)
  })
}

///|
async fn dispatch(
  router : Router,
  request : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit noraise {
  let path : String = match request.path.split_once("?") {
    Some((head, _)) => head.to_owned()
    None => request.path
  }
  let mut path_matched = false
  for route in router.routes {
    match match_path(route.pattern, path) {
      Some(params) => {
        path_matched = true
        let method_ok = match route.http_method {
          Some(m) => m == request.meth
          None => true
        }
        if method_ok {
          (route.handler)(RequestContext(params~, request~, body~, conn~)) catch {
            _ => send_text(conn, 500, "internal error") catch { _ => () }
          }
          return
        }
      }
      None => ()
    }
  }
  if path_matched {
    send_text(conn, 405, "Method Not Allowed") catch {
      _ => ()
    }
  } else {
    send_text(conn, 404, "Not Found") catch {
      _ => ()
    }
  }
}

///|
// Matches "/a/:name/c" against a request path; :segments are captured
// into the params map. Returns None when lengths or literals disagree.
pub fn match_path(pattern : String, path : String) -> Map[String, String]? {
  let pattern_segments = split_segments(pattern)
  let path_segments = split_segments(path)
  if pattern_segments.length() != path_segments.length() {
    return None
  }
  let params : Map[String, String] = Map([])
  for i in 0..<pattern_segments.length() {
    let p = pattern_segments[i]
    let x = path_segments[i]
    if p.length() > 1 && p[0] == ':' {
      params[p[1:].to_owned()] = x.to_owned()
    } else if p != x {
      return None
    }
  }
  Some(params)
}

///|
fn split_segments(s : String) -> Array[StringView] {
  let segments = []
  for segment in s.split("/") {
    segments.push(segment)
  }
  segments
}

///|
pub async fn send_text(
  conn : @http.ServerConnection,
  status : Int,
  text : String,
) -> Unit {
  conn
  ..send_response(status, reason_phrase(status), extra_headers={
    "Content-Type": "text/plain",
  })
  ..write_string(text)
  .end_response()
}

///|
pub async fn send_json(
  conn : @http.ServerConnection,
  status : Int,
  json : Json,
) -> Unit {
  conn
  ..send_response(status, reason_phrase(status), extra_headers={
    "Content-Type": "application/json",
  })
  ..write_string(json.stringify())
  .end_response()
}

///|
pub async fn read_json_body(ctx : RequestContext) -> Json raise SharedError {
  let text = ctx.body.read_all().text() catch {
      _ => raise InvalidJson("failed to read request body")
    }
  @json.parse(text) catch {
    _ => raise InvalidJson("invalid JSON body")
  }
}

///|
fn reason_phrase(status : Int) -> String {
  match status {
    200 => "OK"
    201 => "Created"
    204 => "No Content"
    400 => "Bad Request"
    404 => "Not Found"
    405 => "Method Not Allowed"
    500 => "Internal Server Error"
    _ => "Unknown"
  }
}
