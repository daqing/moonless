///|
// Decoding and validation of moonless.toml, the function manifest: name
// required, triggers all optional, cron a five-field expression, s3.events
// a subset of {put, delete}, and an optional toolchain that must not exceed
// the platform's pinned version (R1).

///|
// Must stay in sync with ARG MOONBIT_VERSION in the Dockerfile.
pub let platform_toolchain : String = "0.10.14+7d59c7ec9"

///|
pub struct S3Trigger {
  bucket : String
  events : Array[String]
} derive(Debug)

///|
pub extend S3Trigger with Debug::{to_repr}

///|
pub fn S3Trigger::S3Trigger(
  bucket~ : String,
  events~ : Array[String],
) -> S3Trigger {
  { bucket, events, }
}

///|
pub struct ManifestTriggers {
  http_enabled : Bool
  cron : String?
  s3 : S3Trigger?
} derive(Debug)

///|
pub extend ManifestTriggers with Debug::{to_repr}

///|
pub fn ManifestTriggers::ManifestTriggers(
  http_enabled? : Bool = false,
  cron? : String,
  s3? : S3Trigger,
) -> ManifestTriggers {
  { http_enabled, cron, s3, }
}

///|
pub struct Manifest {
  name : String
  triggers : ManifestTriggers
  toolchain : String?
} derive(Debug)

///|
pub extend Manifest with Debug::{to_repr}

///|
pub fn Manifest::Manifest(
  name~ : String,
  triggers? : ManifestTriggers = ManifestTriggers(),
  toolchain? : String,
) -> Manifest {
  { name, triggers, toolchain, }
}

///|
fn version_parts(version : String) -> Array[Int] raise SharedError {
  let numeric : StringView = match version.split_once("+") {
    Some((head, _)) => head
    None => version[:]
  }
  let parts : Array[Int] = []
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
) -> Int raise SharedError {
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
  Manifest(name~, triggers~, toolchain?)
}

///|
fn parse_triggers(
  t : Map[String, @toml.TomlValue],
) -> ManifestTriggers raise SharedError {
  let http_enabled = match toml_table(t, "http") {
    Some(h) => toml_bool(h, "enabled").unwrap_or(true)
    None => false
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
      let events = match toml_string_array(tbl, "events") {
        Some(events) => {
          for event in events {
            guard event is ("put" | "delete") else {
              raise InvalidManifest(
                "s3.events entries must be put or delete, got: \{event}",
              )
            }
          }
          events
        }
        None => raise InvalidManifest("s3.events is required")
      }
      Some(S3Trigger(bucket~, events~))
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
