# moonless

**moonless** 是一个自托管（self-hosted）、面向内网的 serverless 计算平台，
完全用 [MoonBit](https://www.moonbitlang.com) 开发。名字是一个合成词：
**Moon**Bit + server**less**。

> **当前状态：** MoonBit 黑客松参赛项目，开发中（2026 年 10 月）。
> 本 README 描述的是设计目标，功能按 [Roadmap](#roadmap) 的顺序逐步落地。
>
> [English README](README.mbt.md)

## 为什么做 moonless

你有一台内网机器，还有一堆值得以服务形式存在的小任务：一个渲染报表的
HTTP 接口、一个每晚定时执行的清理脚本、一个"桶里来了新文件就触发"的
处理钩子。你不想为每个任务单独看护一台服务，而公有云 FaaS 又够不着——
或者你根本不想用它。

moonless 让这台机器发挥价值：跑一次 `docker compose up`，整个内网就有了一个
函数平台。用 MoonBit 写函数，一条命令发布，通过 HTTP、定时任务或上传文件
来触发。

## 特性一览

- **MoonBit 优先的函数模型。** 函数是编译为 WebAssembly 模块的
  MoonBit 程序——MoonBit 的一等公民编译目标。没有专有 SDK、没有
  厂商运行时：`moon build --target wasm` 产出什么，平台就跑什么。
- **默认沙箱隔离。** 函数以 wasm 模块在 moonrun 下执行：内存隔离、
  没有对宿主的随意访问——同时经由运行时的 host 层保有完整的网络
  能力（TCP / TLS）。
- **三种触发方式。** HTTP 路由、cron 定时、S3 上传事件，全部在代码旁的
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
                          │    ▼              │ put 事件                  │
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
| SeaweedFS    | S3 兼容对象存储；对象上传时通知 moonless                                  |

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
http = { enabled = true }
```

### 4. 部署并调用

```bash
moonless deploy
curl "$MOONLESS_SERVER/fn/hello"
```

### 5. 查看日志

```bash
moonless logs hello
```

加上 `--follow` 可持续轮询，并在新日志到达时只输出新增记录。

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

## 触发器

所有触发器都是可选的，在 `moonless.toml` 中声明：

```toml
name = "resize-images"

[triggers]
http = { enabled = true }
cron = "0 8 * * *"
s3 = { bucket = "uploads", events = ["put"] }
```

- **HTTP** —— 函数挂在 `/fn/<name>` 路由上。
- **cron** —— 标准的五段式 cron 表达式；触发时调度配置会出现在事件里。
- **S3** —— 用任意 S3 客户端（`aws`、`mc`、`rclone`……）上传对象，
  SeaweedFS 通知 moonless，函数被触发，事件里带有 bucket 和 key。
  事件交付为尽力而为（best-effort）。

## 函数级限制

在 `moonless.toml` 中设置可选的超时与并发覆盖值：

```toml
[limits]
timeout_ms = 5000
concurrency = 2
```

两者都必须是正整数。超出的调用会排队；函数未覆盖时，沿用 runner 全局的
`MOONLESS_RUN_TIMEOUT_MS` 和 `MOONLESS_MAX_CONCURRENCY` 默认值。

## 版本与回滚

每次成功部署都会保留 wasm 产物，并把构建加入函数历史。回滚到前一个构建：

```bash
moonless rollback <name>
```

下一次调用会立即使用选中的产物。

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
- [ ] **P3 —— 加固：** 多节点 runner 与沙箱策略（Redis wasm 支持：
      补丁已验证，上游 PR 待合并）

后续想法：多语言函数（函数契约在设计上就是语言无关的）、函数版本化、
多节点 runner。

## 许可证

[MIT](LICENSE)
