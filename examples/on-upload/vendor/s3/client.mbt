///|
/// Sign a request for an already-resolved origin/host/path. The shared core
/// of `prepare_request` (bucket operations) and `prepare_service_request`
/// (bucketless operations such as ListBuckets).
fn Client::sign_request(
  self : Client,
  meth : S3Method,
  origin : String,
  host : String,
  path : String,
  body : &@io.Data,
  options : RequestOptions,
) -> Request raise {
  let timestamp = match options.timestamp {
    Some(value) => value
    None => now_timestamp()
  }
  let query = query_params(options.query)
  let headers = copy_user_headers(options.headers)
  if meth is Put && !contains_header(headers, "content-length") {
    headers["Content-Length"] = body.binary().length().to_string()
  }
  headers["Accept-Encoding"] = "identity"
  headers["Host"] = host
  let payload_hash = match options.payload_hash {
    Some(value) => @sigv4.Provided(value)
    None => @sigv4.Sha256
  }
  let signed = @sigv4.sign(
    {
      meth: http_method(meth),
      path,
      query,
      headers: headers.to_array(),
      body: body.binary(),
    },
    to_sigv4_credentials(self.config.credentials),
    @sigv4.SigningOptions::for_s3(
      timestamp~,
      region=self.config.region,
      payload_hash~,
    ),
  )
  {
    origin,
    target: append_query(path, @sigv4.canonical_query_string(signed.query)),
    headers: headers_map(signed.headers),
  }
}

///|
fn Client::prepare_request(
  self : Client,
  meth : S3Method,
  bucket : String,
  key : String,
  body : &@io.Data,
  options~ : RequestOptions = RequestOptions(),
) -> Request raise {
  if bucket == "" {
    raise S3Error::InvalidInput("bucket must not be empty")
  }
  let (origin, host) = endpoint_origin_and_host(self.config, bucket)
  let path = canonical_object_path(self.config, bucket, key)
  self.sign_request(meth, origin, host, path, body, options)
}

///|
/// Prepare a bucketless request against the bare service endpoint (e.g.
/// ListBuckets): `GET /` on `s3.<region>.amazonaws.com` or the configured
/// endpoint, with no bucket component in the host or path.
fn Client::prepare_service_request(
  self : Client,
  meth : S3Method,
  body : &@io.Data,
  options~ : RequestOptions = RequestOptions(),
) -> Request raise {
  let (scheme, host) = service_endpoint_parts(self.config)
  self.sign_request(meth, "\{scheme}://\{host}", host, "/", body, options)
}

///|
fn headers_map(headers : Array[(String, String)]) -> Map[String, String] {
  let map : Map[String, String] = Map([])
  for pair in headers {
    map[pair.0] = pair.1
  }
  map
}

///|
fn ensure_object_key(key : String) -> Unit raise {
  if key == "" {
    raise S3Error::InvalidInput("key must not be empty")
  }
}

///|
fn copy_user_headers(headers : Map[String, String]) -> Map[String, String] {
  let copied : Map[String, String] = Map([])
  for key, value in headers {
    if !is_signer_controlled_header(key) {
      copied[key] = value
    }
  }
  copied
}

///|
fn is_signer_controlled_header(name : String) -> Bool {
  name.compare_ignore_ascii_case("accept-encoding") == 0 ||
  name.compare_ignore_ascii_case("authorization") == 0 ||
  name.compare_ignore_ascii_case("host") == 0 ||
  name.compare_ignore_ascii_case("transfer-encoding") == 0 ||
  name.compare_ignore_ascii_case("x-amz-content-sha256") == 0 ||
  name.compare_ignore_ascii_case("x-amz-date") == 0 ||
  name.compare_ignore_ascii_case("x-amz-security-token") == 0
}

///|
fn contains_header(headers : Map[String, String], name : String) -> Bool {
  for key, _ in headers {
    if key.compare_ignore_ascii_case(name) == 0 {
      return true
    }
  }
  false
}

///|
fn http_method(meth : S3Method) -> @http.RequestMethod {
  match meth {
    Get => @http.Get
    Head => @http.Head
    Put => @http.Put
    Delete => @http.Delete
  }
}

///|
async fn[T] Client::send(
  self : Client,
  meth : S3Method,
  bucket : String,
  key : String,
  body : &@io.Data,
  options~ : RequestOptions = RequestOptions(),
  f : async (@http.Response, @http.Client) -> T,
) -> T {
  let request = self.prepare_request(meth, bucket, key, body, options~)
  send_request(meth, request, body, f)
}

///|
async fn[T] Client::send_service(
  self : Client,
  meth : S3Method,
  body : &@io.Data,
  options~ : RequestOptions = RequestOptions(),
  f : async (@http.Response, @http.Client) -> T,
) -> T {
  let request = self.prepare_service_request(meth, body, options~)
  send_request(meth, request, body, f)
}

///|
async fn[T] send_request(
  meth : S3Method,
  request : Request,
  body : &@io.Data,
  f : async (@http.Response, @http.Client) -> T,
) -> T {
  let client = @http.Client(request.origin)
  let extra_headers = signed_headers(request)

  defer client.close()
  client.request(http_method(meth), request.target, extra_headers~)
  if meth is Put {
    client.write(body)
  }
  let response = client.end_request()
  f(response, client)
}

///|
fn Request::extra_headers(self : Request) -> Map[String, String] {
  let headers : Map[String, String] = Map([])
  for key, value in self.headers {
    if key.compare_ignore_ascii_case("host") != 0 {
      headers[key] = value
    }
  }
  headers
}

///|
fn signed_headers(
  request : Request,
) -> Map[@http.CaseInsensitiveString, String] {
  let headers : Map[@http.CaseInsensitiveString, String] = Map([])
  for key, value in request.extra_headers() {
    headers[@http.CaseInsensitiveString(key)] = value
  }
  headers
}

///|
fn ensure_success_response(
  response : @http.Response,
  body : String,
) -> Unit raise {
  if !is_success_response(response) {
    raise S3Error::ServiceError(response, body)
  }
}

///|
fn is_success_response(response : @http.Response) -> Bool {
  response.code >= 200 && response.code < 300
}

///|
async fn read_error_body(client : @http.Client) -> String {
  client.read_all().text()
}

///|
async fn raise_service_error_response(
  response : @http.Response,
  client : @http.Client,
) -> Unit {
  let body = read_error_body(client)
  raise S3Error::ServiceError(response, body)
}

///|
fn raise_service_error_response_without_body(
  response : @http.Response,
) -> Unit raise {
  raise S3Error::ServiceError(response, "")
}

///|
pub async fn Client::get_object(
  self : Client,
  bucket : String,
  key : String,
  options~ : RequestOptions = RequestOptions(),
) -> ObjectResult {
  ensure_object_key(key)
  let request = self.prepare_request(Get, bucket, key, b"", options~)
  let client = @http.Client(request.origin)
  let extra_headers = signed_headers(request)

  errdefer client.close()
  let response = client
    ..request(@http.Get, request.target, extra_headers~)
    .end_request()
  if !is_success_response(response) {
    defer client.close()
    raise_service_error_response(response, client)
  }
  { response, body: client, }
}

///|
pub async fn Client::put_object(
  self : Client,
  bucket : String,
  key : String,
  body : &@io.Data,
  options~ : RequestOptions = RequestOptions(),
) -> @http.Response {
  ensure_object_key(key)
  self.send(Put, bucket, key, body, options~, (response, client) => {
    if !is_success_response(response) {
      raise_service_error_response(response, client)
    }
    response
  })
}

///|
pub async fn Client::delete_object(
  self : Client,
  bucket : String,
  key : String,
  options~ : RequestOptions = RequestOptions(),
) -> @http.Response {
  ensure_object_key(key)
  self.send(Delete, bucket, key, b"", options~, (response, client) => {
    if !is_success_response(response) {
      raise_service_error_response(response, client)
    }
    response
  })
}

///|
pub async fn Client::head_object(
  self : Client,
  bucket : String,
  key : String,
  options~ : RequestOptions = RequestOptions(),
) -> @http.Response {
  ensure_object_key(key)
  self.send(Head, bucket, key, b"", options~, (response, client) => {
    if !is_success_response(response) {
      ignore(client)
      raise_service_error_response_without_body(response)
    }
    response
  })
}

///|
pub async fn Client::list_objects_v2(
  self : Client,
  bucket : String,
  prefix? : String,
  delimiter? : String,
  continuation_token? : String,
  max_keys? : Int32,
  options~ : RequestOptions = RequestOptions(),
) -> ListObjectsV2Result {
  let query = options.query.copy()
  query["list-type"] = "2"
  if prefix is Some(value) {
    query["prefix"] = value
  }
  if delimiter is Some(value) {
    query["delimiter"] = value
  }
  if continuation_token is Some(value) {
    query["continuation-token"] = value
  }
  if max_keys is Some(value) {
    query["max-keys"] = value.to_string()
  }
  let options = {
    headers: options.headers,
    query,
    timestamp: options.timestamp,
    payload_hash: options.payload_hash,
  }
  self.send(Get, bucket, "", b"", options~, (response, client) => {
    let body = client.read_all().text()
    ensure_success_response(response, body)
    parse_list_objects_v2(body)
  })
}

///|
/// List all buckets owned by the authenticated account.
///
///    :param prefix: Optional — restrict results to buckets whose names
///        begin with this prefix
///    :param continuation_token: Optional — token from a previous truncated
///        response
///    :param max_buckets: Optional — cap on the number of buckets returned
///    :return: The bucket list, plus owner identity and pagination fields
pub async fn Client::list_buckets(
  self : Client,
  prefix? : String,
  continuation_token? : String,
  max_buckets? : Int32,
  options~ : RequestOptions = RequestOptions(),
) -> ListBucketsResult {
  let query = options.query.copy()
  if prefix is Some(value) {
    query["prefix"] = value
  }
  if continuation_token is Some(value) {
    query["continuation-token"] = value
  }
  if max_buckets is Some(value) {
    query["max-buckets"] = value.to_string()
  }
  let options = {
    headers: options.headers,
    query,
    timestamp: options.timestamp,
    payload_hash: options.payload_hash,
  }
  self.send_service(Get, b"", options~, (response, client) => {
    let body = client.read_all().text()
    ensure_success_response(response, body)
    parse_list_buckets(body)
  })
}

///|
/// Check that a bucket exists and the caller has permission to access it.
/// A successful response proves existence; a 403 means the bucket exists
/// but is owned by another account; a 404 raises `ServiceError`.
///
///    :param bucket: Name of the S3 bucket
///    :return: The response on success (no response body for HEAD)
pub async fn Client::head_bucket(
  self : Client,
  bucket : String,
  options~ : RequestOptions = RequestOptions(),
) -> @http.Response {
  self.send(Head, bucket, "", b"", options~, (response, client) => {
    if !is_success_response(response) {
      ignore(client)
      raise_service_error_response_without_body(response)
    }
    response
  })
}

///|
/// The `CreateBucketConfiguration` body S3 requires when creating a bucket
/// outside `us-east-1` (which rejects the constraint instead).
fn create_bucket_configuration(region : String) -> String {
  "<CreateBucketConfiguration><LocationConstraint>\{region}</LocationConstraint></CreateBucketConfiguration>"
}

///|
/// Create a bucket. Outside `us-east-1` the request carries a
/// `LocationConstraint` with the configured region, as the S3 API requires.
///
///    :param bucket: Name of the S3 bucket to create
///    :return: The response on success (200, or 3xx redirect)
pub async fn Client::create_bucket(
  self : Client,
  bucket : String,
  options~ : RequestOptions = RequestOptions(),
) -> @http.Response {
  let body : Bytes = if self.config.region == "us-east-1" {
    b""
  } else {
    @utf8.encode(create_bucket_configuration(self.config.region))
  }
  self.send(Put, bucket, "", body, options~, (response, client) => {
    if !is_success_response(response) {
      raise_service_error_response(response, client)
    }
    response
  })
}

///|
/// Delete a bucket. The bucket must be empty, or S3 rejects the request
/// with `BucketNotEmpty`.
///
///    :param bucket: Name of the S3 bucket to delete
///    :return: The response on success (204)
pub async fn Client::delete_bucket(
  self : Client,
  bucket : String,
  options~ : RequestOptions = RequestOptions(),
) -> @http.Response {
  self.send(Delete, bucket, "", b"", options~, (response, client) => {
    if !is_success_response(response) {
      raise_service_error_response(response, client)
    }
    response
  })
}

///|
fn Client::presigned_url(
  self : Client,
  meth : S3Method,
  bucket : String,
  key : String,
  expires_seconds~ : Int32 = 3600,
  content_type? : String,
) -> String raise {
  ensure_object_key(key)
  if expires_seconds <= 0 || expires_seconds > 604800 {
    raise S3Error::InvalidInput("expires_seconds must be between 1 and 604800")
  }
  let (origin, host) = endpoint_origin_and_host(self.config, bucket)
  let path = canonical_object_path(self.config, bucket, key)
  let headers = match content_type {
    Some(value) => [("Host", host), ("Content-Type", value)]
    None => [("Host", host)]
  }
  let (scheme, _) = endpoint_parts(origin)
  let presigned = @sigv4.presign_url(
    request={ meth: http_method(meth), path, query: [], headers, body: b"", },
    credentials=to_sigv4_credentials(self.config.credentials),
    options=@sigv4.SigningOptions::for_s3(
      timestamp=now_timestamp(),
      region=self.config.region,
      payload_hash=Unsigned,
    ),
    expires=expires_seconds,
    scheme~,
  )
  presigned.url
}

///|
/// Generate a presigned GET URL for an S3 object.
///
///    :param bucket: Name of the S3 bucket
///    :param key: Key (path) of the object within the bucket
///    :param expires_seconds: Time in seconds for the URL to remain valid
///        (default 1 hour, maximum 7 days)
///    :return: Presigned URL as a string
pub fn Client::generate_presigned_get_url(
  self : Client,
  bucket : String,
  key : String,
  expires_seconds~ : Int32 = 3600,
) -> String raise {
  self.presigned_url(Get, bucket, key, expires_seconds~)
}

///|
/// Generate a presigned PUT URL for uploading an object directly to S3.
///
///    :param bucket: Name of the S3 bucket
///    :param key: Key (path) where the object will be stored
///    :param expires_seconds: Time in seconds the URL remains valid
///        (default 1 hour, maximum 7 days)
///    :param content_type: Optional — if set, the client MUST send this exact
///        Content-Type header when uploading, or S3 will reject it
///    :return: Presigned URL as a string
pub fn Client::generate_presigned_put_url(
  self : Client,
  bucket : String,
  key : String,
  expires_seconds~ : Int32 = 3600,
  content_type? : String,
) -> String raise {
  self.presigned_url(Put, bucket, key, expires_seconds~, content_type?)
}

///|
impl ReadCloser for @http.Client

///|
impl ReadCloser for @http.Client with fn close(self) {
  self.close()
}
