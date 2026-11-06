///|
test "manifest parses the README's full example" {
  let manifest = @shared.parse_manifest(
    (
      #|name = "resize-images"
      #|
      #|[triggers]
      #|http = { enabled = true }
      #|cron = "0 8 * * *"
      #|s3 = { bucket = "uploads", events = ["put"] }
    ),
  )
  assert_eq(manifest.name, "resize-images")
  assert_eq(manifest.triggers.http_enabled, true)
  assert_eq(manifest.triggers.cron, Some("0 8 * * *"))
  guard manifest.triggers.s3 is Some(s3) else { fail("s3 trigger missing") }
  assert_eq(s3.bucket, "uploads")
  assert_eq(s3.events.length(), 1)
  assert_eq(s3.events[0], "put")
  assert_eq(manifest.toolchain, None)
}

///|
test "manifest with only a name uses default triggers" {
  let manifest = @shared.parse_manifest("name = \"hello\"")
  assert_eq(manifest.name, "hello")
  assert_eq(manifest.triggers.http_enabled, false)
  assert_eq(manifest.triggers.cron, None)
  assert_true(manifest.triggers.s3 is None)
  assert_eq(manifest.toolchain, None)
}

///|
test "manifest accepts a toolchain up to the pinned version" {
  let older = @shared.parse_manifest(
    (
      #|name = "hello"
      #|toolchain = "0.10.11"
    ),
  )
  assert_eq(older.toolchain, Some("0.10.11"))
  let pinned = @shared.parse_manifest(
    (
      #|name = "hello"
      #|toolchain = "0.10.14+7d59c7ec9"
    ),
  )
  assert_eq(pinned.toolchain, Some("0.10.14+7d59c7ec9"))
}

///|
test "manifest rejects missing or empty name" {
  try @shared.parse_manifest("toolchain = \"0.10.11\"") catch {
    @shared.InvalidManifest(_) => ()
    _ => fail("expected InvalidManifest")
  } noraise {
    _ => fail("expected missing name to be rejected")
  }
  try @shared.parse_manifest("name = \"\"") catch {
    @shared.InvalidManifest(_) => ()
    _ => fail("expected InvalidManifest")
  } noraise {
    _ => fail("expected empty name to be rejected")
  }
}

///|
test "manifest rejects malformed cron expressions" {
  // Whitespace runs are tolerated (still five fields); wrong field counts are not.
  for expr in ["0 8 * *", "0 8 * * * *", "* * *"] {
    let source = "name = \"f\"\n\n[triggers]\ncron = \"\{expr}\""
    try @shared.parse_manifest(source) catch {
      @shared.InvalidManifest(_) => ()
      _ => fail("expected InvalidManifest")
    } noraise {
      _ => fail("expected cron \{expr} to be rejected")
    }
  }
}

///|
test "manifest rejects s3 events outside put/delete and missing fields" {
  try
    @shared.parse_manifest(
      (
        #|name = "f"
        #|
        #|[triggers.s3]
        #|bucket = "uploads"
        #|events = ["put", "copy"]
      ),
    )
  catch {
    @shared.InvalidManifest(_) => ()
    _ => fail("expected InvalidManifest")
  } noraise {
    _ => fail("expected s3 event copy to be rejected")
  }
  try
    @shared.parse_manifest(
      (
        #|name = "f"
        #|
        #|[triggers.s3]
        #|events = ["put"]
      ),
    )
  catch {
    @shared.InvalidManifest(_) => ()
    _ => fail("expected InvalidManifest")
  } noraise {
    _ => fail("expected missing s3.bucket to be rejected")
  }
}

///|
test "manifest rejects a toolchain newer than the platform" {
  try
    @shared.parse_manifest(
      (
        #|name = "hello"
        #|toolchain = "0.10.15"
      ),
    )
  catch {
    @shared.InvalidManifest(_) => ()
    _ => fail("expected InvalidManifest")
  } noraise {
    _ => fail("expected toolchain newer than platform to be rejected")
  }
}

///|
test "manifest rejects invalid TOML and wrong-typed keys" {
  try @shared.parse_manifest("name = ") catch {
    @shared.InvalidManifest(_) => ()
    _ => fail("expected InvalidManifest")
  } noraise {
    _ => fail("expected broken TOML to be rejected")
  }
  try @shared.parse_manifest("name = 42") catch {
    @shared.InvalidManifest(_) => ()
    _ => fail("expected InvalidManifest")
  } noraise {
    _ => fail("expected non-string name to be rejected")
  }
}

///|
test "toolchain version comparison ignores build suffixes" {
  assert_eq(
    @shared.compare_toolchain_versions("0.10.14", "0.10.14+7d59c7ec9"),
    0,
  )
  assert_eq(@shared.compare_toolchain_versions("0.9.99", "0.10.1"), -1)
  assert_eq(@shared.compare_toolchain_versions("1.0", "0.10.14"), 1)
  assert_eq(@shared.compare_toolchain_versions("0.10.14.1", "0.10.14"), 1)
}

///|
test "manifest parses and round-trips per-function limits" {
  let manifest = @shared.parse_manifest(
    (
      #|name = "limited"
      #|
      #|[limits]
      #|timeout_ms = 2500
      #|concurrency = 2
    ),
  )
  assert_eq(manifest.limits.timeout_ms, Some(2500))
  assert_eq(manifest.limits.concurrency, Some(2))
  let back = @shared.Manifest::from_json(manifest.to_json())
  assert_eq(back.limits.timeout_ms, Some(2500))
  assert_eq(back.limits.concurrency, Some(2))
}

///|
test "manifest rejects non-positive limits" {
  for
    source in [
      "name = \"limited\"\n[limits]\ntimeout_ms = 0", "name = \"limited\"\n[limits]\nconcurrency = -1",
    ] {
    try @shared.parse_manifest(source) catch {
      @shared.InvalidManifest(_) => ()
      _ => fail("expected InvalidManifest")
    } noraise {
      _ => fail("expected invalid limits to be rejected")
    }
  }
}

///|
test "manifest binary mode is explicit and path-safe" {
  let manifest = @shared.parse_manifest(
    "name = \"native\"\nbinary = \"bin/func\"\nsandbox = \"policy.json\"",
  )
  assert_eq(manifest.binary, Some("bin/func"))
  assert_eq(manifest.sandbox, Some("policy.json"))
  let back = @shared.Manifest::from_json(manifest.to_json())
  assert_eq(back.binary, Some("bin/func"))
  assert_eq(back.sandbox, Some("policy.json"))
  for path in ["", "/bin/func", "../func", "bin/../func"] {
    try
      @shared.parse_manifest("name = \"native\"\nbinary = \"\{path}\"")
    catch {
      @shared.InvalidManifest(_) => ()
      _ => fail("expected InvalidManifest")
    } noraise {
      _ => fail("expected binary path \{path} to be rejected")
    }
  }
}
