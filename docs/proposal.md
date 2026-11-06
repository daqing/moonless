# moonless 项目申报书

## 基本信息

- 项目名称：moonless —— 基于 MoonBit 的内网自托管 serverless 计算平台
- 参赛者：张庆城
- 联系方式：18654631132
- GitHub 仓库：https://github.com/daqing/moonless
- 项目方向：serverless 计算平台
- 是否为移植项目：否（架构与实现均为原创设计）

## 项目简介

moonless 是一个完全用 MoonBit 开发、面向内网部署的自托管
（self-hosted）serverless 计算平台。名字由来：**Moon**Bit +
server**less**。

在内网任意一台机器上 `docker compose up`，整个内网即拥有一个函数
平台：开发者用 MoonBit 编写函数，一条命令部署，通过 HTTP 路由、
cron 定时、S3 对象上传三种方式触发，并可直连内网既有的
MySQL / Postgres 数据库。

核心特色：**函数编译为 WebAssembly 模块（MoonBit 的一等公民编译
目标），经官方 moonrun 运行时执行**——默认沙箱隔离、部署单元仅
KB 级，同时保有完整的网络能力（TCP / TLS）。平台自身的四个微服务
与 CLI 也全部为 MoonBit 程序，构建于 `moonbitlang/async` 之上。

## 核心功能范围

1. **函数模型与契约**：函数即普通 MoonBit 程序；触发上下文经
   `MOONLESS_EVENT` 环境变量注入（JSON），stdout 为返回值、
   stderr 为日志；本地 `moon run` 即可完全脱离平台调试。
2. **三种触发器**：HTTP（`/fn/<name>` 路由）、cron（五段式
   表达式）、S3 事件（对象上传触发）。
3. **部署模型**：`moonless deploy` 上传源码与 vendored 依赖，
   平台完全离线构建 wasm 模块；manifest（`moonless.toml`）声明
   函数名、触发器与工具链版本（不得超过平台锁定版本）。
4. **平台服务（全部为 MoonBit 微服务）**：
   - gateway：平台入口，函数 HTTP 路由、管理 API、事件接收；
   - builder：调用 moon 工具链构建 wasm 模块；
   - runner：经 moonrun 子进程执行函数，捕获输出与日志；
   - scheduler：cron 调度；
   - docker-compose 一键编排全部服务。
5. **存储与数据服务**：集成 SeaweedFS 提供 S3 兼容对象存储与
   上传事件通知（`aws` / `mc` / `rclone` 等标准客户端直接可用）；
   MySQL / Postgres 由用户自备，函数以 MoonBit driver 直连
   （两个 driver 均官方支持 wasm target）、地址经环境变量注入；
   Redis 采用 `oboard/redis`（其 wasm 支持由本项目的上游补丁
   打通并经真实 Redis 往返验证，补丁将回馈上游）。

## 技术方案要点

- 执行模型：函数 = wasm 模块（`moon build --target wasm`），
  moonrun 执行，沙箱默认隔离、网络经 host 层可用；
- 平台：native MoonBit 微服务，基于 `moonbitlang/async`
  （http / socket / process）；
- 工具链版本锁定：镜像锁定 + manifest `toolchain` 字段校验，
  杜绝"本地能编译、平台构建失败"；
- 资源防护：函数输出上限（默认 10MB 截断）、执行超时、并发上限；
- 事件交付为尽力而为（best-effort），文档如实声明。

## 技术验证进展（关键路径已完成 spike 实证）

1. **async http server**：路由、JSON 处理、并发全部验证通过
  （两个各 sleep 500ms 的并发请求总耗时 0.516s，证明确为并发）；
2. **wasm 函数契约**：`moon build --target wasm` 产物经 moonrun
   执行，`MOONLESS_EVENT` 环境变量与 stdout 输出实测通过，契约成立；
3. **wasm 网络能力**：wasm 模块经 moonrun 完成真实 TCP
   连接-收发往返；
4. **数据库 driver wasm 支持核实与打通**：`moonbit-community/postgres`
   与 `moonbitstack/moonmysql` 均官方声明支持 wasm target
   （moonmysql 作者注明已用 moonrun 验证）；Redis driver
   （`oboard/redis`）原仅声明 native，经本项目一行补丁放开后，
   wasm 与 native 双 target 对真实 Redis 的 SET/GET 往返验证
   通过，补丁将作为 PR 回馈上游。

验证代码保留于仓库 `spike/` 目录，全部证据可复现。

## 里程碑计划

- **P0**：部署 → 平台构建 → HTTP 触发的最小闭环
  （CLI `deploy` / `list` / `logs`）；
- **P1**：cron 调度、日志收集与查询；
- **P2**：SeaweedFS 集成（S3 API + 上传事件触发）、
  数据服务地址注入；
- **P3**：超时与并发限制、版本与回滚、HTTP 状态码控制、
  基于 moonrun 实验性沙箱策略的函数级权限控制。

## 与 MoonBit 生态的结合

- 平台核心代码 100% MoonBit——展示 MoonBit 构建工业级服务端
  系统的能力；
- 函数以 wasm（MoonBit 一等公民目标）为执行格式，深度契合
  语言的核心方向；
- 集成 MoonBit 生态包：`moonbitlang/async`、
  `moonbit-community/toml`、`moonbit-community/postgres`、
  `moonbitstack/moonmysql`（均支持 wasm target）。

## 移植或参考说明

非移植项目。第三方基础设施（SeaweedFS、用户自备数据库）作为
独立服务经 docker-compose 编排集成，不修改其代码；moonless 的
平台代码、函数契约、调度与构建管线均为原创设计。
