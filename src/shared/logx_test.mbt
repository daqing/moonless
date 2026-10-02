///|
test "format_timestamp renders UTC ISO-8601 with milliseconds" {
  assert_eq(@shared.format_timestamp(0L), "1970-01-01T00:00:00.000Z")
  assert_eq(
    @shared.format_timestamp(1790928000000L),
    "2026-10-02T08:00:00.000Z",
  )
  assert_eq(
    @shared.format_timestamp(1791071999000L),
    "2026-10-03T23:59:59.000Z",
  )
  assert_eq(
    @shared.format_timestamp(1790928000123L),
    "2026-10-02T08:00:00.123Z",
  )
  // Leap-year day: 2024-02-29T12:00:00Z.
  assert_eq(
    @shared.format_timestamp(1709208000000L),
    "2024-02-29T12:00:00.000Z",
  )
}

///|
async test "log helpers write without raising" {
  @shared.log_info(service="shared-test", message="info line")
  @shared.log_warn(service="shared-test", message="warn line")
  @shared.log_error(service="shared-test", message="error line")
}
