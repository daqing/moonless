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

- **MoonBit 优先的函数模型。** 函数就是一个普通的 MoonBit native 程序。
  没有专有 SDK、没有厂商运行时——`moon build` 产出什么，平台就跑什么。
- **三种触发方式。** HTTP 路由、cron 定时、S3 上传事件，全部在代码旁的
  一个小 manifest 里声明。
- **Unix 风格的函数契约。** 触发上下文通过 `MOONLESS_EVENT` 环境变量传入；
  结果走 stdout，日志走 stderr。调试时平台完全可以让路。
- **部署源码而非二进制。** `moonless deploy` 上传 MoonBit 源码，平台负责
  构建 Linux 二进制——你的笔记本上永远不需要交叉编译。
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
   deploy / list / logs   │    │  ▲           │        （native 二进制）  │
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
| `builder`    | 用 moon 工具链把上传的源码构建为 Linux 二进制                             |
| `runner`     | 执行面：fork 函数进程，收集 stdout / stderr                               |
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
cd moonless
moon build cmd/moonless --target native
export MOONLESS_SERVER=http://localhost:8080
```

### 3. 写一个函数

函数就是一个带可执行包的标准 MoonBit 项目。假设
`cmd/main/main.mbt` 长这样：

```moonbit
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

MVP 简化：HTTP 响应固定返回 `200`，stdout 原样作为响应体；状态码与
headers 的控制在 Roadmap 中。

### 本地调试——平台可缺席

契约只是环境变量和标准流，所以你可以手工以平台的方式运行函数：

```bash
MOONLESS_EVENT='{"source":"http","method":"GET","path":"/fn/hello"}' \
  moon run cmd/main --target native
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

## 使用数据服务

把你的 Redis / MySQL / Postgres 地址告诉 moonless（配置项在
`docker-compose.yml` 里），每个函数运行时都会收到注入的环境变量：

```text
MOONLESS_REDIS_URL=redis://redis.internal:6379
MOONLESS_MYSQL_URL=mysql://user:pass@mysql.internal:3306/db
MOONLESS_POSTGRES_URL=postgres://user:pass@pg.internal:5432/db
MOONLESS_S3_ENDPOINT=http://seaweedfs:8333
```

用 MoonBit 生态的 driver 连接：

- Redis：[`hackwaly/redis`](https://mooncakes.io/docs/hackwaly/redis@0.1.1)
- MySQL：[`moonbitstack/moonmysql`](https://mooncakes.io/docs/moonbitstack/moonmysql@0.7.3)
- Postgres：[`moonbit-community/postgres`](https://mooncakes.io/docs/moonbit-community/postgres@0.1.1)

## Roadmap

- [ ] **P0 —— 最小闭环：** `deploy` / `list` / `logs` CLI、源码上传、
      平台构建、HTTP 触发与 stdout 响应
- [ ] **P1 —— 定时：** cron 调度器、日志收集
- [ ] **P2 —— 事件：** SeaweedFS 集成（S3 API + 上传事件触发）、
      数据服务地址注入
- [ ] **P3 —— 加固：** 超时与并发限制、版本与回滚、HTTP 状态码与
      headers 控制

后续想法：多语言函数（函数契约在设计上就是语言无关的）、函数版本化、
多节点 runner。

## 许可证

[MIT](LICENSE)
