# moonless

**moonless** 是一个自托管（self-hosted）、面向内网的 serverless 计算平台，
完全用 [MoonBit](https://www.moonbitlang.com) 开发。名字是一个合成词：
**Moon**Bit + server**less**。

> **当前状态：** MoonBit 黑客松参赛项目，开发中（2026 年 11 月）。
> 本 README 描述的是设计目标，功能按 [Roadmap](#roadmap) 的顺序逐步落地。
>
> [English README](README.mbt.md)

## 为什么做 moonless

你有一台内网机器，还有一堆值得以服务形式存在的小任务：一个渲染报表的
HTTP 接口、一个每晚定时执行的清理脚本、一个"桶里来了新文件就触发"的
处理钩子。你不想为每个任务单独看护一台服务，而公有云 FaaS 又够不着——
或者你根本不想用它。

moonless 让这台机器发挥价值：跑一次 `docker compose up`，整个内网就有了一个
函数平台。用 MoonBit 写函数，一条命令发布，通过 HTTP、定时任务或 S3 事件
来触发。

## 特性一览

- **MoonBit 优先的函数模型。** 函数是编译为 WebAssembly 模块的
  MoonBit 程序——MoonBit 的一等公民编译目标。没有专有 SDK、没有
  厂商运行时：`moon build --target wasm` 产出什么，平台就跑什么。
- **默认沙箱隔离。** 函数以 wasm 模块在 moonrun 下执行：内存隔离、
  没有对宿主的随意访问——同时经由运行时的 host 层保有完整的网络
  能力（TCP / TLS）。
- **三种触发方式。** HTTP 路由、cron 定时、S3 事件，全部在代码旁的
  一个小 manifest 里声明。
- **Unix 风格的函数契约。** 触发上下文通过 `MOONLESS_EVENT` 环境变量传入；
  结果走 stdout，日志走 stderr。调试时平台完全可以让路。
- **部署源码而非二进制。** `moonless deploy` 上传 MoonBit 源码及
  vendored 依赖缓存，平台负责构建 wasm 模块——服务器端完全离线。
  你的笔记本上永远不需要交叉编译。
- **平台服务全部用 MoonBit 编写。** gateway、builder、runner、scheduler
  都是构建在 [`moonbitlang/async`](https://mooncakes.io/docs/moonbitlang/async@0.22.4)
  之上的 MoonBit 程序。
- **内置 S3 兼容存储**，由 [SeaweedFS](https://github.com/seaweedfs/seaweedfs)
  提供：`aws`、`mc`、`rclone` 等标准工具开箱即用。
- **数据服务自带。** moonless 把你现有的 Redis / MySQL / Postgres 地址以
  环境变量形式注入函数，用 MoonBit driver 直连。

## 架构

```
                          ┌───────────────────────────────────────────────┐
                          │              docker compose                   │
                          │                                               │
   moonless CLI ─────────►│  gateway ─────► runner ─────► 你的函数        │
   deploy / list / logs   │    │  ▲           │      （wasm，经 moonrun）│
                          │    │  │           │                           │
                          │    ▼  │           ▼                           │
                          │  builder        scheduler                    │
                          │    │              ▲                           │
                          │    ▼              │ S3 事件                   │
                          │  SeaweedFS ───────┘  (S3 兼容存储)            │
                          │                                               │
                          │   你的 Redis / MySQL / Postgres（外部自备）   │
                          └───────────────────────────────────────────────┘
```

| 服务         | 职责                                                                      |
| ------------ | ------------------------------------------------------------------------- |
| `gateway`    | 平台入口：函数 HTTP 路由、管理 API、事件接收                              |
| `builder`    | 用 moon 工具链把上传的源码构建为 wasm 模块                  |
| `runner`     | 执行面：经 moonrun 运行 wasm 模块，收集 stdout / stderr      |
| `scheduler`  | 按 cron 配置调度触发函数                                                  |
| SeaweedFS    | S3 兼容对象存储；把 S3 请求上报给 moonless                                |

Redis、MySQL、Postgres 不在平台之内：你自己运行（或复用现有实例），
moonless 只负责把地址交给函数。

## 快速开始

### 1. 启动平台

在任何装了 Docker 的内网机器上：

```bash
git clone https://github.com/daqing/moonless.git
cd moonless
docker compose up -d
```

### 2. 安装 CLI

```bash
moon update
moon build cmd/moonless --target native
mkdir -p "$HOME/.local/bin"
cp "$PWD/_build/native/debug/build/cmd/moonless/moonless.exe" "$HOME/.local/bin/moonless"
export PATH="$HOME/.local/bin:$PATH"
export MOONLESS_SERVER=http://localhost:8080
```

### 3. 写一个函数

在仓库根目录创建一个独立的 MoonBit 项目：

```bash
moon new hello
cd hello
```

函数就是一个带可执行包的标准 MoonBit 项目。假设
`cmd/main/main.mbt` 长这样：

```moonbit nocheck
///|
fn main {
  match @env.get_env_var("MOONLESS_EVENT") {
    Some(event) => println("hello! triggered by: \{event}")
    None => println("hello!")
  }
}
```

并在 `cmd/main/moon.pkg` 里引入 env：

```text
import {
  "moonbitlang/core/env"
}

pkgtype(kind: "executable")
```

在 `moon.mod` 旁边加一个 `moonless.toml`，声明函数与触发器：

```toml
name = "hello"
# 可选：函数期望的 moon 工具链版本。
# 不得超过平台锁定的版本。
toolchain = "0.10.11"

[triggers]
http = true
```

### 4. 部署并调用

```bash
moonless deploy
moonless list
moonless show hello
curl "$MOONLESS_SERVER/fn/hello"
```

使用 `moonless list -q` 可省略表格首行 header。`moonless show <name>`
会打印已部署的 manifest、触发器、限制、当前构建和历史。

### 5. 查看日志

```bash
moonless logs hello
```

加上 `--follow` 可持续轮询，并在新日志到达时只输出新增记录。如果暂时没有日志，follow 模式会等待第一条记录，而不是直接退出。

## 函数运行契约

函数遵循朴素的 Unix 惯例：

| 通道                 | 含义                                                        |
| -------------------- | ----------------------------------------------------------- |
| `MOONLESS_EVENT` 环境变量 | 触发上下文，JSON 格式                                  |
| stdout               | 函数返回值：HTTP 触发时作为响应体返回，其他触发时归档到日志 |
| stderr               | 日志：平台收集，`moonless logs` 可查                        |

各触发来源的事件内容：

**http**
```json
{"source": "http", "method": "POST", "path": "/fn/hello", "query": "", "body": "..."}
```

**cron**
```json
{"source": "cron", "schedule": "0 8 * * *", "time": "2026-10-02T08:00:00Z"}
```

**s3**
```json
{"source": "s3", "event": "put", "bucket": "uploads", "key": "report.csv"}
```

### HTTP 响应控制

默认情况下，stdout 是响应体，状态码为 `200`。需要设置状态码或 headers 时，
在响应体之前写一行 JSON 控制行：

```text
{"status":201,"headers":{"Content-Type":"application/json","X-Request-Id":"abc"}}
{"created":true}
```

控制行必须包含 `status` 或 `headers`。没有合法控制行的输出保持原样。
`Content-Length`、`Transfer-Encoding` 和 `Connection` 由 gateway 管理，函数
不能覆盖。

### 本地调试——平台可缺席

契约只是环境变量和标准流，所以你可以手工以平台的方式运行函数：

```bash
MOONLESS_EVENT='{"source":"http","method":"GET","path":"/fn/hello"}' \
  moon run cmd/main --target wasm
```

## 其他语言——显式启用

事件环境变量与 stdout/stderr 契约天然与语言无关。如需部署已有的可执行文件，
而不是 MoonBit 源码，在 `moonless.toml` 中显式设置包内相对路径：

```toml
name = "native-worker"
binary = "func"

[triggers]
http = true
```

此模式不需要 `moon.mod`。可执行文件必须匹配 runner 的操作系统和架构。
**原生二进制会直接执行，不经过 wasm 沙箱**；只应对受信任的函数启用。

## 触发器

所有触发器都是可选的，在 `moonless.toml` 中声明：

```toml
name = "resize-images"

[triggers]
http = true
cron = "0 8 * * *"
s3 = { bucket = "uploads", methods = ["put"] }
```

- **HTTP** —— 函数挂在 `/fn/<name>` 路由上。
- **cron** —— 标准的五段式 cron 表达式；触发时调度配置会出现在事件里。
- **S3** —— 指定 bucket 和会触发函数的 method（`get`、`put`、`delete`）。
  SeaweedFS 的 S3 审计日志经 fluent-bit 转发后，每条成功的匹配
  请求都会触发函数，事件里带有 bucket 和 key。由于事件来自 S3 API 层，直接
  通过 filer 写入的文件不会触发函数。不支持 POST 上传：SeaweedFS 的审计
  记录不含对象 key。事件交付为尽力而为（best-effort）。

`http` 既可以写成 `true` / `false`，也可以写成显式的 table 形式
`http = { enabled = true }`。

函数只能通过其已部署 manifest 中声明的触发器调用；例如，未启用 `http` 时
`/fn/<name>` 会返回 `403`。

### 测试 S3 触发器

部署 `examples/on-upload`（manifest 把 `uploads` 桶的 `put` 请求绑定到该函数），
然后用任意 S3 客户端上传一个对象。SeaweedFS 提供标准 S3 API，`curl` 自己就能
完成 SigV4 签名——不需要安装 AWS CLI（要求 curl 7.75+）：

```bash
cd examples/on-upload
moonless deploy

S3=http://localhost:8333

# 200 = 创建成功，409 = 桶已存在。
curl -sS -o /dev/null -w 'bucket: %{http_code}\n' -X PUT \
  --aws-sigv4 "aws:amz:us-east-1:s3" --user "moonless:moonless-secret" \
  "$S3/uploads"

echo "hello" > report.txt
curl -fsS -T report.txt \
  --aws-sigv4 "aws:amz:us-east-1:s3" --user "moonless:moonless-secret" \
  "$S3/uploads/report.txt"

moonless logs on-upload --tail 5
```

日志里应出现 `on-upload received:` 和事件 JSON，其中包含
`"bucket":"uploads"` 以及上传的 key。用 AWS CLI 也可以：

```bash
AWS_ACCESS_KEY_ID=moonless AWS_SECRET_ACCESS_KEY=moonless-secret AWS_REGION=us-east-1 \
  aws --endpoint-url http://localhost:8333 s3 cp report.txt s3://uploads/report.txt
```

`mc` 不在 moonless 的安装范围内。需要先安装 MinIO 客户端，再按同样的方式
使用：

```bash
# macOS
brew install minio-mc

# Linux (x86_64；ARM 使用 linux-arm64)
curl -fsSL https://dl.min.io/aistor/mc/release/linux-amd64/mc -o mc
chmod +x mc && sudo mv mc /usr/local/bin/mc

mc --version

mc alias set moonless http://localhost:8333 moonless moonless-secret
mc cp report.txt moonless/uploads/report.txt
```

脚本化的端到端验证：`moon run scripts/e2e_s3.mbtx` 会用 `mc` 上传对象并等待
函数日志（先按上面安装 `mc`，或设置 `MC=/path/to/mc`）；
`moon run scripts/demo.mbtx` 则用 AWS CLI 走一遍 HTTP、cron 和 S3 三种触发。

不经过对象存储、只验证触发器匹配与分发时，可以直接向 gateway 的内部事件入口
投递一个合成事件：

```bash
curl -fsS -X POST "$MOONLESS_SERVER/api/events" \
  -H 'Content-Type: application/json' \
  -d '{"source":"s3","event":"put","bucket":"uploads","key":"report.csv"}'
```

响应会列出所有匹配的函数；返回 `[]` 表示 bucket 或事件名没有匹配到任何
触发器。在 payload 中加入 `"function":"on-upload"` 可只分发给指定函数。

### S3 method 触发演示

`examples/s3-methods` 把 `hello` 桶绑定到 `get`、`put`、`delete`。运行：

```bash
moon run scripts/demo_s3_methods.mbtx
```

如果 `mc` 不在 `PATH` 中，设置 `MC=/path/to/mc`。脚本会用 `mc` 对对象
执行 PUT、GET、DELETE，三者都是真实的 SeaweedFS 审计事件。

## 函数级限制

在 `moonless.toml` 中设置可选的超时与并发覆盖值：

```toml
[limits]
timeout_ms = 5000
concurrency = 2
```

两者都必须是正整数。超出的调用会排队；函数未覆盖时，沿用 runner 全局的
`MOONLESS_RUN_TIMEOUT_MS` 和 `MOONLESS_MAX_CONCURRENCY` 默认值。

## 沙箱策略

wasm 函数可在 `moonless.toml` 中指定包内的 moonrun 策略文件：

```toml
sandbox = "policy.json"
```

例如，以下策略只允许读取事件变量，其他宿主能力默认拒绝：

```json
{
  "env": { "from_host": ["MOONLESS_EVENT"] },
  "fs": { "read": [], "write": [] },
  "net": { "dns": [], "connect": [], "bind": [] },
  "process": { "spawn": false }
}
```

`net.connect` 控制出站连接，并允许所需的 hostname DNS 查询；`net.bind` 接受
IP 地址或 `*`。文件系统根路径使用宿主路径，相对路径从策略文件位置解析。
策略随每个构建保存并上传到远端 runner。原生 binary 函数不使用此机制。

moonrun 策略目前仍是实验功能，且不覆盖 WASI。特别注意，
`process.spawn: true` 会给子进程宿主的原有权限，而不是用其他策略段限制它。

## 版本与回滚

每次成功部署都会保留 wasm 产物，并把构建加入函数历史。回滚到前一个构建：

```bash
moonless rollback <name>
```

下一次调用会立即使用选中的产物。

## 删除函数

删除已部署的函数：

```bash
moonless delete <name>...
```

可以一次传入多个名字，因此清空整个注册表可以这样写：

```bash
moonless list -q | awk '{print $1}' | xargs moonless delete
```

这会注销每个函数的 HTTP、cron 和 S3 触发器，并删除它的构建产物、构建工作目录和
运行日志。其他函数及其数据不受影响。

## 多节点 runner

启动另一个具有可访问地址的 runner，并配置 gateway 地址；无需共享 volume：

```bash
docker run -d --network moonless_default \
  -e MOONLESS_GATEWAY_URL=http://gateway:8080 \
  -e MOONLESS_RUNNER_PUBLIC_URL=http://node-2:8082 \
  moonless /app/bin/runner
```

注册节点与默认 runner 一起参与轮询调度。gateway 会在每次远程调用前上传当前
wasm 构建；runner 每 30 秒续注册。注册表保存在 gateway 内存中，gateway 重启后
节点会在下一轮续注册时恢复。

## 使用数据服务

把你的 Redis / MySQL / Postgres 地址告诉 moonless（配置项在
`docker-compose.yml` 里），每个函数运行时都会收到注入的环境变量：

```text
MOONLESS_REDIS_URL=redis://redis.internal:6379
MOONLESS_MYSQL_URL=mysql://user:pass@mysql.internal:3306/db
MOONLESS_POSTGRES_URL=postgres://user:pass@pg.internal:5432/db
MOONLESS_S3_ENDPOINT=http://seaweedfs:8333
AWS_ACCESS_KEY_ID=moonless
AWS_SECRET_ACCESS_KEY=moonless-secret
AWS_REGION=us-east-1
```

设置对应的 Compose 输入并重建 runner，例如：

```bash
REDIS_URL=redis://redis.internal:6379 docker compose up -d runner
```

未设置或为空的数据服务地址不会注入。AWS 变量使用标准名称，便于 S3
客户端直接读取。上述值是来自 `deploy/seaweedfs/s3.json` 的本地开发凭据；
部署到其他环境时应同步更换。

用 MoonBit 生态的 driver 连接（两者均可在 wasm 函数中使用）：

- MySQL：[`moonbitstack/moonmysql`](https://mooncakes.io/docs/moonbitstack/moonmysql@0.7.3)
- Postgres：[`moonbit-community/postgres`](https://mooncakes.io/docs/moonbit-community/postgres@0.1.1)

> Redis 说明：[`oboard/redis`](https://mooncakes.io/docs/oboard/redis@0.2.1)
> 声明仅支持 native target，因此 moonless 在仓库内维护其 vendored
> 补丁版（`vendor/redis/`）——wasm 支持已放开，并经 moonrun 对真实
> Redis 端到端验证。

完整 Redis 示例见 `examples/redis-counter`。将 `REDIS_URL` 指向你的实例后，
运行 `moon run scripts/e2e_redis_counter.mbtx`，即可打包 vendored driver、
部署函数并验证连续两次计数递增。

## 引导式演示

安装 Docker、MoonBit 和 AWS CLI 后，运行：

```bash
moon run scripts/demo.mbtx
```

脚本会启动 Compose 栈、部署三个核心示例，通过 HTTP、cron 和 S3 实际触发，
并展示日志；同时检查整个流程不超过五分钟。

## Roadmap

- [x] **P0 —— 最小闭环：** `deploy` / `list` / `logs` CLI、源码上传、
      平台构建、HTTP 触发与 stdout 响应
- [x] **P1 —— 定时：** cron 调度器、日志收集
- [x] **P2 —— 事件：** SeaweedFS 集成（S3 API + 上传事件触发）、
      数据服务地址注入
- [x] **P3 —— 加固：** 沙箱策略（Redis wasm 支持：补丁已验证，上游 PR
      待合并）

## 许可证

[MIT](LICENSE)
