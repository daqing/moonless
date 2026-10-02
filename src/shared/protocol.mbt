///|
// Inter-service protocol types and their JSON codecs: CLI -> gateway ->
// builder/runner requests and results, plus the function registry record.

///|
pub struct DeployRequest {
  name : String
  archive : String // tar.gz of the project + vendored .mooncakes/, base64
} derive(Debug)

///|
pub extend DeployRequest with Debug::{to_repr}

///|
pub fn DeployRequest::DeployRequest(
  name~ : String,
  archive~ : String,
) -> DeployRequest {
  { name, archive, }
}

///|
pub struct BuildResult {
  ok : Bool
  build_id : String // empty when the build failed
  wasm_path : String // path of func.wasm, empty when the build failed
  error_tail : String // tail of build stderr shown by the CLI on failure
} derive(Debug)

///|
pub extend BuildResult with Debug::{to_repr}

///|
pub fn BuildResult::BuildResult(
  ok~ : Bool,
  build_id? : String = "",
  wasm_path? : String = "",
  error_tail? : String = "",
) -> BuildResult {
  { ok, build_id, wasm_path, error_tail, }
}

///|
pub struct RunRequest {
  name : String
  event : Event
  env : Map[String, String] // extra env injected into the function process
} derive(Debug)

///|
pub extend RunRequest with Debug::{to_repr}

///|
pub fn RunRequest::RunRequest(
  name~ : String,
  event~ : Event,
  env? : Map[String, String] = Map([]),
) -> RunRequest {
  { name, event, env, }
}

///|
pub struct RunResult {
  stdout : String
  stderr : String
  exit_code : Int
  duration_ms : Int
  truncated : Bool // per-stream output cap hit, R4
} derive(Debug)

///|
pub extend RunResult with Debug::{to_repr}

///|
pub fn RunResult::RunResult(
  stdout? : String = "",
  stderr? : String = "",
  exit_code? : Int = 0,
  duration_ms? : Int = 0,
  truncated? : Bool = false,
) -> RunResult {
  { stdout, stderr, exit_code, duration_ms, truncated, }
}

///|
pub struct RegistryRecord {
  name : String
  manifest : Manifest
  build_id : String
  updated_at : String // ISO-8601 UTC
} derive(Debug)

///|
pub extend RegistryRecord with Debug::{to_repr}

///|
pub fn RegistryRecord::RegistryRecord(
  name~ : String,
  manifest~ : Manifest,
  build_id~ : String,
  updated_at~ : String,
) -> RegistryRecord {
  { name, manifest, build_id, updated_at, }
}

///|
pub fn DeployRequest::to_json(self : DeployRequest) -> Json {
  let json : Json = { "name": self.name, "archive": self.archive }
  json
}

///|
pub fn DeployRequest::from_json(json : Json) -> DeployRequest raise SharedError {
  guard json is Object(obj) else {
    raise InvalidJson("deploy request expected an object")
  }
  DeployRequest(
    name=json_field_string(obj, "name"),
    archive=json_field_string(obj, "archive"),
  )
}

///|
pub fn BuildResult::to_json(self : BuildResult) -> Json {
  let json : Json = {
    "ok": self.ok,
    "buildId": self.build_id,
    "wasmPath": self.wasm_path,
    "errorTail": self.error_tail,
  }
  json
}

///|
pub fn BuildResult::from_json(json : Json) -> BuildResult raise SharedError {
  guard json is Object(obj) else {
    raise InvalidJson("build result expected an object")
  }
  BuildResult(
    ok=json_field_bool(obj, "ok"),
    build_id=json_field_string(obj, "buildId"),
    wasm_path=json_field_string(obj, "wasmPath"),
    error_tail=json_field_string(obj, "errorTail"),
  )
}

///|
pub fn RunRequest::to_json(self : RunRequest) -> Json {
  let env : Map[String, Json] = Map([])
  for key, value in self.env {
    env[key] = Json::string(value)
  }
  let json : Json = {
    "name": self.name,
    "event": self.event.to_json(),
    "env": Json::object(env),
  }
  json
}

///|
pub fn RunRequest::from_json(json : Json) -> RunRequest raise SharedError {
  guard json is Object(obj) else {
    raise InvalidJson("run request expected an object")
  }
  guard json_field(obj, "event") is Some(event_json) else {
    raise InvalidJson("run request has no event")
  }
  let event = Event::from_json(event_json)
  RunRequest(
    name=json_field_string(obj, "name"),
    event~,
    env=json_field_string_map(obj, "env"),
  )
}

///|
pub fn RunResult::to_json(self : RunResult) -> Json {
  let json : Json = {
    "stdout": self.stdout,
    "stderr": self.stderr,
    "exitCode": self.exit_code,
    "durationMs": self.duration_ms,
    "truncated": self.truncated,
  }
  json
}

///|
pub fn RunResult::from_json(json : Json) -> RunResult raise SharedError {
  guard json is Object(obj) else {
    raise InvalidJson("run result expected an object")
  }
  RunResult(
    stdout=json_field_string(obj, "stdout"),
    stderr=json_field_string(obj, "stderr"),
    exit_code=json_field_int(obj, "exitCode"),
    duration_ms=json_field_int(obj, "durationMs"),
    truncated=json_field_bool(obj, "truncated"),
  )
}

///|
pub fn RegistryRecord::to_json(self : RegistryRecord) -> Json {
  let json : Json = {
    "name": self.name,
    "manifest": self.manifest.to_json(),
    "buildId": self.build_id,
    "updatedAt": self.updated_at,
  }
  json
}

///|
pub fn RegistryRecord::from_json(
  json : Json,
) -> RegistryRecord raise SharedError {
  guard json is Object(obj) else {
    raise InvalidJson("registry record expected an object")
  }
  guard json_field(obj, "manifest") is Some(manifest_json) else {
    raise InvalidJson("registry record has no manifest")
  }
  let manifest = Manifest::from_json(manifest_json)
  RegistryRecord(
    name=json_field_string(obj, "name"),
    manifest~,
    build_id=json_field_string(obj, "buildId"),
    updated_at=json_field_string(obj, "updatedAt"),
  )
}

///|
pub fn Manifest::to_json(self : Manifest) -> Json {
  let triggers : Map[String, Json] = Map([])
  triggers["http"] = if self.triggers.http_enabled {
    let enabled : Json = { "enabled": true }
    enabled
  } else {
    Json::null()
  }
  triggers["cron"] = match self.triggers.cron {
    Some(expr) => Json::string(expr)
    None => Json::null()
  }
  triggers["s3"] = match self.triggers.s3 {
    Some(s3) => {
      let s3_json : Map[String, Json] = Map([])
      s3_json["bucket"] = Json::string(s3.bucket)
      s3_json["events"] = Json::array(
        s3.events.map(event => Json::string(event)),
      )
      Json::object(s3_json)
    }
    None => Json::null()
  }
  let root : Map[String, Json] = Map([])
  root["name"] = Json::string(self.name)
  root["toolchain"] = match self.toolchain {
    Some(v) => Json::string(v)
    None => Json::null()
  }
  root["triggers"] = Json::object(triggers)
  Json::object(root)
}

///|
pub fn Manifest::from_json(json : Json) -> Manifest raise SharedError {
  guard json is Object(obj) else {
    raise InvalidJson("manifest expected an object")
  }
  let name = json_field_string(obj, "name")
  if name == "" {
    raise InvalidJson("manifest name must not be empty")
  }
  let toolchain = match obj.get("toolchain") {
    Some(String(v)) => Some(v)
    _ => None
  }
  let triggers = match json_field_object(obj, "triggers") {
    Some(t) => {
      let http_enabled = match json_field_object(t, "http") {
        Some(h) => json_field_bool(h, "enabled")
        None => false
      }
      let cron = match t.get("cron") {
        Some(String(expr)) => Some(expr)
        _ => None
      }
      let s3 = match json_field_object(t, "s3") {
        Some(s3_obj) => {
          let bucket = json_field_string(s3_obj, "bucket")
          if bucket == "" {
            raise InvalidJson("manifest s3.bucket must not be empty")
          }
          Some(
            S3Trigger(bucket~, events=json_field_string_array(s3_obj, "events")),
          )
        }
        None => None
      }
      ManifestTriggers(http_enabled~, cron?, s3?)
    }
    None => ManifestTriggers()
  }
  Manifest(name~, triggers~, toolchain?)
}

///|
fn json_field(obj : Map[String, Json], key : String) -> Json? {
  match obj.get(key) {
    Some(Null) | None => None
    Some(value) => Some(value)
  }
}

///|
fn json_field_string_map(
  obj : Map[String, Json],
  key : String,
) -> Map[String, String] raise SharedError {
  let out : Map[String, String] = Map([])
  match obj.get(key) {
    Some(Object(entries)) =>
      for k, v in entries {
        guard v is String(s) else {
          raise InvalidJson("field \{key} expected string values")
        }
        out[k] = s
      }
    Some(Null) | None => ()
    Some(_) => raise InvalidJson("field \{key} expected an object")
  }
  out
}
