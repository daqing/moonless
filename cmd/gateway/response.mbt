///|
priv struct FunctionResponse {
  status : Int32
  headers : Map[String, String]
  body : String
}

///|
fn plain_function_response(stdout : String) -> FunctionResponse {
  { status: 200, headers: Map([]), body: stdout, }
}

///|
fn parse_function_response(stdout : String) -> FunctionResponse {
  let (line, body) = match stdout.split_once("\n") {
    Some((header, rest)) => (header, rest.to_owned())
    None => (stdout[:], "")
  }
  let json = @json.parse(line) catch {
    _ => return plain_function_response(stdout)
  }
  guard json is Object(obj) else { return plain_function_response(stdout) }
  if obj.get("status") is None && obj.get("headers") is None {
    return plain_function_response(stdout)
  }
  let status = match obj.get("status") {
    Some(Number(value, ..)) => value.to_int()
    Some(_) => return plain_function_response(stdout)
    None => 200
  }
  if status < 100 || status > 599 {
    return plain_function_response(stdout)
  }
  let headers : Map[String, String] = Map([])
  match obj.get("headers") {
    Some(Object(values)) =>
      for name, value in values {
        match value {
          String(text) => {
            let normalized = name.to_lower()
            if normalized != "content-length" &&
              normalized != "transfer-encoding" &&
              normalized != "connection" {
              headers[name] = text
            }
          }
          _ => return plain_function_response(stdout)
        }
      }
    Some(_) => return plain_function_response(stdout)
    None => ()
  }
  { status, headers, body, }
}
