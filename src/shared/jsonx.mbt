///|
// JSON field helpers shared by the event and protocol codecs. Missing or
// null fields fall back to the caller's default; present-but-wrongly-typed
// fields raise instead of being silently dropped.

///|
pub(all) suberror SharedError {
  InvalidJson(String)
  InvalidEvent(String)
  InvalidManifest(String)
  InvalidArchive(String)
  RunError(String)
  HttpError(String)
} derive(Debug)

///|
pub extend SharedError with Debug::{to_repr}

///|
pub fn json_field_string(
  obj : Map[String, Json],
  key : String,
  default? : String = "",
) -> String raise SharedError {
  match obj.get(key) {
    Some(String(s)) => s
    Some(Null) | None => default
    Some(_) => raise InvalidJson("field \{key} expected a string")
  }
}

///|
pub fn json_field_int(
  obj : Map[String, Json],
  key : String,
  default? : Int = 0,
) -> Int raise SharedError {
  match obj.get(key) {
    Some(Number(v, ..)) => v.to_int()
    Some(Null) | None => default
    Some(_) => raise InvalidJson("field \{key} expected a number")
  }
}

///|
pub fn json_field_bool(
  obj : Map[String, Json],
  key : String,
  default? : Bool = false,
) -> Bool raise SharedError {
  match obj.get(key) {
    Some(True) => true
    Some(False) => false
    Some(Null) | None => default
    Some(_) => raise InvalidJson("field \{key} expected a bool")
  }
}

///|
pub fn json_field_object(
  obj : Map[String, Json],
  key : String,
) -> Map[String, Json]? raise SharedError {
  match obj.get(key) {
    Some(Object(inner)) => Some(inner)
    Some(Null) | None => None
    Some(_) => raise InvalidJson("field \{key} expected an object")
  }
}

///|
pub fn json_field_string_array(
  obj : Map[String, Json],
  key : String,
) -> Array[String] raise SharedError {
  match obj.get(key) {
    Some(Array(items)) => {
      let out = []
      for item in items {
        match item {
          String(s) => out.push(s)
          _ => raise InvalidJson("field \{key} expected an array of strings")
        }
      }
      out
    }
    Some(Null) | None => []
    Some(_) => raise InvalidJson("field \{key} expected an array")
  }
}
