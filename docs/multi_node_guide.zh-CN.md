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

## 快速上手：添加第二个节点

整套服务自带的 runner（0 号节点）无需任何配置。要新增节点：

1. 先启动整套服务，并确认 Compose 网络名。它是 `<项目名>_default`；本仓库
   （目录名 `moonless`）即 `moonless_default`：

   ```bash
   docker compose up -d
   docker network ls --format '{{.Name}}' | grep moonless
   ```

2. 在同一网络里启动该节点。上报地址**不要**用 `127.0.0.1`——gateway 是在自己的
   容器内部调用节点的，那里 `127.0.0.1` 指向 gateway 自己。用节点的容器名：

   ```bash
   docker run -d --name node-2 --network moonless_default \
     -e MOONLESS_GATEWAY_URL=http://gateway:8080 \
     -e MOONLESS_RUNNER_PUBLIC_URL=http://node-2:8082 \
     moonless /app/bin/runner
   ```

   远程节点不需要 `moonless-data` volume：gateway 会在每次运行前把构建上传给它。
   它的 `MOONLESS_DATA` 默认是该容器内的 `/var/lib/moonless`，如果希望节点本地的
   日志和已上传的构建在重启后保留，就挂一个 volume。这里的 `moonless` 镜像就是
   `docker compose build` 产出的那个。

3. 验证 gateway 能访问它，并确认它已注册：

   ```bash
   docker compose exec gateway wget -qO- http://node-2:8082/healthz   # -> ok
   docker compose logs gateway | grep 'registered runner'
   ```

4. 触发一个函数，观察由哪个节点执行：

   ```bash
   curl http://127.0.0.1:8080/fn/bot
   docker logs -f node-2
   ```

   选址是轮转的，所以连续调用会在节点之间交替；每个 runner 会为自己处理的运行
   记录 `node=<url> start|execute|finish …`。

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

## 网络可达性

注册和执行的方向是**相反的**，这正是"节点注册成功了，但 gateway 访问不到它"
的常见原因：

```text
runner ──POST /api/runners/register──► gateway   （runner → gateway）
gateway ──POST /modules、/run──────► runner      （gateway → runner）
```

runner 只要能访问 gateway 就能注册；gateway 的端口通常是发布出来的，所以这一段
没问题。但随后 gateway 会用节点上报的 `MOONLESS_RUNNER_PUBLIC_URL` 去调用
runner，这个地址必须能在 **gateway 容器内部**解析。若不能，被调度到该节点的
请求就会失败，报 `moonless: failed to upload module to runner: POST <url>/modules
failed: …`。

这里用 `127.0.0.1` / `localhost` 永远是错的：在 gateway 容器里它指向 gateway
自己，而不是宿主机或别的容器。请改用以下方式之一：

- **同一 Docker 网络（第二个容器时的推荐做法）。** 把 runner 接进 Compose 网络，
  用它自己的服务/容器名作为上报地址：

  ```bash
  docker run -d --name node-2 --network moonless_default \
    -e MOONLESS_GATEWAY_URL=http://gateway:8080 \
    -e MOONLESS_RUNNER_PUBLIC_URL=http://node-2:8082 \
    moonless /app/bin/runner
  ```

  `node-2` 之所以能从 `gateway` 解析，是因为两者都在 `moonless_default` 网络里
  （这是项目默认网络，Compose 项目名不同时请相应调整）。

- **runner 在宿主机上（不在 Docker 里）。** runner 监听
  `0.0.0.0:$MOONLESS_RUNNER_PORT`（默认 `8082`），容器要通过宿主机网关名访问它。
  与容器里的 runner 不同，宿主机上的 runner **必须**把
  `MOONLESS_DATA` 设成当前用户可写的目录，因为默认的 `/var/lib/moonless` 属于
  root，gateway 上传会失败并返回 `500 moonless: cannot store module at
  /var/lib/moonless/...: <权限错误>`：

  ```bash
  # 在宿主机上
  MOONLESS_DATA="$HOME/.moonless" \
  MOONLESS_GATEWAY_URL=http://127.0.0.1:8080 \
  MOONLESS_RUNNER_PUBLIC_URL=http://host.docker.internal:8082 \
    moon run -- cmd/runner
  ```

  `host.docker.internal` 在 Docker Desktop（macOS/Windows）可直接解析。在 Linux
  上给 gateway 服务加 `extra_hosts: ["host.docker.internal:host-gateway"]`，或
  改用网桥 IP（如 `172.17.0.1`）。如果 runner 日志里上传出现 500，请检查
  `MOONLESS_DATA` 目录是否存在，以及运行 runner 的用户是否可写。

  要在**同一台宿主机上跑多个 runner**，给每个分配各自的 `MOONLESS_RUNNER_PORT`、
  `MOONLESS_DATA` 和匹配的公网 URL——`MOONLESS_RUNNER_PUBLIC_URL` 里的端口必须
  等于监听端口（或能转发到它的端口）：

  ```bash
  # 节点 A
  MOONLESS_RUNNER_PORT=8082 MOONLESS_DATA="$HOME/.moonless/a" \
  MOONLESS_RUNNER_PUBLIC_URL=http://host.docker.internal:8082 \
    moon run -- cmd/runner

  # 节点 B
  MOONLESS_RUNNER_PORT=8083 MOONLESS_DATA="$HOME/.moonless/b" \
  MOONLESS_RUNNER_PUBLIC_URL=http://host.docker.internal:8083 \
    moon run -- cmd/runner
  ```

  数据目录必须分开：两个 runner 共用同一个 `MOONLESS_DATA` 会在同一批模块和日志
  文件上相互争抢。

- **公网 URL 与监听端口必须一致。** runner 绑定
  `0.0.0.0:$MOONLESS_RUNNER_PORT`（默认 `8082`）；`MOONLESS_RUNNER_PUBLIC_URL`
  必须指向能到达该监听器的主机和端口。

在依赖它之前，先在 gateway 容器里验证：

```bash
docker compose exec gateway sh -c \
  'wget -qO- http://node-2:8082/healthz || curl -fsS http://node-2:8082/healthz'
```

runner 对 `GET /healthz` 返回 `ok`。若这一步失败，说明地址不可达，后续的模块
上传会以同样方式失败。runner 启动日志会打印上报的地址
（`listening on 0.0.0.0:<端口> (advertising <url>)`），gateway 也会记录每次上传的
结果及其使用的节点 URL。

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

由于 `id` 和 `url` 是同一个值，两个节点不能上报相同的 URL，而且**修改**节点的
公网 URL 会注册一个**新**节点，而不是更新旧的。旧条目不会立刻消失：每次注册都会
刷新心跳，超过 90 秒（连续三轮 30 秒）没有重新注册的节点会在下一次选址前被清除，
所以改了地址或已经下线的 runner 留下的影子节点，会在一小段时间后不再接到流量。
计数器和节点表都是进程内的，gateway 重启会同时清空两者；各节点会在 30 秒内重新
注册而恢复。

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

| stderr | 原因 |
| --------------------------------------------- | --------------------------------------------- |
| `moonless: failed to upload module to runner: <原因>` | gateway 读取构建失败，或调用 `/modules` 失败（原因里写明路径或 URL） |
| `moonless: runner unreachable`                | `/run` 超时或连接失败                         |
| `moonless: runner protocol error`             | 响应体无法解析为 `RunResult`                  |

gateway 还会记录选中的节点和上传结果（`uploaded <fn> build=<id> to runner
<url>` / `module upload to <url> failed: <原因>`），因此失败信息会指明被选中的
节点。非 JSON 响应现在会带上 HTTP 状态码和一小段响应体
（`returned status 500 with a non-JSON body: internal error`），能看出该地址上
到底是谁在应答。常见原因是 gateway 无法访问已注册的节点 URL——例如在 gateway
所在网络命名空间里用 `127.0.0.1` 注册，它指向的是 gateway 自己而不是该节点。
另一个原因是修改 `MOONLESS_RUNNER_PUBLIC_URL` 后遗留的旧节点；它会在停止重新
注册 90 秒后被清除。

runner 也会记录自己这一侧的 gateway 交互，所以上传失败无需对照两份日志就能定位：

```text
[runner] INFO  node=http://node-2:8082 gateway upload name=resize build=b-1001 wasm=2841b policy=0b
[runner] INFO  node=http://node-2:8082 stored upload name=resize build=b-1001 wasm=2841b at /var/lib/moonless/functions/resize/b-1001
[runner] INFO  node=http://node-2:8082 gateway run request name=resize source=http build=b-1001
```

拒绝会上报为 WARN 并带原因（`rejected upload …`、`rejected /modules: <解析
错误>`）；存储失败（例如宿主机 runner 的 `MOONLESS_DATA` 不可写）会上报为 ERROR，
带目标路径和系统错误，并以 `moonless: cannot store module at <dir>: <错误>` 的
形式放在 500 响应体里返回（不再是路由层千篇一律的 `internal error`）。

## 每个节点的配置

节点之间并不等价：每个节点按自己的环境变量运行（`cmd/runner/execute.mbt`）。

| 变量                        | 默认值            | 作用                                 |
| --------------------------- | ----------------- | ------------------------------------ |
| `MOONLESS_RUNNER_PORT`      | `8082`            | runner 绑定的端口（宿主机 `0.0.0.0:<端口>`） |
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
- **过期节点会被清除。** 每次注册都会刷新节点的最后心跳。超过 90 秒（连续三轮
  30 秒）没有重新注册的节点会被清除，所以改了 `MOONLESS_RUNNER_PUBLIC_URL` 的
  节点——因为 id 就是 URL，它会以**新**节点的身份出现——留下的旧条目会在 TTL 后
  不再抢走流量。gateway 不会主动探测节点；runner 上的 `GET /healthz`（返回
  `ok`）只用于手动检查。
- **日志保存在节点本地。** 每个 runner 把运行日志写在自己的 `MOONLESS_DATA`
  下，而 gateway 的日志 API 只读自己的 data root，因此远程节点上执行的运行不会
  出现在 `moonless logs` / `moonless runs` 里。请直接从节点收集日志，或把
  `MOONLESS_DATA` 指向共享存储。每个 runner 还会为每次调用向 stderr 各写一条
  `start` 和一条 `finish`，并带上 `node=<public_url>` 标记（即它的
  `MOONLESS_RUNNER_PUBLIC_URL`，未设置时为 `local`），所以把各节点的输出汇到
  一起就能看出某个函数是在哪个节点执行的：

  ```text
  ... [runner] INFO node=http://node-2:8082 start name=resize source=http build=b-1001
  ... [runner] INFO node=http://node-2:8082 execute name=resize module=/var/lib/moonless/functions/resize/b-1001/func.wasm timeout=60000ms concurrency=8
  ... [runner] INFO node=http://node-2:8082 finish name=resize source=http exit=0 duration=42ms truncated=false
  ```
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
