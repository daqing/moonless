# 来自 oboard/moonbit-redis 的 vendored 版本

[oboard/moonbit-redis](https://github.com/oboard/moonbit-redis)（MIT，见 LICENSE）
的 vendored 副本，由 moonless 在仓库内维护。

本地改动：

- `moon.pkg` 把 `supported_targets` 放开为 `+native+wasm`（上游只声明了
  native）。已通过 moonrun 对真实 Redis 在两种 target 上验证 —— 见
  `probe_wasm/`。
- `connect_with_url` 支持用
  `redis://[[username]:[password]@]host[:port][/db]` 形式的 URL 建立连接
  （上游只提供 host/port 形式的 `connect`）。

上游测试未一并 vendored（它们需要 localhost:6379 上的 Redis）。
