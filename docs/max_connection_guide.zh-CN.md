# max_connection 准入限制

[English](max_connection_guide.md)

`[limits] max_connection` 限制 gateway 为单个函数同时接纳的 HTTP 客户端请求数。
超过上限的请求立即失败：不会进入 runner，函数也不会执行。

## 配置

```toml
[limits]
timeout_ms = 10000
concurrency = 2
max_connection = 2
```

三者都必须是正整数。`max_connection` 只作用于 HTTP 触发；cron 与 S3 派发不占用
名额。

## 执行路径

gateway 处理 `/fn/<name>` 时依次执行：

1. 查找函数的 registry 记录；
2. 检查 HTTP trigger 是否开启；
3. 按函数名尝试占用一个连接名额；
4. 占不到名额：立即返回 `429 Too Many Requests`，结束本次请求；
5. 占到名额：读取请求体、构造事件、调用 `dispatch_run`；
6. 请求结束（成功、错误、超时、客户端断开）后释放名额。

名额检查在 `dispatch_run` 之前完成，所以超限请求不会出现在 runner 的 `/run`，
不会执行函数，也不会产生 run log。

这里的“失败”指该 HTTP 请求以 429 结束，gateway 进程本身继续运行。响应体示例：

```text
moonless: function <name> exceeded max_connection=<n>
```

## 与 concurrency 的区别

- `concurrency`：runner 上同时执行的运行数上限。超出的运行在 runner 排队，之后
  仍会执行。
- `max_connection`：gateway 上同时接纳的 HTTP 请求数上限。超出的请求直接 429，
  不会排队，也不会执行。

两者的计数都包含正在执行和正在等待的请求：

- 一个请求只要被 gateway 接纳，就占用一个 `max_connection` 名额，直到它返回；
- 一个请求只要在 runner 等待执行，就占用一个 `concurrency` 名额。

因此：

- `max_connection > concurrency`：名额内多出来的请求会在 runner 排队；
- `max_connection <= concurrency`：执行槽满后，新请求基本会直接被 429，不再排队；
- 如果希望“执行槽满就拒绝”，把两者设为相同值。

## 计数范围

- 按函数名分别计数。
- 计数位于 gateway 进程内。单 gateway 部署下就是全局限制；多 gateway 部署时每个
  进程各有一份名额。
- 只统计 HTTP 触发。cron、S3 以及直接调用 runner `/run` 不经过这个计数器。
- 空闲的 keep-alive 连接不占名额；只有正在处理的 HTTP 请求计数。

## 验证

先确认超限请求的状态码和响应体：

```bash
# 期望 429，且响应体包含 max_connection
curl -i http://127.0.0.1:8080/fn/<name>
```

一次完整的并发验收：

1. 给函数加 `max_connection = 1`，重新 deploy；
2. 先发一个会阻塞一段时间的请求；
3. 在它返回前再发一个请求，应收到 429；
4. 第一个请求结束后再发，应恢复正常。

自动化测试 `cmd/gateway/connections_wbtest.mbt` 覆盖了这条路径：拒绝后 runner
调用次数保持不变，名额释放后新请求才进入 runner。

## 上线注意

- 修改后需要重建 gateway 镜像：`docker compose up -d --build gateway`。
- 修改 `moonless.toml` 后必须重新 `moonless deploy`，registry 里的 manifest 才会
  带上 `maxConnection`。
- 只重启 gateway 而不重新 deploy，旧 manifest 没有该字段，行为仍是原来的不限制。

## 实现位置

- `cmd/gateway/trigger.mbt`：准入检查与 429 响应。
- `cmd/gateway/connections.mbt`：按函数的计数器。
- `cmd/gateway/connections_wbtest.mbt`：拒绝、名额释放与 runner 未调用的回归测试。
- `src/shared/manifest.mbt`、`src/shared/protocol.mbt`：TOML 与 registry JSON 编解码。
