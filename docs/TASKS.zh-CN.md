# moonless — 任务分解

一份带编号的任务清单，用于在闲余时间逐步完成 moonless 的开发，内容
派生自 [README](../README.zh-CN.md) 与 [project-notes.md](project-notes.md)
中的设计决策。

约定：

- 任务按里程碑分组：第 0–6 章构成 **P0**（最小闭环），7–8 章为
  **P1**，9–10 章为 **P2**，第 11 章做整体验收，第 12 章为 **P3**
  扩展项。
- 同一章内按顺序执行；跨章遵循 *依赖于* 的引用。
- 每个任务都有 *完成标准* 作为验收检查，通过后再勾选复选框。
- 除非特别说明，每个任务收尾时运行 `moon info && moon fmt`，并保证
  `moon test` 全绿。

## 0. 前置验证（P0）

- [x] **T0.1 — async http server spike。** 半天，先于一切任务（R7）：
  用 `moonbitlang/async` 的 http server 实现带路径路由、JSON body、
  并发请求的最小服务；记录 API 的坑。
  *完成标准：* spike 正确处理两个并发的 JSON 请求；发现记入
  `project-notes.md`。

## 1. 项目脚手架（P0）

- [x] **T1.1 — 仓库布局。** 建立五个可执行包 `cmd/gateway`、
  `cmd/builder`、`cmd/runner`、`cmd/scheduler`、`cmd/moonless`（各为
  一个 `println("hello from <name>")` 的 main），以及跨服务共享类型
  的库包 `src/shared`。移除脚手架 `cmd/main`。
  *完成标准：* 五个入口都能通过 `moon build --target native`，
  且 `moon test` 全绿。
- [x] **T1.2 — Compose 与镜像。** 编写 `docker-compose.yml`（gateway、
  builder、runner、scheduler）和单个共享镜像 `Dockerfile`：内含
  版本锁定的 moon 工具链（R1；wasm 构建无需 C 工具链——moonrun 随
  工具链分发）；builder 与 runner 运行同一镜像、以不同入口区分。
  声明 builder、runner、gateway 共享的 named volume
  `/var/lib/moonless`。
  *完成标准：* `docker compose up` 拉起四个服务容器（此阶段 hello
  world 行为即可）。
- [ ] **T1.3 — 依赖引入。** 在 `moon.mod` 加入 `moonbit-community/toml`
  （`moonbitlang/async` 已在 T0.1 加入；依赖选型原则：存在多个候选时
  优先 moonbit-community 的包）；cron 库随 T7.1 引入。
  *完成标准：* 新依赖引入后构建通过，`pkg.generated.mbti` 的差异
  符合预期。
- [ ] **T1.4 — 平台约定文档。** 在同目录 `project-notes.md` 记录：
  端口分配（如 gateway 8080、builder 8081、runner 8082、scheduler
  8083）、共享 volume 布局
  （`/var/lib/moonless/{functions,builds,logs,registry}/`）以及
  `MOONLESS_*` 环境变量清单、函数输出上限（每流默认 10MB，R4）与
  时区约定（容器 `TZ`，默认 UTC，R8）。
  *完成标准：* compose 文件、代码与文档三者一致。

## 2. 公共基础 — `src/shared`（P0）

- [ ] **T2.1 — 事件类型。** 按 README 中确切的 JSON 形状，把触发
  上下文建模为含 http / cron / s3 三个变体的类型，并实现编解码。
  *完成标准：* 单元测试覆盖三种变量的往返（round-trip）。
- [ ] **T2.2 — Manifest 解析。** 解码并校验 `moonless.toml`：`name`
  必填、触发器全部可选、`cron` 为五段式表达式、`s3.events` 取值
  属于 `{put, delete}`、可选的 `toolchain` 字段不得超过平台锁定的
  版本（R1）。
  *完成标准：* 单元测试覆盖合法与非法样例。
- [ ] **T2.3 — HTTP server 辅助。** 基于 `moonbitlang/async` 的轻量
  路由封装：路径匹配、方法分发、JSON body 读取、响应辅助函数。
  *完成标准：* 至少被一个服务的冒烟测试使用。
- [ ] **T2.4 — HTTP client 辅助。** 带超时配置的 GET/POST（JSON
  body）。
  *完成标准：* 通过本地测试服务器的单元测试。
- [ ] **T2.5 — 日志辅助。** 结构化 stderr 日志：服务名、时间戳、
  级别、消息。
  *完成标准：* 五个服务全部接入。
- [ ] **T2.6 — 服务间协议类型。** `DeployRequest`、`BuildResult`、
  `RunRequest`、`RunResult` 与注册表记录的 struct 定义 + JSON 编解码。
  *完成标准：* 往返单元测试通过。

## 3. Builder 服务（P0）

- [ ] **T3.1 — 构建 API。** `POST /build` 接收 MoonBit 项目的
  tar.gz 包和函数名；缺少 `moon.mod` 或 `moonless.toml` 的包拒绝。
  *完成标准：* 手工构造的 tar.gz 请求能正确返回成功/失败。
- [ ] **T3.2 — 安全解包。** 解压到隔离工作目录
  `/var/lib/moonless/builds/<build-id>/`，做路径穿越防护
  （zip-slip）。
  *完成标准：* 含 `../` 条目的恶意压缩包被拒绝。
- [ ] **T3.3 — 调用工具链。** 在工作目录经 `@moonbitlang/async/process`
  （`run` + `collect_output`）运行 `moon build --target wasm`，捕获
  输出，定位产出的 `.wasm` 模块。
  *完成标准：* fixture 项目构建成功并返回模块路径。
- [ ] **T3.4 — 产物存储。** 把模块复制到
  `/var/lib/moonless/functions/<name>/<build-id>/func.wasm`，旁边写入
  构建元数据。
  *完成标准：* builder 容器重启后产物仍在（named volume）。
- [ ] **T3.5 — 失败回报。** `BuildResult` 中返回构建 stderr 尾部，
  供 CLI 展示失败原因。
  *完成标准：* 坏 fixture 返回可读的错误信息。
- [ ] **T3.6 — 离线构建验证。** 依赖以 vendored 形式随上传包到达
  （R2）；确认 builder 构建全程完全不需要网络。
  *完成标准：* 禁用 builder 容器的网络访问后，deploy 依然成功。
- [ ] **T3.7 — Builder 测试。** 集成测试：一个好 fixture、一个坏
  fixture。
  *完成标准：* 两条路径都被 `moon test` 或 `scripts/` 下脚本覆盖。

## 4. Runner 服务（P0）

- [ ] **T4.1 — 执行 API。** `POST /run` 接收 `{name, event, env?}` →
  设置 `MOONLESS_EVENT` 执行已存储的 wasm 模块，返回
  `{stdout, stderr, exitCode, duration}`。
  *完成标准：* curl 调用已部署 fixture 能取回捕获的输出。
- [ ] **T4.2 — 进程执行。** 经 `@moonbitlang/async/process` 起
  moonrun 子进程执行：spawn `moonrun <module.wasm>`，用 `extra_env`
  组装环境变量（`MOONLESS_EVENT` 加注入的服务地址），用
  `collect_output` 捕获 stdout/stderr。
  *完成标准：* echo/sleep/exit-code 用例行为全部正确。
- [ ] **T4.3 — 超时。** 默认 60 秒后杀死函数，返回超时结果。
  *完成标准：* `sleep` fixture 被杀死且结果如实上报。
- [ ] **T4.4 — 并发上限。** 用简单信号量限制同时 fork 数（默认 8，
  可用环境变量配置），超出的请求排队。
  *完成标准：* 突发测试表现为排队执行而非失败。
- [ ] **T4.5 — 模块定位。** 把 `<name>` 解析到
  `/var/lib/moonless/functions/` 下最新的 `.wasm`。
  *完成标准：* 重新部署 fixture 后，下一次执行用的是新模块。
- [ ] **T4.6 — 日志采集。** 每次执行的事件与 stderr 追加到
  `/var/lib/moonless/logs/<name>/<日期>.log`，供 gateway 查询。
  *完成标准：* 文件按预期布局生成。
- [ ] **T4.7 — Runner 测试。** 覆盖：普通 stdout、stderr 噪音、非零
  退出码、大输出、超时。
  *完成标准：* 全部用例通过。
- [ ] **T4.8 — 输出上限。** 执行每流输出上限（默认 10MB，可用环境
  变量调整）：超出截断并在结果中标记 `truncated`（R4）；HTTP 响应
  路径遵循同一上限。
  *完成标准：* 无限回显的 fixture 被截断，runner 内存无增长。

## 5. Gateway 服务（P0）

- [ ] **T5.1 — 管理 API。** `POST /api/deploy`（tar.gz，转发给
  builder 后登记）、`GET /api/functions`、
  `GET /api/functions/<name>`、
  `GET /api/functions/<name>/logs?tail=N`。
  *完成标准：* 用 curl 走通 deploy → list → logs 完整循环。
- [ ] **T5.2 — 注册表。** 函数注册表存为
  `/var/lib/moonless/registry/` 下的本地文件，原子写入（临时文件 +
  rename）；记录包含 manifest 和当前 build id。
  *完成标准：* 并发 deploy 不会产生损坏的注册表文件。
- [ ] **T5.3 — HTTP 触发。** 路由 `/fn/<name>`（任意方法）→ 组装
  http 事件 JSON → 调用 runner → stdout 作为响应体返回，状态码 200
  （缓冲式；流式不在 MVP 范围）。
  *完成标准：* `curl $MOONLESS_SERVER/fn/hello` 返回函数 stdout。
- [ ] **T5.4 — 内部事件入口。** `POST /api/events` 接收任意事件
  来源；与注册表中的触发器匹配并派发给 runner。
  *完成标准：* 合成的 s3 事件能触发绑定的函数。
- [ ] **T5.5 — Deploy 编排。** 串联 上传 → 构建 → 登记，把构建失败
  连同原因传回调用方。
  *完成标准：* 坏 deploy 返回错误，好 deploy 可被调用。
- [ ] **T5.6 — Gateway 测试。** 集成测试：部署 fixture、HTTP 触发、
  日志获取。
  *完成标准：* 脚本化的端到端流程在 compose 栈上通过。

## 6. moonless CLI（P0）

- [ ] **T6.1 — CLI 骨架。** 子命令分发（`deploy`、`list`、`logs`），
  `MOONLESS_SERVER` 环境变量 + `--server` 覆盖参数。
  *完成标准：* 无参数运行 `moonless` 打印用法说明。
- [ ] **T6.2 — `deploy`。** 校验当前目录是含 `moonless.toml` 的
  MoonBit 项目；必要时先在本地解析依赖，然后把源码**连同** vendored
  的 `.mooncakes/` 缓存打包 tar.gz（排除 `_build/`、点文件），使
  builder 永不需要网络（R2）；上传；展示构建结果。
  *完成标准：* 从仓库部署 hello 示例成功。
- [ ] **T6.3 — `list`。** 表格输出已部署函数、触发器及最近构建
  状态。
  *完成标准：* 输出与注册表状态一致。
- [ ] **T6.4 — `logs`。** 拉取尾部日志（默认 50 行）；`--follow`
  流式延后到 T12.4。
  *完成标准：* HTTP 触发函数后，其 stderr 出现在日志中。
- [ ] **T6.5 — 错误体验。** 对以下情形给出友好提示：服务器不可达、
  不是 MoonBit 项目、缺 `moonless.toml`、函数不存在。
  *完成标准：* 每种情形都打印可操作的提示而非堆栈。
- [ ] **T6.6 — 冒烟脚本。** 在 `scripts/` 下编写跑通 P0 全流程的
  脚本：deploy → curl → logs。
  *完成标准：* 脚本在全新的 compose 栈上通过。

## 7. Scheduler（P1）

- [ ] **T7.1 — Cron 库。** 从 `lijunjie860/moonbit_cron`、
  `cxh04/cron_mbt`、`001-Elsa/mooncron` 中选型集成（或论证自写五段
  式解析器的理由）。三者均非 moonbit-community 包；若任务启动前出现
  社区包，按 project-notes 中的依赖选型原则优先换用。
  *完成标准：* 下次触发时间的计算有单元测试。
- [ ] **T7.2 — 注册表同步。** 每 30 秒向 gateway 拉取含 cron 触发器
  的函数，维护内存调度表。
  *完成标准：* 部署 cron 函数后一个同步周期内被拾取。
- [ ] **T7.3 — 派发循环。** 到达触发时间时组装 cron 事件并 POST 到
  gateway 的 `/api/events`。
  *完成标准：* `* * * * *` 的 fixture 在一分钟内触发。
- [ ] **T7.4 — 漏跑策略。** 记录并实现"迟到的直接跳过"（停机后不
  补跑）。
  *完成标准：* 短周期测试验证行为符合定义。
- [ ] **T7.5 — Scheduler 测试。** 覆盖解析、下次触发时间、派发路径
  （尽量用假时钟）。
  *完成标准：* 测试套件全绿。

## 8. 日志收集深化（P1）

- [ ] **T8.1 — 轮转。** 按天（或大小上限）轮转日志文件，保留最近
  N 个文件。
  *完成标准：* 合成写入按配置触发轮转。
- [ ] **T8.2 — 查询增强。** gateway API 支持按触发来源和时间窗口
  过滤日志；`moonless logs` 暴露过滤参数。
  *完成标准：* `--source` 与 `--since` 参数可用。
- [ ] **T8.3 — 运行记录。** 每次调用一条记录（函数、来源、时长、
  退出码），经 `GET /api/functions/<name>/runs` 查询；
  `moonless runs <name>` 展示。
  *完成标准：* 最近 N 次运行被正确列出。

## 9. SeaweedFS 集成（P2）

- [ ] **T9.1 — Compose 集成。** 以 `weed server` 单进程模式（master /
  volume / filer / S3 gateway 单容器，R6）在 compose 中加入
  SeaweedFS，配置持久化 volume 和静态 S3 凭据。
  *完成标准：* S3 gateway 在 compose 网络内应答。
- [ ] **T9.2 — S3 冒烟测试。** 用 `aws` CLI（或 `mc`）配置 endpoint
  和凭据：建桶、上传、下载。
  *完成标准：* 宿主机经映射端口操作成功；文档化确切命令。
- [ ] **T9.3 — Filer webhook。** 配置 filer 的通知 webhook，把事件
  POST 到 gateway 的 `/api/events`。
  *完成标准：* 一次上传产生一条到达 gateway 的事件（有日志即可）。
- [ ] **T9.4 — 事件适配器。** 解析 SeaweedFS filer 事件 JSON，映射
  为我们的 s3 事件（`bucket`、`key`），处理 SeaweedFS 的
  `/buckets/<bucket>/...` 路径约定；忽略非 S3 路径。
  *完成标准：* 基于录制事件 fixture 的单元测试。
- [ ] **T9.5 — 触发器匹配。** 将 s3 事件与 `moonless.toml` 的 s3
  触发器（bucket + events）匹配并派发。
  *完成标准：* 上传到已绑定桶触发函数，其他桶不触发。
- [ ] **T9.6 — 端到端。** `mc cp` 上传文件 → 绑定函数的日志出现含
  正确 bucket/key 的 s3 事件。
  *完成标准：* 脚本化并通过。
- [ ] **T9.7 — S3 endpoint 注入。** 向函数暴露
  `MOONLESS_S3_ENDPOINT`（及凭据）；对照 README 数据服务一节验证。
  *完成标准：* 函数能通过 S3 客户端列出触发它的桶。

## 10. 数据服务注入（P2）

- [ ] **T10.1 — Compose 配置项。** compose 中加入 `REDIS_URL`、
  `MYSQL_URL`、`POSTGRES_URL` 条目（默认注释掉，指向用户自备实例）。
  *完成标准：* 设置后能传递到 runner。
- [ ] **T10.2 — Runner 注入。** fork 函数时按配置值设置
  `MOONLESS_REDIS_URL` / `MOONLESS_MYSQL_URL` /
  `MOONLESS_POSTGRES_URL`。
  *完成标准：* 函数读回任一变量并回显。
- [ ] **T10.3 — 示例函数。** 用 `vendor/redis/` 下的 vendored 补丁版
  driver 实现一个 Redis 计数器示例，部署后经 HTTP 触发。
  *完成标准：* 连续 curl 使计数递增。
- [ ] **T10.4 — 文档核对。** 按运行中的系统逐条走查 README 数据服务
  一节。
  *完成标准：* 每个文档中的环境变量和 driver 链接都准确。

## 11. 端到端与演示（最终验收）

- [ ] **T11.1 — 示例项目。** 仓库内置 `examples/hello`、
  `examples/nightly-cleanup`（cron）、`examples/on-upload`（s3）。
  *完成标准：* 每个示例都能经 `moonless deploy` 干净部署。
- [ ] **T11.2 — Quick-start 走查。** 在全新机器/VM 上逐字执行 README
  快速开始。
  *完成标准：* 每条命令照文运行成功；不顺利的地方回头修 README。
- [ ] **T11.3 — README 同步。** 更新两份 README 的 Roadmap 勾选以
  反映真实进度；中文版保持同步。
  *完成标准：* 两份文件与交付状态一致。
- [ ] **T11.4 — 演示脚本。** 面向评委的演示流程：起栈、部署、三种
  方式触发、展示日志。
  *完成标准：* 彩排一遍不超过五分钟。

## 12. 扩展项（P3）

- [ ] **T12.1 — 函数级限制。** `moonless.toml` 中的超时与并发配置，
  由 runner 执行。
- [ ] **T12.2 — 版本与回滚。** 每个函数保留构建历史；
  `moonless rollback <name>` 切换生效构建。
- [ ] **T12.3 — HTTP 响应控制。** 函数设置状态码与 headers 的协议
  （如 stdout 首行输出 JSON header），替代固定 200。
- [ ] **T12.4 — `logs --follow`。** 日志流式输出到终端。
- [ ] **T12.5 — 多节点 runner。** runner 向 gateway 注册、跨节点部署
  函数。
- [ ] **T12.6 — 多语言函数。** 说明契约天然语言无关；显式 opt-in
  接受非 MoonBit 二进制。
- [ ] **T12.7 — CI。** GitHub Actions 在 push 时运行 `moon test` 与
  `moon fmt --check`。
- [ ] **T12.8 — 沙箱策略。** 探索 moonrun 的实验性沙箱策略
  （network connect/bind、DNS、文件访问规则）作为函数级权限控制
  的实现机制。
