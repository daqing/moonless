# moonless 项目记录（讨论稿）

> 本文档是项目讨论过程的记录，最终产出为 README.md / README.zh-CN.md。
> 随讨论推进持续更新。

## 背景

- MoonBit 开源编程语言黑客松项目，赛期一个月（2026-10 起）。
- 参赛者：张庆城（daqing）。
- 仓库：https://github.com/daqing/moonless
- 模块名：`daqing/moonless`，v0.1.0，MIT，`preferred_target = "native"`。

## 申报书要点（2026-10-02）

- 项目名称：基于 MoonBit 开发的 serverless 计算平台
- 项目方向：serverless 计算平台
- 是否为移植项目：否（原创设计）
- 核心功能范围：给开发者提供一个内网可部署的 serverless 计算平台
- 完全基于 MoonBit 开发

## 已确认的目标与定位

- **一句话定位**：一个内网部署的自托管（self-hosted）serverless 计算平台。
- 完全用 MoonBit 开发（平台本身即 MoonBit 的实力展示）。
- 面向内网/私有环境，信任模型宽松，不追求公有云级多租户硬隔离——
  因此函数走 native 执行是合理选项。

## 开发者体验（设想的使用流程）

1. 开发者按正常 MoonBit 项目结构开发一个 **native 程序**。
2. 通过 `moonless deploy` 把二进制发布到 moonless 平台。
3. 平台支持三种触发方式：
   - **HTTP**：请求打到函数对应的内网 URL；
   - **定时任务**：按 cron 配置调度；
   - **S3 事件**：向 moonless 自带的 S3 兼容存储桶存入文件时触发。
4. 函数按**约定的入参协议**拿到触发上下文（HTTP URL、定时任务配置、
   S3 文件路径）。
5. 函数的输出与副作用：
   - 写标准输出（stdout）；
   - 调用 moonless **内置的服务组件**：数据库、Redis 等。

## 技术决策记录

- **函数语言：MoonBit-first。** 面向 MoonBit 黑客松，函数即 MoonBit native
  程序。架构本身对语言是开放的（普通二进制 + 约定协议），多语言支持是
  二期及以后的规划，本期不做。
- **内置服务边界：**
  - **S3 兼容对象存储**：moonless 自研服务端（MoonBit 实现），同时是
    事件触发源；
  - **Redis / 数据库**：不自研、不托管，用户自备实例；moonless 通过
    配置得知服务地址，函数运行时以环境变量（如 `MOONLESS_REDIS_URL`）
    注入，函数用 MoonBit 生态 driver 直连。
- **部署模型：上传源码、平台构建。** `moonless deploy` 打包 `.mbt` +
  `moon.pkg` 上传；平台预装 moon 工具链，统一构建 Linux 二进制
  （跨平台问题消失，平台可解析依赖；构建需能访问 mooncakes registry）。
- **平台架构：微服务。** 每个服务一个独立进程（而非单二进制），
  服务间走内网 HTTP 通信。五个服务：
  - **gateway**：平台入口，函数 HTTP 路由 + 管理 API（deploy / list /
    logs），把请求转成 `MOONLESS_EVENT` 调度执行；
  - **builder**：接收上传的源码包，调 moon 工具链构建 Linux 二进制；
  - **runner**：执行面，fork 函数进程，收集 stdout / stderr 上报日志；
  - **scheduler**：cron 调度，到点触发函数；
  - **store**：S3 兼容对象存储服务端，对象写入时发事件触发函数。
- **部署编排：docker-compose**，仓库提供 `docker-compose.yml` 一键
  拉起全部服务（README Quick Start：`git clone && docker compose up`）。
- 执行模型：native 二进制，内网信任模型，无多租户硬隔离。
- 执行模型：native 二进制，内网信任模型，无多租户硬隔离。

## 函数运行约定（已拍板）

- **事件输入**：环境变量 `MOONLESS_EVENT`，值为 JSON，含 `source` 及
  各来源字段，如：
  - http：`{"source":"http","method":"POST","path":"...","body":"..."}`
  - cron：`{"source":"cron","schedule":"...","time":"..."}`
  - s3：`{"source":"s3","bucket":"...","key":"..."}`
- **stdout = 返回值**：HTTP 触发时作为响应体返回；其他触发时落入日志。
- **stderr = 日志**：平台收集，`moonless logs` 可查。
- **MVP 的 HTTP 响应固定 200**，stdout 原样返回；状态码 / headers
  控制留作后续增强。
- 函数即纯 Unix 程序：`MOONLESS_EVENT=... ./func`，本地手工设环境变量
  即可脱离平台调试。

## 依赖生态（用户提供的调研资料）

- **moonbitlang/async**（0.22.4）：官方异步库，封装 socket / http /
  websocket —— 微服务间 HTTP 通信与服务端实现的基础。
  <https://mooncakes.io/docs/moonbitlang/async@0.22.4>
- **hackwaly/redis**（0.1.1）：Redis 客户端。
  <https://mooncakes.io/docs/hackwaly/redis@0.1.1>
- **moonbitstack/moonmysql**（0.7.3）：MySQL 客户端。
  <https://mooncakes.io/docs/moonbitstack/moonmysql@0.7.3>
- **moonbit-community/postgres**（0.1.1）：Postgres 客户端。
  <https://mooncakes.io/docs/moonbit-community/postgres@0.1.1>

## S3 兼容存储选型（调研结论，2026-10）

**MinIO CE 不可用（已实质死亡）：**

- 2025-05：社区版破坏性更新，砍掉管理功能与管理控制台；
- 2025 年中：停发官方二进制与 Docker 镜像，社区版只剩源码；
- 2026-02：转入维护模式；
- 2026-04-25：社区仓库被 archive。

**候选评估：**

- **SeaweedFS**（推荐）：Apache-2.0，活跃维护，S3 API 完整（SigV4
  现成），小文件性能好。不支持 AWS 风格的 bucket notification API，
  但提供 **Filer 级 webhook 通知**（S3 操作经 Filer，可实时把上传/
  删除事件转发到 HTTP endpoint），可满足"存入文件触发函数"。
  compose 部署比单容器重（master/volume/filer/s3 多进程）。
- **Garage**：轻量（Rust、MPL），但官方文档无 bucket notification /
  webhook 支持的证据——事件触发硬需求不满足。
- **RustFS**：MinIO 的 Rust drop-in 替代，太新，成熟度存疑，赛期
  内风险高。
- Ceph RGW：企业级但过重，不适合内网一键部署场景。

**已拍板（2026-10-02）：集成 SeaweedFS。** store 不再自研；平台为
4 个 MoonBit 服务（gateway / builder / runner / scheduler）+ CLI，
存储与 Redis/DB 同样作为第三方服务被 docker-compose 编排。
S3 事件触发通过 SeaweedFS 的 Filer webhook 通知实现（moonless 侧
解析事件、提取 bucket/key、转成 `MOONLESS_EVENT` 触发函数）；
SigV4 等协议兼容由 SeaweedFS 提供，moonless 不再实现。

## 产品接口默认约定（写作 README 时采用的默认值，可调整）

- 函数 manifest：项目根放 `moonless.toml`（TOML 格式，用户指定，
  弃用最初的 JSON 方案），声明函数名与触发器。MoonBit 生态有现成
  TOML 解析库：moonbit-community/toml、hnlyxiaobing/toml
  （toml-test 98.8% 合规）。
  ```toml
  name = "hello"

  [triggers]
  http = { enabled = true }
  cron = "0 8 * * *"
  s3 = { bucket = "uploads", events = ["put"] }
  ```
  （触发器均为可选；http 默认路径 `/fn/<name>`。）
- HTTP 路由约定：`/fn/<function-name>`。
- 服务地址注入约定：函数运行时环境变量 `MOONLESS_REDIS_URL`、
  `MOONLESS_MYSQL_URL`、`MOONLESS_POSTGRES_URL`、`MOONLESS_S3_ENDPOINT`。

## MVP 边界（最终版，2026-10-02）

- **P0 最小闭环**：docker-compose 骨架 + CLI（`deploy` / `list` / `logs`）
  + gateway 管理 API + builder（moon 工具链构建 Linux 二进制）
  + runner（fork 函数进程、收集 stdout/stderr）+ HTTP 触发 + stdout 返回。
- **P1**：scheduler（cron 触发）+ 日志落盘与查询。
- **P2**：SeaweedFS 集成（compose 拉起 + Filer webhook 接入 + s3 触发）
  + Redis/DB 环境变量注入（工作量小，可提前完成）。
- **P3（stretch）**：函数超时与并发限制、版本与回滚、HTTP 状态码与
  headers 控制。

## 实现期默认值（开工即采用，可随时调整）

- **执行模型：fork-per-trigger。** 每次触发 fork 一个函数进程，跑完即退。
  与函数契约天然一致，MVP 首选；进程池/预热留待有性能需要时再议。
- **平台元数据存储：本地文件。** 函数注册表、触发器配置、日志先用
  gateway 本地文件（TOML/JSON），平台自身零外部依赖即可跑起来；
  后续需要再换 SQLite。
- **CLI 与 gateway 之间 MVP 不做鉴权**（内网信任模型），README 不
  承诺认证功能。

## 待澄清问题

无——讨论已收敛（2026-10-02），README 按上述记录撰写。
