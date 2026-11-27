# 内置的 S3 客户端

[English](README.md)

这是 [`kaashyapan/s3@0.6.0`](https://mooncakes.io/docs/kaashyapan/s3@0.6.0) 的
补丁副本（Apache-2.0，见 `LICENSE`）。之所以内置，是因为已发布的模块无法用
moonless 固定的工具链构建：

- `0.6.0` 依赖 `moonbitlang/async@0.20.3`，后者的 wasm 源码仍把 trait 实现当普通
  方法调用（`self.to_string()`、`self.reader._direct_read(...)`）。固定的
  `moonc 0.10.22` 不再接受这种写法，要求通过 `extend` 显式提升。
- 固定编译器能接受的 async 版本（0.21.1 及以后）把 HTTP 头类型改成了
  `Map[@http.CaseInsensitiveString, String]`，而 `0.6.0` 的 `client.mbt` 不接受。

没有任何已发布的 async 版本能同时满足该客户端和编译器，所以示例改带这份补丁副本。

## 相对上游的改动

- `client.mbt`：请求头经 `signed_headers` 用 `@http.CaseInsensitiveString` 转换。
- `types.mbt`：`} derive(...)` 迁移为 `#derive(...)`。
- `moon.pkg`：仅支持 wasm；去掉未使用的 `moonbitlang/core/buffer` 与
  `moonbitlang/core/string` 导入。
- 不内置上游的 whitebox 测试。

示例以 `daqing/on-upload-fn/vendor/s3` 引入该包。
