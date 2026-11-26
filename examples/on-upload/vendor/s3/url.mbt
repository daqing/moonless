///|
/// Convert a query map into wire-form query parameters: names and values
/// RFC 3986 component-encoded, so delimiter characters cannot alter the
/// parameter structure. The SigV4 signer sorts these into canonical order —
/// the form the signature covers — and `canonical_query_string` renders the
/// wire representation.
fn query_params(query : Map[String, String]) -> Array[(String, String?)] {
  query
  .to_array()
  .map(fn(pair) {
    (
      @sigv4.encode_query_component(pair.0),
      Some(@sigv4.encode_query_component(pair.1)),
    )
  })
}

///|
/// The bare service endpoint (no bucket component): scheme and host.
fn service_endpoint_parts(config : Config) -> (String, String) {
  let endpoint = match config.endpoint {
    Some(value) => value.trim_end(chars="/").to_owned()
    None => "https://s3.\{config.region}.amazonaws.com"
  }
  endpoint_parts(endpoint)
}

///|
fn endpoint_origin_and_host(
  config : Config,
  bucket : String,
) -> (String, String) {
  let (scheme, endpoint_host) = service_endpoint_parts(config)
  match config.endpoint_style {
    Path => ("\{scheme}://\{endpoint_host}", endpoint_host)
    VirtualHost => {
      let origin_host = "\{bucket}.\{endpoint_host}"
      ("\{scheme}://\{origin_host}", origin_host)
    }
  }
}

///|
/// Split an endpoint into scheme and `host[:port]`. Endpoints without a
/// scheme default to `https`.
fn endpoint_parts(endpoint : String) -> (String, String) {
  match endpoint.find("://") {
    None => ("https", endpoint)
    Some(_) =>
      match @uri.parse_uri_reference(endpoint) {
        Ok(uri) if uri.authority is Some(authority) =>
          (uri.scheme, @uri.authority_to_string(authority))
        _ => ("https", endpoint)
      }
  }
}

///|
/// Percent-encode the object key (and bucket, in path style) into the
/// request path: unreserved characters survive, `/` separators pass
/// through, non-ASCII characters encode as UTF-8.
fn canonical_object_path(
  config : Config,
  bucket : String,
  key : String,
) -> String {
  let object = if key == "" { "/" } else { "/\{key}" }
  match config.endpoint_style {
    VirtualHost => @sigv4.percent_encode_path(object)
    Path =>
      "/\{@sigv4.percent_encode_path(bucket)}\{@sigv4.percent_encode_path(object)}"
  }
}

///|
fn append_query(path : String, query : String) -> String {
  if query == "" {
    path
  } else {
    "\{path}?\{query}"
  }
}
