# 多节点 runner

[English](multi_node_guide.md)

默认情况下整套服务只运行一个 runner，即 `docker-compose.yml` 里的 `runner`
服务。多节点 runner 可以在不共享 volume 的前提下增加执行节点：节点向 gateway
报到，gateway 按轮转顺序把每次运行分给某个节点，并把 wasm 构建推送给本地还没
有该构建的节点。

```text
runner 节点 ──POST /api/runners/register──► gateway    （每 30 秒）
gateway ──POST /modules（wasm + policy）──► 节点        （远程节点，每次运行前）
gateway ──POST /run（event、build_id、limits）──► 节点 ──► moonrun
```

三种触发最终都汇聚到同一处：HTTP（`/fn/:name`）、cron 和 S3 事件都会调用
`cmd/gateway/events.mbt` 中的 `dispatch_run`。因此调度选址只由 gateway 决定，
CLI 和 scheduler 都不需要知道节点列表。

## 注册

只有当两个环境变量都设置时，runner 才会加入节点池（`cmd/runner/main.mbt`）：

| 变量                         | 作用                                          |
| ---------------------------- | --------------------------------------------- |
| `MOONLESS_GATEWAY_URL`       | 注册目标，例如 `http://gateway:8080`          |
| `MOONLESS_RUNNER_PUBLIC_URL` | gateway 调用该节点时使用的地址                |

随后节点在循环中向 `/api/runners/register` 发送
`{"id": <public_url>, "url": <public_url>}`（`cmd/runner/register.mbt`）：单次
请求超时 5 秒，两次尝试之间休眠 30 秒。失败会记一条 warning，并在下一轮继续
重试。

节点 id 就是它的公网 URL，所以节点重启后只是用同一个 id 重新报到，不会产生
重复节点。gateway 的注册处理（`cmd/gateway/runners.mbt`）会去掉一个结尾的
`/`；id 已存在时就地更新 URL，否则追加新节点。注册表是内存里的
`RunnerRegistry`，由互斥锁保护；响应为 `{"ok": true, "runners": <数量>}`。

## 调度

`select_runner` 把 Compose 里的 runner 视为隐式的 0 号节点，它的地址来自
gateway 的 `MOONLESS_RUNNER_URL`（默认 `http://runner:8082`）。设已注册 N 个
节点：

```moonbit
let count = registry.nodes.length() + 1
let selected = registry.next % count
```

`next` 每次派发自增，所以流量在 N+1 个槽位间轮转：

- 槽位 0 永远是 `MOONLESS_RUNNER_URL`；
- 槽位 1..N 是按注册顺序排列的已注册节点。

由于 `id` 和 `url` 是同一个值，两个节点不能上报相同的 URL。计数器和节点表都
是进程内的，gateway 重启会同时清空两者；各节点会在 30 秒内重新注册而恢复。

## 模块下发

Compose 中的 runner、builder 和 gateway 共享 `moonless-data` volume，所以
builder 写出的构建已经在 runner 磁盘上。远程节点使用自己的 `MOONLESS_DATA`，
因此 gateway 会在调用前先上传：

1. `ensure_runner_module` 从 gateway 自己的 data root 读取
   `<data_root>/functions/<name>/<build_id>/func.wasm` 以及同目录的
   `policy.json`。
2. 把 wasm 做 base64 编码，把
   `ModuleUpload{name, build_id, wasm, policy}` POST 到 `<node>/modules`，
   超时 30 秒。
3. 节点校验路径片段，把 `func.wasm`（权限 755）和 `policy.json` 写到自己的
   `data_root/functions/<name>/<build_id>/`，返回 `{"ok": true}`
   （`cmd/runner/modules.mbt`）。

**每次**把运行分到远程节点前都会重新上传，没有“已上传”缓存。

之后 gateway 把 `RunRequest{name, event, build_id, limits}` POST 到
`<node>/run`，客户端超时 70 秒。runner 按请求中的 `build_id` 解析模块——文件
存在时以显式指定的构建为准，否则节点返回 `build unavailable on runner`——在
moonrun 下执行，并返回
`RunResult{stdout, stderr, exit_code, duration_ms, truncated}`。

任一步失败时，gateway 会合成一个 exit code 为 127 的结果，并在 stderr 中写入
标记：

| stderr                                        | 原因                                          |
| --------------------------------------------- | --------------------------------------------- |
| `moonless: failed to upload module to runner` | 读取模块、读取策略或调用 `/modules` 失败      |
| `moonless: runner unreachable`                | `/run` 超时或连接失败                         |
| `moonless: runner protocol error`             | 响应体无法解析为 `RunResult`                  |

## 每个节点的配置

节点之间并不等价：每个节点按自己的环境变量运行（`cmd/runner/execute.mbt`）。

| 变量                        | 默认值            | 作用                                 |
| --------------------------- | ----------------- | ------------------------------------ |
| `MOONLESS_DATA`             | `/var/lib/moonless` | 该节点上的模块、日志和注册表目录   |
| `MOONLESS_RUN_TIMEOUT_MS`   | `60000`           | 默认运行超时                         |
| `MOONLESS_MAX_CONCURRENCY`  | `8`               | 节点上的全局并发运行数               |
| `MOONLESS_OUTPUT_LIMIT`     | `10485760`        | 单路 stdout/stderr 上限              |
| `MOONLESS_LOG_MAX_BYTES`    | `16777216`        | 单个运行日志文件的大小上限           |
| `MOONLESS_LOG_KEEP`         | `14`              | 每个函数保留的日志文件数             |
| `MOONLESS_REDIS_URL`、`MOONLESS_MYSQL_URL`、`MOONLESS_POSTGRES_URL`、`MOONLESS_S3_ENDPOINT`、`AWS_ACCESS_KEY_ID`、`AWS_SECRET_ACCESS_KEY`、`AWS_REGION` | 未设置 | 注入该节点上每个函数进程 |

gateway 不会填充 `RunRequest.env`，所以数据服务地址和 AWS 凭据必须在每个需要
使用它们的节点上配置。

函数级 `[limits]` 由 gateway 解析并随每次运行下发，因此远程节点即使没有共享
注册表 volume 也会生效。但两者的作用域不同：

- `timeout_ms` 和 `concurrency` 由实际接收到运行的节点执行，所以
  `concurrency` 是**每节点**的，不是集群级的：三个节点、`concurrency = 2`
  时，最多可同时运行六个。
- `max_connection` 在 gateway 上执行，对 HTTP 触发仍是集群级的。

## 注意事项

- **注册表只在内存。** gateway 重启会清空节点表。在各节点重新注册（30 秒内）
  之前，只有默认 runner 会接到运行。
- **没有反注册，也没有健康检查。** 没有移除节点的接口，也不会探测死节点。死
  节点仍占轮转份额，轮到它的运行以 `runner unreachable`（exit 127）失败。要
  把它从列表中移除，只能重启 gateway。
- **日志保存在节点本地。** 每个 runner 把运行日志写在自己的 `MOONLESS_DATA`
  下，而 gateway 的日志 API 只读自己的 data root，因此远程节点上执行的运行不会
  出现在 `moonless logs` / `moonless runs` 里。请直接从节点收集日志，或把
  `MOONLESS_DATA` 指向共享存储。
- **删除只覆盖节点本地。** `moonless delete` 只删除 gateway data root 下的
  模块、构建和日志；此前上传到远程节点的副本仍会留在那里。
- **上传开销。** 因为没有上传缓存，每次远程运行都要重新传输 wasm。模块大到
  超过 30 秒上传超时，就会以上面的上传标记失败。
- **轮转不感知负载和本地性。** 慢节点或繁忙节点照样轮到；选址不考虑容量，也
  不考虑节点上是否已有该构建。
- **gateway 只等待 70 秒。** `/run` 的客户端超时是 70 秒，所以 `timeout_ms`
  超过该值的函数会表现为 `runner unreachable`。

## 安全

runner 的 `/run`、`/modules` 和 gateway 的 `/api/*` 都没有任何认证。能访问节点
的人可以推送模块并执行，能访问 gateway 的人可以注册一个假 runner 并收到上传的
wasm 构建。请把 runner 端口限制在可信网络内，不要公开 8082 或管理 API。由于
`/api/runners/register` 既无认证又只存在内存中，节点表只是调度提示，不能当作
安全边界。
