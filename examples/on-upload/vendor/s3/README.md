# Vendored S3 client

[中文版](README.zh-CN.md)

A patched copy of [`kaashyapan/s3@0.6.0`](https://mooncakes.io/docs/kaashyapan/s3@0.6.0)
(Apache-2.0, see `LICENSE`). It is checked in because the published module cannot
be built with moonless's pinned toolchain:

- `0.6.0` depends on `moonbitlang/async@0.20.3`, whose wasm sources call trait
  implementations as plain methods (`self.to_string()`,
  `self.reader._direct_read(...)`). The pinned `moonc 0.10.22` rejects that form
  and requires promotion via `extend`.
- Every async release that the pinned compiler accepts (0.21.1 and later) changed
  the HTTP header type to `Map[@http.CaseInsensitiveString, String]`, which
  `0.6.0`'s `client.mbt` does not accept.

No published async version satisfies both the client and the compiler, so the
example carries this patched copy instead.

## Changes from upstream

- `client.mbt`: request headers are converted through `signed_headers`, using
  `@http.CaseInsensitiveString`.
- `types.mbt`: `} derive(...)` migrated to `#derive(...)`.
- `moon.pkg`: wasm-only; unused `moonbitlang/core/buffer` and
  `moonbitlang/core/string` imports dropped.
- Whitebox tests from upstream are not vendored.

The example imports this package as `daqing/on-upload-fn/vendor/s3`.
