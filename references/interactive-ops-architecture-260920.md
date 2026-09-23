# 人与 Codex 共用终端的交互式运维架构260920

这篇文档用于定义一套“人主导、Codex 旁观并按需协作”的交互式终端方案。核心不是重新开发 AI Terminal，而是保留 iTerm2 作为人的主操作界面，让 tmux 提供持久 Shell 与历史缓冲，让 Codex 能读取同一份终端上下文；只有在明确授权时，Codex 才能向 Shell 输入命令。

# 核心目标

- **人是主操作者。** 日常 SSH、查看日志、执行命令、编辑文件都由我直接在 iTerm2 中完成。
- **不复制 Terminal 输出。** 当我说“看一下刚才的输出”“为什么失败”“接下来怎么处理”时，Codex 应主动读取当前终端上下文。
- **窗口不需要集成。** iTerm2 与 Codex App/CLI 可以是两个独立窗口，由 macOS 自己并排布局。
- **Shell 必须持久化。** 即使 iTerm2 窗口关闭或重新连接，正在进行的 SSH/运维会话和历史仍然存在。
- **Codex 默认只读。** 它可以观察、分析和提出建议；只有我明确要求“你执行”“直接处理”等情况下，才向终端输入命令。
- **Ctrl+C 是人工中止信号。** 一旦我主动按下 Ctrl+C，Codex 必须知道这件事，并立即停止当前自动推进链路，不得把中断当作普通命令失败后继续尝试。

# 系统形态

iTerm2 是人的 UI；tmux Control Mode 是底层持久 Session；PTY/Shell/SSH 是实际执行环境；Terminal Bridge 负责把 tmux 的状态、历史和人工事件暴露给 Codex。Codex App 或 CLI 可以独立放在另一个窗口。
整个系统的事实中心不是 Codex，而是 **tmux 中的真实 Shell session**。iTerm2 负责给人提供自然的终端体验；Codex 通过一个很薄的 bridge 读取 tmux pane，而不是要求我把输出复制给它。

# 终端层：iTerm2 + tmux

优先考虑 iTerm2 的 tmux Control Mode：

```bash
tmux -CC new-session -s ops

```

重新连接：

```bash
tmux -CC attach -t ops

```

目标是让 tmux 在底层负责 session 持久化，同时尽可能保留 iTerm2 原生窗口、Tab、Split、选择、复制和滚动体验。
tmux history 建议放大：

```javascript
set -g history-limit 100000

```

这样终端输出有两种用途：

- 我通过 iTerm2 自然滚动和搜索历史。
- Codex 通过 tmux 读取同一个 pane 的历史上下文。
例如：

```bash
tmux capture-pane -p -t <pane-id> -S -3000

```

# Codex 的交互模型

Codex 不拥有 Shell，它只是 Shell 的协作者。
正常模式：

```text
我操作 Shell
→ tmux 保存输入输出
→ Codex 按需读取
→ Codex 分析并回复
→ 我决定下一步

```

授权执行模式：

```text
我明确要求 Codex 执行
→ Codex 读取当前 pane 与状态
→ Terminal Bridge 写入命令
→ 命令在同一个 Shell 中运行
→ 输出回到同一个 tmux pane
→ Codex 读取结果
→ 根据结果继续，但始终受人工中止信号约束

```

因此不需要出现“人的 Terminal”和“Codex Terminal”两套状态。双方面对的是同一个实际 session。

# Terminal Bridge

Bridge 应保持非常薄，不负责做复杂 Agent 推理。它主要提供几个原子能力：

- `read_terminal`：读取当前 pane 最近 N 行或完整 history。
- `get_active_pane`：确定我当前正在操作哪个 tmux pane。
- `get_terminal_state`：获取 pane、当前命令、host、cwd 等可获得状态。
- `send_command`：仅在明确授权后向当前 pane 输入命令。
- `send_keys`：处理 Enter、方向键等必要按键。
- `interrupt`：必要时由 Codex 请求 Ctrl+C，但与“用户主动 Ctrl+C”必须区分。
- `terminal_events`：把用户输入、中断、pane 切换、命令结束等事件提供给 Codex。
第一阶段甚至可以只实现 `read_terminal + get_active_pane + terminal_events`，完全不给 Codex 写权限。

# Ctrl+C：最高优先级的人工中止语义

这是整个方案里需要单独设计的部分。
单纯让 Codex 事后通过 `capture-pane` 看输出并不够，因为 Ctrl+C 经常只表现为程序退出、`^C` 或新的 shell prompt，Codex 未必能可靠判断这是**用户主动夺回控制权**。
因此 Bridge 应把 Ctrl+C 作为一个明确事件，而不是只把它当作一个字符。
理想事件类似：

```json
{
  "type": "user_interrupt",
  "pane": "%3",
  "key": "C-c",
  "source": "human",
  "timestamp": "..."
}

```

Codex 收到该事件后的规则必须是：

1. 立即终止当前自动执行计划。
2. 不自动重试刚才被中断的命令。
3. 不因为看到新的 shell prompt 就执行计划中的下一条命令。
4. 不自行换一种方法继续完成原任务。
5. 保留当前上下文和已经取得的结果。
6. 将控制权交还给我，等待我的下一条自然语言指令。
7. 只有我明确要求继续后，才能恢复自动执行。
也就是说：

```text
Ctrl+C ≠ command failed
Ctrl+C ≠ retry
Ctrl+C ≠ continue next step

Ctrl+C = HUMAN OVERRIDE / STOP

```

这个语义的优先级应高于 Codex 当前任务、计划和自动执行状态。

# 为什么不能只依赖 tmux history 判断 Ctrl+C

history 更适合回答“刚才发生了什么”，但不适合作为可靠的控制通道。
例如：

```text
journalctl -f ...
^C
root@server:~#

```

Codex 可以推测发生了 Ctrl+C，但不能百分之百知道：

- 是我主动按的；
- 是 Codex 自己发的；
- 是程序自身退出；
- 是连接或 PTY 发生异常。
因此长期方案应有两个通道：

```text
数据通道：tmux pane history
控制通道：Terminal events

```

history 给 Codex“眼睛”，events 告诉 Codex“人刚刚做了什么”。

# 人与 Codex 的权限关系

默认状态建议定义为：

```text
READ      = 默认允许
SUGGEST   = 默认允许
WRITE     = 需要当前任务授权
CONTINUE  = 未发生人工中止时按授权范围执行
INTERRUPT = Ctrl+C 后立即撤销 CONTINUE

```

一次授权可以允许 Codex 连续执行几步，但任何时候我按 Ctrl+C，都相当于即时撤销这次连续执行权。

# 上下文分层

## 即时上下文

来自当前 tmux pane：最近执行的命令、stdout/stderr、当前 prompt、当前 SSH 主机、最近几千行输出，以及用户 Ctrl+C 等终端事件。

## 任务上下文

来自当前 Codex session：当前正在排查什么、已经做过哪些判断、为什么执行上一条命令、下一步原计划是什么、哪些动作已经获得授权。

## 长期上下文

来自本地 Knowledge / `AGENTS.md` 等：服务器角色、网络拓扑、常用路径、运维约定、风险边界、常见命令和历史经验。
三层结合后，Terminal history 不需要承担长期知识库的角色。

# 第一阶段 MVP

不开发 Web Terminal，也不重做 UI。

```text
iTerm2
  ↓
tmux -CC
  ↓
persistent shell / SSH
  ↓
Terminal Bridge
  ↓
Codex App 或 Codex CLI

```

MVP 重点验证：

- iTerm2 + tmux Control Mode 的日常操作体验是否足够自然。
- tmux history 是否能稳定覆盖日常运维需要。
- Codex 能否自动找到“我当前正在操作的 pane”。
- Codex 是否能在不复制输出的情况下理解“刚才”“这个报错”“现在什么状态”。
- 能否可靠捕获**用户主动 Ctrl+C**，并让 Codex 立即停止推进。
- 长时间 SSH、日志输出、vim 等交互场景是否存在状态识别问题。
第一版建议保持 Codex **只读 Terminal**。Ctrl+C 事件机制验证可靠后，再加入写入能力。

# 第二阶段

加入受控执行：

- `send_command`
- 当前任务授权状态
- 用户中断后的授权撤销
- 命令完成检测
- 当前 host / cwd / foreground process 状态
- 多 pane 识别
这时交互会逐渐变成：

```text
我：看看这个为什么不对
Codex：读取当前 Terminal → 分析

我：你直接查吧
Codex：在同一 Shell 执行检查命令 → 读取结果 → 继续

我：Ctrl+C
系统：立即终止 Codex 自动推进

我：这个方向不对，换一个思路
Codex：基于已有上下文重新规划

```

# 最终形态

最终目标不是“AI Terminal”，而是：

> **我的 Terminal + 一个拥有终端视觉、上下文记忆和受控操作能力的 Codex。**
人的操作路径不需要因为 AI 存在而改变。AI 是旁观者、分析者和按需协作者；tmux 是双方共享的执行现场；Terminal Bridge 只解决“看见、识别事件、受控输入”三个问题。
这套结构最大的价值是把 AI 接入现有工作流，而不是要求现有工作流迁移到 AI 的界面里。

# 参考项目拆解后的架构更新

目前参考项目的定位已经可以分开看：

- **agent-mux**：重点借鉴 Human + Agent 共用 tmux 的协作、安全状态、pause kill-switch 与 audit 思路，不准备直接采用它较重的多 Agent 编排形态。
- **tmux-bridge-mcp**：更适合作为 Bridge 实现骨架。它证明 Codex ↔ MCP ↔ tmux 的读取、输入、pane 枚举等基础能力可以保持非常薄，并提供了“先 read 再 act”的 Read Guard 思路。
- **Wave Terminal**：后续重点参考“哪些 Terminal 信息应该进入 AI context”、durable session、SSH 状态和 approval 的处理方式。
- **Warp**：后续重点参考 Command Block / Terminal Event Model，即如何把连续字符流提升成 command、output、exit、prompt 等结构化事件。
- **xterm.js / ttyd**：作为更底层的 PTY 输入输出与键盘事件路径参考，尤其用于研究 Human Ctrl+C 的可靠捕获位置。

## Bridge v0.1 的能力分层

当前倾向把 Bridge 收敛为四组能力：

- **Observation**
	- `terminal_list`
	- `terminal_read`
	- `terminal_state`

- **Action**
	- `terminal_type`
	- `terminal_key`
	- `terminal_interrupt`

- **Human Events**
	- `terminal_events`

- **Control**
	- `acquire_execution`
	- `release_execution`
	- `execution_status`
第一阶段仍然优先实现 Observation + Human Events，Action 可以暂缓。

## Read Guard、Pane ACL 与 Execution Lease

参考 tmux-bridge-mcp 的 Read Guard，但准备进一步强化为：

```text
READ → PLAN → AUTHORIZATION → ACT → READ

```

而不是简单的 READ → ACT。
同时，Codex 的执行授权不能覆盖整个 tmux server，而应绑定到具体 pane。未来同时打开北京、广州、US9929、ESXi 和本地 Shell 时，某一次“你直接查吧”的授权只允许 Codex 操作当前明确授权的 pane。
授权执行采用 **Execution Lease** 概念：

```text
acquire_execution
→ pane = %3
→ generation = 42
→ ACTIVE

```

如果用户主动 Ctrl+C：

```text
generation 42
→ REVOKED

```

之后 Bridge 层直接拒绝该 lease 下的 `terminal_type`、`terminal_key` 等写操作。这样 Human Override 不依赖模型是否正确理解 prompt，而是由 Bridge 强制执行。

## Audit Log

Codex 对 Terminal 的主动操作应保留审计记录，例如：

```text
10:31:22 READ       pane=%3
10:31:25 TYPE       systemctl status x-ui
10:31:26 KEY        Enter
10:31:28 READ       pane=%3
10:31:35 HUMAN_KEY  Ctrl+C
10:31:35 OVERRIDE   execution lease revoked

```

后续可以用于故障回看、安全审计，以及帮助 AI 判断刚才哪些动作来自人、哪些来自 Agent。

# 后续设计议题：AI Context

**优先级：后排。当前先记录，不阻塞 MVP。**
长期不能简单地把 tmux 最近几万行全部塞进 Codex context。需要设计一个 Terminal Context Policy，决定“什么信息应该进入 AI context”。
初步考虑至少区分：

- 当前 pane 的最近命令与输出。
- 当前 foreground command 的完整输出或关键窗口。
- 当前 host、cwd、shell、SSH 目标等环境状态。
- 最近的人类输入事件，尤其 Ctrl+C、pane 切换和手动输入。
- 最近一次 Codex 主动执行的命令及其结果。
- 与当前任务直接相关的较早 Command Block。
- Codex session 中的任务目标、判断过程和执行授权状态。
- 来自 `AGENTS.md` / Knowledge 的长期机器与运维背景。
不建议默认进入 context 的内容包括：

- 与当前任务无关的巨大 scrollback。
- 高频重复日志。
- ANSI/绘制字符等纯显示噪声。
- 已经结构化总结且不再需要原文的历史输出。
- 其他未授权 pane 的内容。
长期目标是从“固定抓最近 N 行”逐渐演进到“当前状态 + 最近 Command Blocks + 相关历史检索”。

# 后续设计议题：Command Block / Terminal Event Model

**优先级：后排。当前先记录，不阻塞 Human Event Layer 与 MVP。**
tmux 的 `capture-pane` 本质上提供的是字符流快照。长期希望借鉴 Warp 的思路，把 Terminal 行为结构化成 Command Block。
一个理想 Command Block 可以包含：

```json
{
  "command": "systemctl restart x-ui",
  "source": "human",
  "host": "tx-bj-vps-0001",
  "cwd": "/home/duobeiyun",
  "started_at": "...",
  "finished_at": "...",
  "exit_code": 1,
  "interrupted": false
}

```

对应输出单独关联：

```text
CommandStarted
→ OutputChunk / OutputSummary
→ CommandFinished

```

Terminal Event 则可以进一步包括：

- `human_input`
- `human_interrupt`
- `agent_input`
- `command_started`
- `command_finished`
- `prompt_ready`
- `pane_selected`
- `ssh_host_changed`
- `cwd_changed`
这样 Codex 最终面对的就不再只是“屏幕上的一堆字符”，而是：

```text
Terminal State
+ Command Blocks
+ Event Stream
+ 必要的 Raw Output

```

这会显著改善 AI 对命令边界、执行结果、用户行为和历史上下文的理解。
不过这部分当前明确排在后面。**现阶段优先解决 Human Event Layer，尤其是如何在 iTerm2 + tmux -CC 下可靠识别人主动按下 Ctrl+C，并与 Agent 发送的 Ctrl+C 区分。**

# 当前实施优先级

目前优先级调整为：

1. **验证 Human Event Layer**：找到 iTerm2 + tmux -CC 输入路径中最合适的 Human Ctrl+C 捕获点。
2. **验证 tmux Bridge MVP**：active pane、read history、状态读取和 MCP 接入。
3. **实现 Execution Lease + Human Override + Pane ACL + Audit。**
4. **加入受控写入能力。**
5. **设计 AI Context Policy。**
6. **逐步引入 Command Block / Terminal Event Model。**
7. 必要时再考虑更复杂的 UI 或 Web Terminal；当前不作为目标。
因此短期技术问题已经从“怎么让 Codex 读写 tmux”收敛为：**如何让 Bridge 可靠知道人的行为，并让人的控制权始终高于 Agent。**
