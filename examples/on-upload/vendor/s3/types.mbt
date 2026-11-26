///|
#derive(Debug, Eq)
pub(all) enum EndpointStyle {
  VirtualHost
  Path
}

///|
priv enum S3Method {
  Get
  Head
  Put
  Delete
}

///|
#derive(Eq)
struct Credentials {
  access_key_id : String
  secret_access_key : String
  session_token : String?
}

///|
pub impl Debug for Credentials with fn to_repr(self) {
  let redacted = Repr::string("***")
  let session_token = match self.session_token {
    Some(_) => Repr::ctor("Some", [(None, redacted)])
    None => Repr::ctor("None", [])
  }
  Repr::record({
    "access_key_id": Repr::string(self.access_key_id),
    "secret_access_key": redacted,
    "session_token": session_token,
  })
}

///|
#derive(Debug, Eq)
struct Config {
  region : String
  credentials : Credentials
  endpoint : String?
  endpoint_style : EndpointStyle
}

///|
#derive(Debug)
pub suberror S3Error {
  InvalidConfig(String)
  InvalidInput(String)
  InvalidResponse(String)
  ServiceError(@http.Response, String)
}

///|
#derive(Eq, Debug)
struct Client {
  config : Config
}

///|
pub struct ObjectResult {
  response : @http.Response
  body : &ReadCloser
}

///|
#derive(Debug, Eq)
pub struct ListedObject {
  key : String
  size : Int64
  etag : String?
}

///|
#derive(Debug, Eq)
pub struct ListObjectsV2Result {
  is_truncated : Bool
  next_continuation_token : String?
  contents : Array[ListedObject]
  common_prefixes : Array[String]
}

///|
#derive(Debug, Eq)
pub struct Bucket {
  name : String
  creation_date : String?
}

///|
#derive(Debug, Eq)
pub struct ListBucketsResult {
  owner_id : String?
  owner_display_name : String?
  prefix : String?
  continuation_token : String?
  buckets : Array[Bucket]
}

///|
#derive(Debug)
struct RequestOptions {
  headers : Map[String, String]
  query : Map[String, String]
  timestamp : String?
  payload_hash : String?
}

///|
pub(open) trait ReadCloser: @io.Reader {
  fn close(Self) -> Unit
}

///|
priv struct Request {
  origin : String
  target : String
  headers : Map[String, String]
}

///|
pub fn Credentials::Credentials(
  access_key_id : String,
  secret_access_key : String,
  session_token? : String,
) -> Credentials {
  { access_key_id, secret_access_key, session_token, }
}

///|
/// Create an S3 client configuration.
///
/// `endpoint_style` is optional and defaults based on the endpoint:
/// - No `endpoint` (AWS default URL): `VirtualHost`, the AWS-standard
///   `bucket.s3.<region>.amazonaws.com` addressing.
/// - Custom `endpoint` (MinIO, R2, Ceph, Garage, ...): `Path`, since
///   third-party S3-compatible services generally do not resolve
///   `<bucket>.<endpoint>` subdomains.
/// An explicit `endpoint_style` always wins.
pub fn Config::Config(
  region : String,
  credentials : Credentials,
  endpoint? : String,
  endpoint_style? : EndpointStyle,
) -> Config {
  let endpoint_style = match endpoint_style {
    Some(style) => style
    None =>
      // Virtual-host addressing needs DNS control over `bucket.<endpoint>`,
      // which only AWS (the implicit endpoint) provides.
      match endpoint {
        Some(_) => Path
        None => VirtualHost
      }
  }
  { region, credentials, endpoint, endpoint_style, }
}

///|
pub fn RequestOptions::RequestOptions(
  headers~ : Map[String, String] = {},
  query~ : Map[String, String] = {},
  timestamp? : String,
  payload_hash? : String,
) -> RequestOptions {
  { headers, query, timestamp, payload_hash, }
}

///|
pub fn Client::Client(config : Config) -> Client raise {
  if config.region == "" {
    raise S3Error::InvalidConfig("region must not be empty")
  }
  if config.credentials.access_key_id == "" {
    raise S3Error::InvalidConfig("access key id must not be empty")
  }
  if config.credentials.secret_access_key == "" {
    raise S3Error::InvalidConfig("secret access key must not be empty")
  }
  { config, }
}
