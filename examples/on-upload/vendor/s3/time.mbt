///|
fn pad2(n : Int32) -> String {
  if n < 10 {
    "0\{n}"
  } else {
    n.to_string()
  }
}

///|
fn amz_timestamp(now_ms : UInt64) -> String raise {
  let secs = (now_ms / 1000UL).reinterpret_as_int64()
  let zdt = @time.unix(secs, zone=@time.utc_zone)
  let dt = zdt.to_plain_date_time()
  "\{dt.year()}\{pad2(dt.month())}\{pad2(dt.day())}T\{pad2(dt.hour())}\{pad2(dt.minute())}\{pad2(dt.second())}Z"
}

///|
fn now_timestamp() -> String raise {
  amz_timestamp(@env.now())
}
