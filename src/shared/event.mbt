///|
// The trigger context handed to a function as MOONLESS_EVENT. The JSON
// shapes are the ones documented in the README's function-contract section.

///|
pub struct HttpEventData {
  http_method : String
  path : String
  query : String
  body : String
} derive(Debug)

///|
pub extend HttpEventData with Debug::{to_repr}

///|
pub fn HttpEventData::HttpEventData(
  http_method~ : String,
  path~ : String,
  query~ : String,
  body~ : String,
) -> HttpEventData {
  { http_method, path, query, body, }
}

///|
pub struct CronEventData {
  schedule : String
  time : String
} derive(Debug)

///|
pub extend CronEventData with Debug::{to_repr}

///|
pub fn CronEventData::CronEventData(
  schedule~ : String,
  time~ : String,
) -> CronEventData {
  { schedule, time, }
}

///|
pub struct S3EventData {
  event_name : String
  bucket : String
  key : String
} derive(Debug)

///|
pub extend S3EventData with Debug::{to_repr}

///|
pub fn S3EventData::S3EventData(
  event~ : String,
  bucket~ : String,
  key~ : String,
) -> S3EventData {
  { event_name: event, bucket, key, }
}

///|
pub(all) enum Event {
  Http(HttpEventData)
  Cron(CronEventData)
  S3(S3EventData)
} derive(Debug)

///|
pub extend Event with Debug::{to_repr}

///|
pub fn Event::to_json(self : Event) -> Json {
  match self {
    Http(e) => {
      let json : Json = {
        "source": "http",
        "method": e.http_method,
        "path": e.path,
        "query": e.query,
        "body": e.body,
      }
      json
    }
    Cron(e) => {
      let json : Json = {
        "source": "cron",
        "schedule": e.schedule,
        "time": e.time,
      }
      json
    }
    S3(e) => {
      let json : Json = {
        "source": "s3",
        "event": e.event_name,
        "bucket": e.bucket,
        "key": e.key,
      }
      json
    }
  }
}

///|
pub fn Event::from_json(json : Json) -> Event raise SharedError {
  guard json is Object(obj) else {
    raise InvalidEvent("event expected an object")
  }
  let source = json_field_string(obj, "source", default="") catch { _ => "" }
  match source {
    "http" =>
      Http(
        HttpEventData(
          http_method=json_field_string(obj, "method", default="GET"),
          path=json_field_string(obj, "path", default=""),
          query=json_field_string(obj, "query", default=""),
          body=json_field_string(obj, "body", default=""),
        ),
      )
    "cron" =>
      Cron(
        CronEventData(
          schedule=json_field_string(obj, "schedule", default=""),
          time=json_field_string(obj, "time", default=""),
        ),
      )
    "s3" =>
      S3(
        S3EventData(
          event=json_field_string(obj, "event", default=""),
          bucket=json_field_string(obj, "bucket", default=""),
          key=json_field_string(obj, "key", default=""),
        ),
      )
    other => raise InvalidEvent("unknown event source: \{other}")
  }
}
