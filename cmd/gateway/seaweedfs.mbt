///|
// Convert SeaweedFS filer notifications into moonless S3 trigger events.
// Create and update are object puts; unrelated paths and directory metadata
// changes are not function triggers.
fn adapt_seaweedfs_event(
  payload : Json,
) -> @shared.Event? raise @shared.SharedError {
  guard payload is Object(obj) else {
    raise @shared.InvalidEvent("SeaweedFS event expected an object")
  }
  let event_type = @shared.json_field_string(obj, "event_type")
  let event_name = match event_type {
    "create" | "update" => "put"
    "delete" => "delete"
    _ => return None
  }
  let path = @shared.json_field_string(obj, "key")
  guard path.has_prefix("/buckets/") else { return None }
  guard path[9:].split_once("/") is Some((bucket, key)) else { return None }
  if bucket == "" || key == "" || filer_entry_is_directory(obj, event_type) {
    return None
  }
  Some(
    @shared.Event::S3(
      @shared.S3EventData(
        event=event_name,
        bucket=bucket.to_owned(),
        key=key.to_owned(),
      ),
    ),
  )
}

///|
fn filer_entry_is_directory(
  obj : Map[String, Json],
  event_type : String,
) -> Bool raise @shared.SharedError {
  guard @shared.json_field_object(obj, "message") is Some(message) else {
    return false
  }
  let entry_key = if event_type == "delete" { "old_entry" } else { "new_entry" }
  match @shared.json_field_object(message, entry_key) {
    Some(entry) => @shared.json_field_bool(entry, "is_directory")
    None => false
  }
}
