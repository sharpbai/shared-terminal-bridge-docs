# STB-RDC：ChatGPT 共享终端适配层 v0.1 及验收260922

## 背景

此前 Shared Terminal Bridge（STB）主要围绕 Codex 与真人共用 tmux 的交互式运维设计。2026-09-22 验证 Remote Desktop Commander（RDC）后，确认 ChatGPT 可以直接访问 SharpbaiPro.local 的本机 shell，并可读取、写入用户正在使用的同一个 tmux session。
因此不再为 ChatGPT 重写完整 Bridge，而是新增一个很薄的 RDC Adapter，继续复用既有 STB 的 HumanEventLayer、Execution Lease、Job tracking、Context Policy 和审计能力。

## 当前架构

```text
ChatGPT
  ↓
Remote Desktop Commander
  ↓
stb-rdc（薄 Adapter）
  ↓ Unix socket / local API
Shared Terminal Bridge 0.14.0
  ├─ HumanEventLayer
  ├─ Execution Lease
  ├─ Job tracking
  ├─ Context Policy
  └─ Audit / History
  ↓
tmux verify33
  ↑
Human / iTerm2

```

核心原则：RDC 负责“ChatGPT 如何到达本机”；STB 负责“Human 与 AI 如何安全共享同一个 Terminal”。

## 项目位置

- 原 STB：`/Users/sharpbai/Documents/ChatGPT/IT网管/shared-terminal-bridge`
- RDC Adapter：`/Users/sharpbai/Documents/ChatGPT/IT网管/shared-terminal-bridge-rdc`
- Adapter 为独立 Git repository，旧 STB 项目未修改。

## v0.1 能力

当前 `stb-rdc` 提供：

```bash
./stb-rdc status
./stb-rdc context SESSION --lines 80
./stb-rdc lease SESSION
./stb-rdc send SESSION GENERATION 'command'
./stb-rdc job JOB_ID
./stb-rdc wait JOB_ID --seconds 60
./stb-rdc interrupt JOB_ID

```

输出统一采用 JSON，便于 ChatGPT 通过 RDC 稳定解析。
Adapter 不直接调用 tmux，也不重新实现 HumanEventLayer 或 lease。AI 正式写入必须经过 STB，并携带有效 generation。

## 2026-09-22 实机验收

使用真实日常 session `verify33` 验证，当前连接 local-33。
已通过：

- RDC → Adapter → STB daemon。
- Adapter 读取 `verify33` context。
- 显式获取 Execution Lease。
- Adapter 经 STB `terminal_submit` 向共享 pane 提交命令。
- 正常命令被 Job tracking 识别为 `COMPLETED`。
- RDC blocking wait 可阻塞等待 STB job 状态变化。
- 真人在 iTerm2 按 `Ctrl+C` 后，无需再给 ChatGPT 发消息，HumanEventLayer 即可唤醒 blocking wait。
- Job 权威状态变为 `INTERRUPTED_BY_HUMAN`。
- Execution Lease 自动变为 `REVOKED`。
- STB 返回 `recommended_action = STOP_CURRENT_TURN`。
- ChatGPT 故意使用旧 generation 再次写入时，本地 STB 返回 `EXECUTION_LEASE_INVALID`，命令没有进入 Terminal。
这证明 Human Override 不依赖模型“自觉停止”，而是由本地 STB 强制执行。

## Human Override 链路

```text
AI command
  ↓
lease generation=N
  ↓
STB → tmux
  ↓
Human Ctrl+C
  ↓
tmux client root key binding
  ↓
HUMAN_INTERRUPT
  ↓
job = INTERRUPTED_BY_HUMAN
lease N = REVOKED
  ↓
blocking wait 被唤醒
  ↓
ChatGPT 收到 STOP_CURRENT_TURN

若 AI 继续使用 generation=N：
  ↓
EXECUTION_LEASE_INVALID
  ↓
本地拒绝执行

```

## v0.1 验收中的修复

初版 Adapter 调用 `terminal_submit` 时使用了 `command` 参数；STB API 实际参数为 `text`。实机验收时发现后已修正，并重新完成 submit、job、Human Override 和 stale generation 验证。

## Git 状态

项目已初始化独立 Git repository，分支为 `main`。
当前基线提交：

```text
4a27c26 Initial RDC adapter v0.1

```

项目包含：

- `stb-rdc`
- `README.md`
- `CHANGELOG.md`
- `VALIDATION-v0.1.md`
- `.gitignore`
当前 v0.1 可视为稳定基线。

## 当前判断

RDC 已经解决远程连接、认证、本机 shell 与 ChatGPT 工具接入，因此原本 Shared Terminal Bridge 中“远程 Bridge”部分无需在 ChatGPT 路线上重复建设。
后续保持两个项目边界：

- `shared-terminal-bridge`：稳定核心，负责 Terminal/Event/Lease/Context/Safety。
- `shared-terminal-bridge-rdc`：ChatGPT + RDC 的薄适配层。

## 后续方向

v0.2 优先不扩张底层功能，而是改善 ChatGPT 使用体验：

- 精简 `context` 输出，降低上下文占用。
- 提供更适合 ChatGPT 的状态摘要。
- 为 Adapter 增加小型自动回归测试。
- 保持正式 AI 写入统一经过 Adapter → STB，不直接使用 RDC 的 `tmux send-keys`。
- 继续把 Human-primary / AI-sidecar 作为核心交互原则。
