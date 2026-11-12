///|
// Decoding and validation of moonless.toml, the function manifest: name
// required, triggers all optional, cron a five-field expression, s3.methods
// a subset of {get, put, delete}, and an optional toolchain that must
// not exceed the platform's pinned version (R1).

///|
// Must stay in sync with ARG MOONBIT_VERSION in the Dockerfile.
pub let platform_toolchain : String = "0.10.14+7d59c7ec9"

///|
#derive(Debug)
pub struct S3Trigger {
  bucket : String
  methods : Array[String]
}

///|
pub extend S3Trigger with Debug::{to_repr}

///|
pub fn S3Trigger::S3Trigger(
  bucket~ : String,
  methods~ : Array[String],
) -> S3Trigger {
  { bucket, methods, }
}

///|
#derive(Debug)
pub struct ManifestTriggers {
  http_enabled : Bool
  cron : String?
  s3 : S3Trigger?
}

///|
pub extend ManifestTriggers with Debug::{to_repr}

///|
pub fn ManifestTriggers::ManifestTriggers(
  http_enabled~ : Bool = false,
  cron? : String,
  s3? : S3Trigger,
) -> ManifestTriggers {
  { http_enabled, cron, s3, }
}

///|
#derive(Debug)
pub struct FunctionLimits {
  timeout_ms : Int32?
  concurrency : Int32?
}

///|
pub extend FunctionLimits with Debug::{to_repr}

///|
pub fn FunctionLimits::FunctionLimits(
  timeout_ms~ : Int32? = None,
  concurrency~ : Int32? = None,
) -> FunctionLimits {
  { timeout_ms, concurrency, }
}

///|
#derive(Debug)
pub struct Manifest {
  name : String
  triggers : ManifestTriggers
  toolchain : String?
  limits : FunctionLimits
  sandbox : String?
}

///|
pub extend Manifest with Debug::{to_repr}

///|
pub fn Manifest::Manifest(
  name~ : String,
  triggers~ : ManifestTriggers = ManifestTriggers(),
  toolchain? : String,
  limits~ : FunctionLimits = FunctionLimits(),
  sandbox? : String,
) -> Manifest {
  { name, triggers, toolchain, limits, sandbox, }
}

///|
fn version_parts(version : String) -> Array[Int32] raise SharedError {
  let numeric : StringView = match version.split_once("+") {
    Some((head, _)) => head
    None => version[:]
  }
  let parts : Array[Int32] = []
  for part in numeric.split(".") {
    parts.push(
      @string.parse_int(part) catch {
        _ => raise InvalidManifest("malformed version: \{version}")
      },
    )
  }
  if parts.length() == 0 {
    raise InvalidManifest("malformed version: \{version}")
  }
  parts
}

///|
// Compares two moonc-style version strings numerically (major.minor.patch),
// ignoring any "+build" suffix. Returns -1 / 0 / 1; raises on malformed input.
pub fn compare_toolchain_versions(
  lhs : String,
  rhs : String,
) -> Int32 raise SharedError {
  let l = version_parts(lhs)
  let r = version_parts(rhs)
  let len = if l.length() > r.length() { l.length() } else { r.length() }
  for i in 0..<len {
    let lv = l.get(i).unwrap_or(0)
    let rv = r.get(i).unwrap_or(0)
    if lv < rv {
      return -1
    }
    if lv > rv {
      return 1
    }
  }
  0
}

///|
pub fn parse_manifest(source : String) -> Manifest raise SharedError {
  let doc = @toml.parse(source) catch {
    err => raise InvalidManifest("invalid TOML: \{err}")
  }
  guard doc is @toml.TomlTable(root) else {
    raise InvalidManifest("manifest expected a top-level table")
  }
  let name = match toml_string(root, "name") {
    Some("") => raise InvalidManifest("name must not be empty")
    Some(n) => n
    None => raise InvalidManifest("name is required")
  }
  let toolchain : String? = match toml_string(root, "toolchain") {
    Some(v) => {
      if compare_toolchain_versions(v, platform_toolchain) > 0 {
        raise InvalidManifest(
          "toolchain \{v} exceeds the platform's pinned \{platform_toolchain}",
        )
      }
      Some(v)
    }
    None => None
  }
  let triggers = match toml_table(root, "triggers") {
    Some(t) => parse_triggers(t)
    None => ManifestTriggers()
  }
  let limits = match toml_table(root, "limits") {
    Some(t) => parse_limits(t)
    None => FunctionLimits()
  }
  let sandbox = match toml_string(root, "sandbox") {
    Some(path) => Some(validate_package_path(path))
    None => None
  }
  Manifest(name~, triggers~, toolchain?, limits~, sandbox?)
}

///|
fn validate_package_path(path : String) -> String raise SharedError {
  if path == "" || path.has_prefix("/") || path.contains("\\") {
    raise InvalidManifest("expected a relative path inside the package")
  }
  for segment in path.split("/") {
    if segment == "" || segment == "." || segment == ".." {
      raise InvalidManifest("path contains an unsafe segment")
    }
  }
  path
}

///|
fn parse_limits(
  tbl : Map[String, @toml.TomlValue],
) -> FunctionLimits raise SharedError {
  FunctionLimits(
    timeout_ms=toml_positive_int(tbl, "timeout_ms"),
    concurrency=toml_positive_int(tbl, "concurrency"),
  )
}

///|
fn toml_positive_int(
  tbl : Map[String, @toml.TomlValue],
  key : String,
) -> Int32? raise SharedError {
  match tbl.get(key) {
    Some(@toml.TomlInteger(value)) => {
      if value <= 0L || value > 2_147_483_647L {
        raise InvalidManifest("limits.\{key} must be a positive Int32")
      }
      Some(value.to_int())
    }
    None => None
    Some(_) => raise InvalidManifest("limits.\{key} expected an integer")
  }
}

///|
fn parse_triggers(
  t : Map[String, @toml.TomlValue],
) -> ManifestTriggers raise SharedError {
  let http_enabled = match t.get("http") {
    Some(@toml.TomlBoolean(enabled)) => enabled
    Some(@toml.TomlTable(h)) => toml_bool(h, "enabled").unwrap_or(true)
    None => false
    Some(_) =>
      raise InvalidManifest("manifest trigger http expected a bool or table")
  }
  let cron : String? = match toml_string(t, "cron") {
    Some(expr) =>
      if is_five_field_cron(expr) {
        Some(expr)
      } else {
        raise InvalidManifest("cron must be a five-field expression: \{expr}")
      }
    None => None
  }
  let s3 : S3Trigger? = match toml_table(t, "s3") {
    Some(tbl) => {
      let bucket = match toml_string(tbl, "bucket") {
        Some("") => raise InvalidManifest("s3.bucket must not be empty")
        Some(b) => b
        None => raise InvalidManifest("s3.bucket is required")
      }
      let methods = match toml_string_array(tbl, "methods") {
        Some(methods) => {
          for entry in methods {
            guard entry is ("get" | "put" | "delete") else {
              raise InvalidManifest(
                "s3.methods entries must be get, put, or delete, got: \{entry}",
              )
            }
          }
          methods
        }
        None => raise InvalidManifest("s3.methods is required")
      }
      Some(S3Trigger(bucket~, methods~))
    }
    None => None
  }
  ManifestTriggers(http_enabled~, cron?, s3?)
}

///|
fn is_five_field_cron(expr : String) -> Bool {
  let mut count = 0
  for field in expr.split(" ") {
    if field != "" {
      count += 1
    }
  }
  count == 5
}

///|
fn toml_string(
  tbl : Map[String, @toml.TomlValue],
  key : String,
) -> String? raise SharedError {
  match tbl.get(key) {
    Some(@toml.TomlString(s)) => Some(s)
    None => None
    Some(_) => raise InvalidManifest("manifest key \{key} expected a string")
  }
}

///|
fn toml_bool(
  tbl : Map[String, @toml.TomlValue],
  key : String,
) -> Bool? raise SharedError {
  match tbl.get(key) {
    Some(@toml.TomlBoolean(b)) => Some(b)
    None => None
    Some(_) => raise InvalidManifest("manifest key \{key} expected a bool")
  }
}

///|
fn toml_table(
  tbl : Map[String, @toml.TomlValue],
  key : String,
) -> Map[String, @toml.TomlValue]? raise SharedError {
  match tbl.get(key) {
    Some(@toml.TomlTable(inner)) => Some(inner)
    None => None
    Some(_) => raise InvalidManifest("manifest key \{key} expected a table")
  }
}

///|
fn toml_string_array(
  tbl : Map[String, @toml.TomlValue],
  key : String,
) -> Array[String]? raise SharedError {
  match tbl.get(key) {
    Some(@toml.TomlArray(items)) => {
      let out = []
      for item in items {
        match item {
          @toml.TomlString(s) => out.push(s)
          _ => raise InvalidManifest("manifest key \{key} expected strings")
        }
      }
      Some(out)
    }
    None => None
    Some(_) => raise InvalidManifest("manifest key \{key} expected an array")
  }
}
