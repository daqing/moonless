///|
// Fixed UTC timestamps for next-fire assertions (from the same civil
// conversions used by the code under test, computed independently here).
fn epoch_ms(
  year : Int,
  month : Int,
  day : Int,
  hour : Int,
  minute : Int,
) -> Int64 {
  let days = civil_days(year, month, day)
  (
    days.to_int64() * 86_400L +
    hour.to_int64() * 3600L +
    minute.to_int64() * 60L
  ) *
  1000L
}

///|
// Independent days-from-civil for test data (mirrors the standard
// algorithm so tests do not just re-run the implementation).
fn civil_days(year : Int, month : Int, day : Int) -> Int {
  let y = if month <= 2 { year - 1 } else { year }
  let era = (if y >= 0 { y } else { y - 399 }) / 400
  let yoe = y - era * 400
  let mp = month + (if month > 2 { -3 } else { 9 })
  let doy = (153 * mp + 2) / 5 + day - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146097 + doe - 719468
}

///|
fn schedule(expr : String) -> @shared.CronSchedule raise {
  @shared.CronSchedule(name="t", expression=expr)
}

///|
test "next fire: every minute, hour rollovers, and day boundaries" {
  // 2026-10-03T08:21:00Z, "every minute" -> 08:22.
  let every_minute = schedule("* * * * *")
  assert_eq(
    next_fire(every_minute, epoch_ms(2026, 10, 3, 8, 21)),
    epoch_ms(2026, 10, 3, 8, 22),
  )
  // Hourly at :00 across an hour boundary.
  let hourly = schedule("0 * * * *")
  assert_eq(
    next_fire(hourly, epoch_ms(2026, 10, 3, 8, 21)),
    epoch_ms(2026, 10, 3, 9, 0),
  )
  // Daily at 08:00 across midnight.
  let daily = schedule("0 8 * * *")
  assert_eq(
    next_fire(daily, epoch_ms(2026, 10, 3, 9, 0)),
    epoch_ms(2026, 10, 4, 8, 0),
  )
  // Month rollover: Sep 30 23:59 -> Oct 1 00:05.
  let monthly = schedule("5 0 1 * *")
  assert_eq(
    next_fire(monthly, epoch_ms(2026, 9, 30, 23, 59)),
    epoch_ms(2026, 10, 1, 0, 5),
  )
}

///|
test "next fire: weekday and day-of-month semantics" {
  // 2026-10-03 is a Saturday. "Monday 09:30" -> 2026-10-05.
  let monday = schedule("30 9 * * 1")
  assert_eq(
    next_fire(monday, epoch_ms(2026, 10, 3, 0, 0)),
    epoch_ms(2026, 10, 5, 9, 30),
  )
  // Sunday is 0 (the library rejects 7 despite classic cron allowing it).
  let sunday0 = schedule("0 6 * * 0")
  assert_eq(
    next_fire(sunday0, epoch_ms(2026, 10, 3, 0, 0)),
    epoch_ms(2026, 10, 4, 6, 0),
  )
  // Restricted dom + dow fire on either match (Vixie OR): the 13th or
  // any Friday, whichever comes first after 2026-10-03.
  let either = schedule("0 12 13 * 5")
  // 2026-10-09 is a Friday.
  assert_eq(
    next_fire(either, epoch_ms(2026, 10, 3, 0, 0)),
    epoch_ms(2026, 10, 9, 12, 0),
  )
  // Lists and ranges: minutes 10-20 step 5 at hour 4-5.
  let stepped = schedule("10-40/15 4-5 * * *")
  assert_eq(
    next_fire(stepped, epoch_ms(2026, 10, 3, 4, 0)),
    epoch_ms(2026, 10, 3, 4, 10),
  )
  assert_eq(
    next_fire(stepped, epoch_ms(2026, 10, 3, 4, 10)),
    epoch_ms(2026, 10, 3, 4, 25),
  )
  assert_eq(
    next_fire(stepped, epoch_ms(2026, 10, 3, 4, 40)),
    epoch_ms(2026, 10, 3, 5, 10),
  )
}

///|
test "next fire: leap-year day" {
  // Feb 29 exists in 2028: "0 0 29 2 *".
  let leap = schedule("0 0 29 2 *")
  assert_eq(
    next_fire(leap, epoch_ms(2026, 10, 3, 0, 0)),
    epoch_ms(2028, 2, 29, 0, 0),
  )
}

///|
test "invalid cron expressions are rejected" {
  try schedule("not a cron") catch {
    @shared.InvalidManifest(message) =>
      assert_true(message.contains("invalid cron"))
    _ => fail("expected InvalidManifest for garbage cron")
  } noraise {
    _ => fail("expected invalid cron to be rejected")
  }
  try schedule("* * * *") catch {
    @shared.InvalidManifest(_) => ()
    _ => fail("expected InvalidManifest for four-field cron")
  } noraise {
    _ => fail("expected four-field cron to be rejected")
  }
}

///|
fn next_fire(sched : @shared.CronSchedule, after : Int64) -> Int64 raise {
  sched.next_fire_ms(after)
}
