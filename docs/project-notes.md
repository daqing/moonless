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
- 函数经 wasm 沙箱获得默认隔离；网络能力可用但受宿主控制。

## 开发者体验（设想的使用流程）

1. 开发者按正常 MoonBit 项目结构开发一个程序（平台负责编译为
   wasm 模块）。
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

- **函数语言：MoonBit-first。** 面向 MoonBit 黑客松，函数即 MoonBit
  程序（编译为 wasm 模块，见"执行模型转向 wasm"节）。架构本身对
  语言开放，多语言支持是二期及以后的规划，本期不做。
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
- 执行模型：函数为 wasm 模块，moonrun 执行（沙箱隔离，网络经
  moonrun host 层可用）；平台组件为 native MoonBit 程序。
- 执行模型：函数为 wasm 模块，moonrun 执行（沙箱隔离，网络经
  moonrun host 层可用）；平台组件为 native MoonBit 程序。

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

## 依赖选型原则（2026-10-02，用户要求）

存在多个候选依赖时，优先选择 **moonbit-community** 组织的包（更可
依赖）；官方 `moonbitlang/*` 包仍然最优先。当前影响：

- **TOML 解析库定为 `moonbit-community/toml`**（备选
  `hnlyxiaobing/toml` 不再考虑）；
- cron 库的三个候选（`lijunjie860/moonbit_cron`、`cxh04/cron_mbt`、
  `001-Elsa/mooncron`）均非社区包，T7.1 选型时维持原候选；若届时
  出现 moonbit-community 的 cron 包，换用之。

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

## 平台工程约定（T1.4 定稿，2026-10-03）

compose、代码与本文三者保持一致；改动任何一项须同步其余两项。

- **端口分配**：gateway 8080、builder 8081、runner 8082、scheduler
  8083。仅 gateway 发布到宿主机（compose `8080:8080`），其余三个端口
  只在 compose 内部网络使用，服务间互调用服务名（如
  `http://builder:8081`）。
- **共享卷**：named volume `moonless-data` 挂载 `/var/lib/moonless`，
  builder、runner、gateway 三个服务共享（scheduler 无状态不挂）。
  子目录布局：`functions/`（函数 wasm 产物）、`builds/`（构建工作
  目录）、`logs/`（函数运行日志）、`registry/`（函数注册表）。子目录
  由各服务按需创建——不要烘焙进镜像：多个容器并发首次挂载同一个空
  named volume 时，Docker 的 volume copy-up 会与预建目录发生
  `mkdir: file exists` 竞态（T1.2 实测）。
- **MOONLESS_\* 环境变量清单**：
  - 平台侧：`MOONLESS_DATA`（共享卷路径，默认 `/var/lib/moonless`，
    Dockerfile 已设）；`MOONLESS_SERVER`（CLI 定位 gateway 地址）；
    `MOONLESS_BUILDER_URL` / `MOONLESS_RUNNER_URL`（gateway 寻址
    builder/runner，默认 `http://builder:8081` / `http://runner:8082`，
    compose 网络内服务名，本地裸跑时设为 `http://127.0.0.1:80xx`）。
  - 函数侧注入：`MOONLESS_EVENT`（触发事件 JSON）；数据服务地址
    `MOONLESS_REDIS_URL` / `MOONLESS_MYSQL_URL` /
    `MOONLESS_POSTGRES_URL` / `MOONLESS_S3_ENDPOINT`（P2 起注入，
    凭据随 S3 端点一并注入）。
  - 运行参数（runner，T4.3/T4.4/T4.8 已落地）：`MOONLESS_RUN_TIMEOUT_MS`
    （函数超时，默认 60000，超时杀死并返回 exitCode=124）、
    `MOONLESS_MAX_CONCURRENCY`（并发 fork 上限，默认 8，超出排队）、
    `MOONLESS_OUTPUT_LIMIT`（每流输出上限字节数，默认 10MB）。
- **函数输出上限**：stdout/stderr 每流默认 10MB，超出截断并在结果中
  标记 `truncated`（R4）；上限可由环境变量调整（T4.8）。
- **时区**：容器 `TZ`，默认 UTC（R8）；cron 语义按容器时区解释。
- **工具链锁定（R1 落地）**：镜像内 moon 工具链版本由 Dockerfile
  `ARG MOONBIT_VERSION=0.10.14+7d59c7ec9` 锁定（对应 moon CLI
  0.1.20260920、moonrun 同版，与开发机一致）。版本化下载 URL 用
  moonc 风格版本号（`https://cli.moonbitlang.com/binaries/<moonc 版
  本>/moonbit-<target>.tar.gz`；moon CLI 风格的 `0.1.20260920` 会
  403，`latest` 永远可达但不可复现）。
- **镜像构建实测要点（T1.2）**：Linux 上 native 链接需要系统 C 编
  译器（镜像装 `gcc` + `libc6-dev`）；"wasm 构建无需 C 工具链"只针对
  函数 wasm 构建。`moon update` 依赖系统 `git`（克隆 mooncakes 注册
  表索引），镜像必须带 git。平台二进制在镜像构建期用
  `moon build --target native --release` 预编译到 `/app/bin/`，四个
  服务共用同一镜像、仅 entrypoint 不同（R3）。
- **离线构建验证（T3.6，2026-10-03，R2）**：`docker network create
  --internal` 组无外网环境（容器内 curl mooncakes.io 返回 000），builder
  在其中完成一次完整 deploy（解包 → `moon build --target wasm` → 产物
  落盘）全部成功。依赖为零的函数天然不需要网络；带依赖函数的"依赖随包
  vendor（上传包内含 `.mooncakes/`）"由 T6.2 的 deploy 打包实现并在
  CLI 侧复测。

## T0.1 spike 发现记录（2026-10-02，R7 关闭依据）

代码：`spike/async_http/`。全部验证通过：路由（200/400/404）、JSON
解析与生成、**并发实证**（两个各 sleep 500ms 的并发请求总耗时
0.516s ≈ 单请求，非串行）。async http server 可作四个服务的基础。

- 入口即 `async fn main`；`@http.Server(@socket.Addr::parse("127.0.0.1:8899"))`
  + `run_forever((request, body, conn) => ...)` 三行起服务，handler
  lambda 自动适配 async 签名。
- **关键行为：handler 内 raise 不会崩服务，但客户端收到空响应**
  （curl exit 000）。gateway 的所有错误路径（JSON 解析、调 runner
  失败等）必须在 handler 内 `catch` 转 4xx/5xx，不能任其上抛。
- body 读取：`body.read_all() -> &Data`，`Data::text() -> String`；
  `moonbitlang/async/io` 无需显式 import。
- core/json 要点：类型名是 `Json`（prelude 可见；`@json.Json` 不存在）；
  `@json.parse(s) -> Json raise ParseError`；`Json::value()` 已
  deprecated，取字段用 `Object(obj)` 模式匹配 + `Map.get`；数字变体
  是 `Number(Double, repr~)`，匹配写 `Number(v, ..)`；JSON literal
  `{ "k": v }` 需显式 `: Json` 标注，否则推断为 `Map`；输出用
  `Json::stringify()`。
- 响应链式写法：`conn..send_response(..)..write_string(..).end_response()`，
  链尾必须 `.`（`..` 收尾触发 deprecated 警告）。
- `@async.sleep(n)` 单位毫秒。
- moon.pkg：`supported_targets = "+native"` 必需。
- 对 T2.3 的启示：路由封装照本 spike 的 `(meth, path)` match 模式
  实现即可，无需引入路由库。

## 执行模型转向 wasm（2026-10-02 定稿，方案 A）

**动机**（用户提出）：wasm 是 MoonBit 的一等公民编译目标与默认项目
模式，函数用 wasm 更契合 MoonBit 黑客松主题。

**定稿**：wasm 为**唯一**函数执行模型（方案 A，不做 native 双运行时）。

- builder 构建 `moon build --target wasm`（镜像无需 C 工具链）；
- runner 以外部子进程执行 `moonrun <func.wasm>`（moonrun 随 moon
  工具链分发，零新增依赖；内嵌 V8 JIT 执行 wasm）；
- 函数契约不变：`MOONLESS_EVENT` 环境变量 + stdout / stderr；
- **平台组件（gateway / builder / runner / scheduler / CLI）仍为
  native MoonBit 程序**——"平台 native、函数 wasm"。

**实证证据链**（spike/wasm_probe、spike/wasm_socket_probe，均在仓库）：

1. `moon build --target wasm` 产出 22KB 模块，`_start` 导出；
2. moonrun 直接执行，`MOONLESS_EVENT` 读取 + stdout 输出正常，契约
   原样成立；
3. 模块 imports = `wasi_snapshot_preview1.fd_write`（标准 WASI）+
   `__moonbit_fs_unstable.*`（MoonBit 私有 host ABI）→ 执行器被
   moonrun 锁定，标准 wasmtime/wasmer 不可用（R1 工具链锁版本恰好
   覆盖此风险）；
4. **wasm 下网络全通**：moonrun 内嵌完整 TCP/DNS/TLS（rustls）栈，
   实测 wasm 模块完成 TCP 连接-发送-回显往返；async/socket 的
   `socket.c` 仅是 native 路径，wasm 路径由 moonrun host 承载；
5. driver 佐证：moonbit-community/postgres 官方支持 classic wasm
   target（WasmGC 反而不支持 socket）；hackwaly/redis 唯一依赖即
   moonbitlang/async，同路径可用；
6. moonrun 另内嵌 SQLite host 支持，且有**实验性沙箱策略系统**
   （policy 规则含 network connect/bind、DNS、文件读写、进程）——
   函数级权限控制的路子已留好。

**Driver wasm 支持矩阵（2026-10-02 实测/包声明核实）**：

| driver | 包声明 | wasm |
| --- | --- | --- |
| moonbit-community/postgres | `client: native+wasm` | ✓ |
| moonbitstack/moonmysql | `client: +native+wasm`（README 注明 verified with moonrun） | ✓ |
| hackwaly/redis | `native+llvm` | ✗ |

hackwaly/redis 虽然只依赖 moonbitlang/async，但其 moon.pkg 自我声明
限制为 native+llvm，wasm 构建计划直接拒绝（本地实测）。候选替代
**Metalymph/valkey（2026-10-02 复核）：不可用**——声明层虽无 target
限制、底层依赖也正确（async/socket），但其模块描述仍为旧版
`moon.mod.json` 格式，当前工具链无法将包纳入构建图（对照：同作者
的 Metalymph/relay 用新版 moon.mod 即完全正常），所有符号不可见，
wasm 编译探针失败于符号解析。oboard/redis 大概率同类，未再逐一
验证。**oboard/redis（0.2.1，2026-10-02）：声明仅 `+native`，由我们
动手打通并转为内部维护**——最终集成方式（用户拍板，不做 PR）：
**vendored 进 moonless 模块**，正式位置 `vendor/redis/`（包路径
`daqing/moonless/vendor/redis`），随 moonless 仓库一起提交演进。
改动仅一行 `supported_targets = "+native+wasm"`（代码零 #cfg/零
FFI）；未带走上游测试（其硬编码 6379），自带 probe_wasm 作验证。
双 target（wasm 经 moonrun / native）对真实 Redis 的 SET/GET 往返
均通过、服务端独立确认写入。目录内 LICENSE 与 README 注明来源与
补丁。上游参照副本保留在 `upstream/moonbit-redis`（gitignore 排除），
未来如上游有更新可对照同步；如后续向上游提 PR 亦从此处整理。
hackwaly/redis 与 valkey 作为备选记录。

**连带影响**：R3（构建/运行环境 ABI 漂移）风险随之**消失**（wasm
平台无关）；"内网信任模型、无隔离"的旧定位升级为"wasm 沙箱默认
隔离、网络可用但受控"。

## 工程风险登记册（2026-10-02 逐条拍板）

- **R1 builder 镜像与工具链版本** — **已决**：自建镜像，构建时锁定
  moon 工具链版本（参考 moonbitlang/minimoonbit-public 的 Dockerfile；
  wasm 构建无需 C 工具链，镜像更轻）。`moonless.toml` 增加 `toolchain`
  字段约定函数
  期望的工具链版本，**最大支持版本即平台锁定版本**，超过则拒绝构建
  并报错。补充设计：`toolchain` 为可选字段，缺省视为兼容、直接用
  平台版本构建；README 写明支持的工具链版本。
- **R2 mooncakes 依赖在内网的可得性** — **已决**：依赖解析全部发生
  在开发机（开发者电脑可联网）。`moonless deploy` 打包时把开发机
  已解析的 `.mooncakes/` 依赖缓存一并上传（vendored），必要时打包前
  CLI 先在开发机执行依赖解析；builder 一律离线构建、不访问
  mooncakes.io。不提供在线拉取选项（YAGNI）。
- **R3 构建与运行环境 ABI 一致性** — **已失效（2026-10-02）**：函数
  转向 wasm 执行后平台无关，glibc ABI 漂移不复存在。builder 与
  runner 共用镜像仍保留为统一工具链的好实践。
- **R4 函数输出无上限的内存风险** — **已决**：stdout / stderr 各设
  上限，默认 10MB，超出截断并在结果中标记 `truncated`（HTTP 响应
  同理）；上限可环境变量调整。
- **R5 SeaweedFS webhook 交付语义** — **已决**：MVP 定调 best-effort，
  README 明确不做事件可靠性承诺（不承诺 exactly-once / at-least-once）；
  T9.4 的事件解析器用真实录制的事件 fixture 开发，不凭想象写。
- **R6 SeaweedFS 资源占用** — **已决**：采用 `weed server` 单进程模式
  （master / volume / filer / S3 gateway 一体），compose 中单容器；
  将来需要扩展再拆分部署。
- **R7 async http server 成熟度（架构地基）** — **已决**：全面开工前
  先做半天 spike（任务 T0.1）：用 `moonbitlang/async` 的 http server
  实现带路由、JSON body、并发请求的最小服务，验证地基。
- **R8 cron 时区** — **已决**：容器 `TZ` 环境变量控制，默认 UTC，
  scheduler 读取 `TZ`；文档写明。
- **R9 赛期内 moon 工具链 breaking change** — **已决**：接受风险，
  由 R1 的工具链版本锁定覆盖，不额外动作。

## 待澄清问题

无——讨论已收敛（2026-10-02），README 按上述记录撰写。
