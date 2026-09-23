# Shared Terminal Bridge 迭代史：从 Ctrl+C PoC 到 API v9

> 本文记录 Shared Terminal Bridge 从最初 Ctrl+C 来源分流 PoC 到 API v9 / v0.14.0 的完整迭代过程。重点不是罗列功能，而是说明每一次真实会话暴露了什么问题、为什么改变设计、调整后效果如何，以及问题如何推动下一版。
相关文档：

- [Shared Terminal Bridge：人与 Codex 共用 tmux 的交互式运维架构与实测](stb-codex-tmux-architecture-and-validation.md)
- [人与 Codex 共用终端的交互式运维架构260920](interactive-ops-architecture-260920.md)
<table_of_contents/>

# 版本口径

项目早期以连续 PoC 和会话驱动开发为主，Git 历史只有“Initial commit”和“event-driven terminal job workflow”两个阶段性提交，并没有为每个内部改动建立 Git tag。
因此本文采用两个互补口径：

1. **Bridge API v1–v9**：代表外部能力和兼容边界。
2. **实操会话版本**：代表用户真实体验与问题反馈，例如 local-33 磁盘占用 03、05、10、14、15。
已明确的发布版本：

- MCP `0.5.1`：早期最小 MCP 已初始化，但 deferred tool discovery 尚未处理。
- Bridge/MCP `v0.10.0 / API v6`：事件驱动 job wait 阶段。
- Bridge/MCP `v0.13.0 / API v8`：只读 TaskBlockRunner。
- Bridge/MCP `v0.14.0 / API v9`：程序 capability profile 与 TUI 选路。
早期 API v1–v5、v7 的独立语义版本号未被可靠保留，本文不伪造编号，只记录 API 能力。

# 总览时间线

<table fit-page-width="true" header-row="true">
<tr>
<td>阶段</td>
<td>核心能力</td>
<td>主要问题来源</td>
<td>结果</td>
</tr>
<tr>
<td>PoC 0</td>
<td>Human/Agent Ctrl+C 来源分流</td>
<td>iTerm2 全局监听不合适</td>
<td>控制面转向 tmux</td>
</tr>
<tr>
<td>API v1</td>
<td>Observation、Pane ACL、Action Guard</td>
<td>需要共享同一真实终端</td>
<td>只读和写入边界成立</td>
</tr>
<tr>
<td>API v2</td>
<td>cursor delta、Task Block 元数据</td>
<td>历史重复进入上下文</td>
<td>确定性上下文预算</td>
</tr>
<tr>
<td>API v3–v4</td>
<td>会话名工具、本地等待、长任务批准</td>
<td>轮询和长任务审批体验差</td>
<td>减少短轮询，批准绑定真实 turn</td>
</tr>
<tr>
<td>API v5–v6</td>
<td>Job、事件取消、通知与策略复核</td>
<td>等待阻塞、新消息无法继续</td>
<td>等待可即时取消，不中断终端任务</td>
</tr>
<tr>
<td>API v7</td>
<td>持久交互历史</td>
<td>缺少可比较的实操证据</td>
<td>形成性能基准</td>
</tr>
<tr>
<td>API v8</td>
<td>只读 TaskBlockRunner</td>
<td>复杂任务模型编排轮数过高</td>
<td>普通首检 input 降约 30%</td>
</tr>
<tr>
<td>API v9</td>
<td>程序能力画像、TUI 选路</td>
<td>TestDisk TUI 消耗 14.303M input</td>
<td>会话 15 整体 input 降约 79%</td>
</tr>
</table>

# 第一阶段：从 iTerm2 监听转向 tmux

## 最初思路

第一版实验尝试通过 iTerm2 Python API 观察按键。很快出现两个问题：

- 需要开启 iTerm2 Python API，连接和窗口生命周期不稳定。
- 脚本会弹出新窗口；Ctrl+C 行为难以限定到特定交互窗口。
- 全局键盘监听会混入其他窗口输入，安全边界不清晰。
- 实际共享对象不是 iTerm2，而是 tmux session/pane。

## 关键转向

设计从“监听 Terminal 模拟器”改为“把 tmux 作为唯一控制面”。
验证结果：

- 真人 Ctrl+C 经过 tmux client key table。
- Agent 的 `tmux send-keys C-c` 直接进入 pane。
- 两条路径天然可区分，无需 macOS 全局键盘监听。
- 可以同时得到 pane ID 和 client TTY。
这一版建立了项目最重要的基础判断：

> 不盯 iTerm2，不监听全局键盘；人和 Agent 的协作边界应建立在 tmux client 与 pane 之间。

# 第二阶段：Human Event Unix Socket

文件日志 PoC 证明来源可以区分后，下一版改为 Unix domain socket 结构化事件。
事件包含：

```json
{
  "seq": 1,
  "type": "human_interrupt",
  "source": "tmux_client",
  "key": "C-c",
  "session": "human-event-socket-poc",
  "pane": "%0",
  "client": "/dev/ttys021",
  "timestamp": "..."
}

```

## 本版解决的问题

- 从轮询日志变为即时结构化事件。
- socket 权限为 0600。
- 单调 seq 可发现丢失或乱序。
- Agent Ctrl+C 不误报为 Human。
- listener 未运行时保持 fail-open，真人中断仍立即到达前台进程。

## 遗留问题

知道“人按了 Ctrl+C”还不够，必须保证模型已经规划但尚未落地的后续动作不能继续执行。由此进入 Execution Lease。

# 第三阶段：Execution Lease 与 stale generation

这一版为每个受控 pane 引入 lease：

```text
pane + generation + state

```

真人 Ctrl+C 将 `ACTIVE` 变成 `REVOKED`。所有后续写入必须携带 generation；旧 generation 在进入 pane 前被拒绝。

## 首次验证

PoC 中：

- generation 1 的正常动作被允许。
- Agent Ctrl+C 不撤销 lease。
- 真人 Ctrl+C 产生 Human Override。
- Human Override 后 generation 1 的旧动作被拒绝。
这明确了撤销语义：

> 用户在模型作出决策后按 Ctrl+C，模型此前尚未执行的决策不再具有执行权。

## 后续演进

最初 MCP 没有可信 Codex turn ID，曾考虑用单增 Unix 时间戳判断后续用户消息。最终实现采用：

```text
thread_id + turn_id + turn_started_at_ms

```

时间戳负责严格单增，唯一 turn ID 排除同毫秒碰撞和回放。只有 Codex 落盘的新 UserMessage 才能在 Human Override 后重新 acquire。

# 第四阶段：Observation Bridge 与 Pane ACL（API v1）

在控制能力之前，先完成只读 Observation：

- `terminal_list`
- `terminal_read`
- `terminal_state`
- per-client active pane resolution
- Pane ACL

## 设计效果

- 授权 history/state 可读。
- 未授权 pane 读写均被拒绝。
- 未知 client fail closed，不回退到模糊的“当前 pane”。
- 观察与写入开始分层。

## 合并本地 daemon

Observation、Human Event、Execution Lease 和 Action Guard 随后合并到一个保持状态的本地 JSON daemon，完成 14 项端到端检查。
接着补齐：

- tmux Ctrl+C binding 的原配置备份和精确恢复。
- SIGKILL 后 ACTIVE lease 自动撤销。
- state 文件 0600。
- daemon 单实例 `flock`。
- tmux server UUID，阻止 pane ID 复用污染授权。
- 真实日常 tmux 的 9 项人工验收。
到这里，安全原型阶段完成。

# 第五阶段：最小 MCP 与托管会话

最小 stdio MCP 不直接操作 tmux，而是转发到 Bridge Unix socket。初版默认只发布 Observation tools，Action 必须显式启用。
随后加入：

- 托管 tmux session 创建、解析和停止。
- `stb create/enter/list/info/stop`。
- 创建时自动配置 100,000 行历史和鼠标。
- MCP 创建交互会话后，本地一键进入。
- 本机管理 lease、批准、job 和历史。

## 会话 05：提示“没有可用工具”

实际 MCP Server `0.5.1` 已初始化，但 Codex Desktop 使用 deferred tool discovery，模型没有搜索延迟工具目录便误报不可用。

### 调整

新增项目级 routing Skill：

- 遇到 shared-terminal-bridge、stb、verify33 或交互终端请求时搜索 deferred catalog。
- 已知精确会话名时直接调用 name-based 工具。
- 只有实际搜索和连接均失败时才能报告工具不可用。

### 效果

后续新会话可以稳定发现 MCP，不再因为工具未预加载而误判。

# 第六阶段：真实运维基线 03——功能正确但效率不足

“检查 local-33 磁盘占用03”首次完整验证了真实工作流：

1. 新 Codex task 获取 generation。
2. 执行磁盘检查。
3. 人按 Ctrl+C 中断扫描。
4. Agent 停止后续写入，只返回已有信息。
5. 后续用户消息到达后取得新 generation。
6. 人在共享终端授予 root，Agent 继续只读分析。

## 数据

<table fit-page-width="true" header-row="true">
<tr>
<td>回合</td>
<td>耗时</td>
<td>MCP 调用</td>
<td>Input</td>
</tr>
<tr>
<td>基础容量检查</td>
<td>32.845s</td>
<td>6</td>
<td>306,434</td>
</tr>
<tr>
<td>Ctrl+C 中断</td>
<td>41.660s</td>
<td>6</td>
<td>263,415</td>
</tr>
<tr>
<td>root 后深入分析</td>
<td>181.000s</td>
<td>13</td>
<td>774,810</td>
</tr>
</table>
三回合合计 255.505 秒、25 次 MCP、1.345M input。

## 关键发现

Bridge Unix socket 通常只有 10–30 ms。主要成本不在 IPC，而在：

- 每条命令后重新采样模型。
- 完整终端历史反复进入上下文。
- 短轮询。
- 审批链和重复工具说明。
- 复杂任务被切成很多模型决策点。
这一基线推动了 AI Context Policy 和 Task Block。

# 第七阶段：AI Context Policy 与 Task Block（API v2）

API v2 引入：

- `terminal_read_delta`
- opaque cursor
- 输出行数与字节预算
- ANSI/control 清理
- 重复行和命令回显折叠
- `terminal_task_block`
- `terminal_task_observe`

## 会话 04：task block 和 read delta 失败

初版在真实会话中暴露兼容性和 daemon 版本未同步问题。调整后：

- 增加 `bridge_info` 和 API 版本协商。
- MCP 按 live daemon 的 API 动态发布工具。
- 旧 daemon 返回明确的 `BRIDGE_RESTART_REQUIRED`。
- 更新后重启 daemon，避免源代码版本与运行实例不一致。

## 为什么 terminal_task_block 只记录、不执行

早期曾考虑一次提交命令列表，由 Bridge 注入脚本或 wrapper。真实会话中出现临时脚本：

```text
/bin/sh /var/folders/.../stb-task-....sh
No such file

```

这说明该方向对目标环境做了错误假设：临时文件只存在本机，却被要求在远程 shell 中执行。

### 最终决策

- Task Block 仅在本地 daemon 保存计划、generation 和观察起点。
- 不向目标环境注入脚本、marker、临时文件、TTY 设置或隐藏协议。
- 每条实际命令都必须在终端中显式可见。
- 大文件传输等特殊需求使用目标环境明确支持的标准命令。
这成为后续所有执行设计的硬边界。

# 第八阶段：观察与写入解耦

某次会话只想查看历史，却遇到 `EXECUTION_LEASE_ALREADY_ACTIVE`。
问题在于模型把“观察终端”误解为“需要获得写权限”。

## 调整

- `terminal_read`、`terminal_read_delta`、`terminal_state` 不需要 lease。
- ACTIVE lease 只控制 Agent 写权，不独占 tmux 或历史。
- 人可以使用鼠标 copy-mode 查看历史，不影响前台程序或 Agent job。
- 同一 pane 上的普通键入仍不建议人和 Agent 同时进行。
- 人类 Ctrl+C 保持最高优先级。
效果是只读查看不再抢占或释放现有 lease。

# 第九阶段：长任务批准与管理入口（API v3–v4）

早期长命令需要批准，但用户没有获得清晰的交互提示。

## 调整方案

采用“方案 1 + 方案 3”，保留“方案 4”管理入口：

- 对话中展示完整命令、预计耗时、资源影响和预算。
- 本地创建待批准 request，不执行命令。
- 用户在后续消息回复“确认执行”。
- 新 turn acquire 后，批准生成一次性 approval ID。
- approval 与 request、命令 SHA-256、pane、generation 和预算绑定。
- `stb approvals/approve/reject` 作为人工管理入口。
API v4 将长任务 request 结构化，解决“批准的是哪条命令”的歧义。

# 第十阶段：Job、通知与低 token 等待（API v5–v6 / v0.10.0）

用户反馈长命令开始后“不知道什么时候会好”，希望不用一直盯着。

## API v5：Terminal Job

每个 `terminal_submit` 返回 `job_id`，可查看：

- RUNNING / COMPLETED
- INTERRUPTED_BY_HUMAN
- NEEDS_ATTENTION
- HUMAN_DECISION_REQUIRED
- 最近活动、输出摘要、预算和完成置信度

## API v6：事件驱动等待

`terminal_wait_job` 在 Bridge 本地等待，最长 10 分钟，不用模型短轮询。
策略：

- 完成、Human Override、交互提示或错误时提前返回。
- 10 分钟无结论时返回 `STRATEGY_REVIEW_REQUIRED`。
- 明显超过合理预期时要求比较替代方案。
- `HUMAN_DECISION_REQUIRED` 留给人工判断，不自动 Ctrl+C。
- macOS 通知提示完成或状态变化。

## 会话 10：人工中断等待后，新消息阻塞

旧实现用固定轮询或阻塞 MCP 请求，用户取消等待后，旧调用可能仍占据会话。

### 调整

- MCP 接收 `notifications/cancelled(requestId)`。
- request ID 映射到 Bridge `wait_id`。
- Bridge 使用 Event 即时唤醒等待。
- 取消只取消“模型等待”，不停止终端命令。
- 新用户消息不再被旧 wait 阻塞。

## 会话 11

用户反馈“明显感觉好用多了”。这确认事件取消、本地等待和重新评估边界有效，随后创建阶段性 Git 提交 `Add event-driven terminal job workflow`。

# 第十一阶段：持久历史与会话 12–13（API v7）

会话 12 已没有明显错误，主要感受是仍可更快。随后加入 tmux/STB 交互历史：

```text
~/.local/state/shared-terminal-bridge/history.jsonl

```

记录动作、pane、generation、状态和脱敏命令摘要，文件权限 0600。

## 会话 13：功能稳定，瓶颈转向模型编排

实操表现顺畅，但复杂任务仍记录 65 次命令提交。首次磁盘检查较会话 12 缩短约 33%，说明前置流程、lease、等待和历史已经工作。
暴露的问题：

- 旧密码提示污染当前 job 判断。
- 同一 turn 重复 acquire。
- wait 完成后追加 status。
- 未闭合引号等明显命令错误。
- 复杂确定性只读步骤仍逐条唤醒模型。
- SSH 断线和取消恢复仍需验证。

## 调整规划

- 提示检测限制在当前 job 输出。
- 同 turn acquire 幂等。
- wait 终态直接携带 bounded output。
- 本地命令完整性 lint。
- 新增版本化只读 TaskBlockRunner。
- 本地检测空增量、循环和无进展。

# 第十二阶段：只读 TaskBlockRunner（API v8 / v0.13.0）

API v8 新增 `terminal_task_block_execute`，旧 Task Block 语义保持不变。

## 能力

- 1–8 个确定性只读步骤。
- 本地逐步调度，不向目标环境传脚本。
- 每步独立 job、可见命令、审计和 generation 校验。
- Human Ctrl+C、交互提示、上下文变化和断言失败立即停止。
- shell 控制符、重定向、展开、未知可执行文件和修改子命令 fail closed。
同时完成：

- 当前 job 范围的提示检测。
- 同 turn acquire 幂等。
- wait 终态提示。
- 不完整命令拒绝。
- 自动回归 63 项通过。

# 第十三阶段：会话 14——Runner 有效，TUI 成为新瓶颈

首次磁盘检查：

<table fit-page-width="true" header-row="true">
<tr>
<td>指标</td>
<td>会话 13</td>
<td>会话 14</td>
<td>变化</td>
</tr>
<tr>
<td>耗时</td>
<td>30.661s</td>
<td>28.471s</td>
<td>-7.1%</td>
</tr>
<tr>
<td>Input token</td>
<td>247,452</td>
<td>172,781</td>
<td>-30.2%</td>
</tr>
<tr>
<td>Output token</td>
<td>932</td>
<td>771</td>
<td>-17.3%</td>
</tr>
</table>
TaskBlockRunner 明确降低了普通检查的模型往返。

## TestDisk TUI 问题

三个主要 TUI 回合：

- 91 次按键。
- 26 次整屏读取。
- 878.9 秒。
- 14.303M input，占整段会话约 64%。
同时出现：

- 全屏退出后显示对齐异常。
- ncurses alternate screen 或 TTY 模式未完全恢复。
- 有按键越过 TUI 生命周期边界并落到 shell 的风险。
- `fdisk`、`blkid`、`testdisk /version`、`qemu-nbd --version` 被 Runner 保守拒绝。

## 策略重排

不建设重型通用 TUI 自动化。固定顺序改为：

```text
程序原生 CLI / CMD / batch
        ↓
人类辅助 TUI 到检查点
        ↓
Agent 轻量、受限 TUI

```

# 第十四阶段：程序能力画像（API v9 / v0.14.0）

API v9 新增纯本地 `terminal_program_profile`：

- 不读写 pane。
- 不需要 lease。
- 首批覆盖 TestDisk 和 PhotoRec。
- 指导优先使用官方 `/cmd`、batch、日志和导出接口。
- 能力画像不代表目标安装版本必然支持，必须先做安全 version probe。
Runner 精确增加：

- `fdisk -l TARGET`
- `blkid -p [-O OFFSET] TARGET`
- TestDisk 版本探测
- `qemu-nbd --version`
没有把整个程序笼统标记为只读，模板之外继续 fail closed。
项目 Skill 同步加入：

- 全屏程序先查 capability profile。
- 非交互接口不足时，让人连续操作到明确检查点。
- Agent 逐键操作作为最后 fallback。
- 强制退出后先检查前台进程和显示状态。
完整回归达到 67 项。

# 第十五阶段：会话 15——进入日常可用状态

会话 15 完成多轮磁盘分析、长扫描、精确删除和删除后验证，全程没有：

- TUI。
- Human Override。
- lease 冲突。
- Runner 拒绝。
- MCP 错误。
- 空增量轮询。
- 等待阻塞。

<table fit-page-width="true" header-row="true">
<tr>
<td>指标</td>
<td>会话 14</td>
<td>会话 15</td>
<td>变化</td>
</tr>
<tr>
<td>活跃时间</td>
<td>1,743.958s</td>
<td>604.434s</td>
<td>-65.3%</td>
</tr>
<tr>
<td>Input token</td>
<td>22.439M</td>
<td>4.727M</td>
<td>-78.9%</td>
</tr>
<tr>
<td>非缓存 input</td>
<td>478,749</td>
<td>85,156</td>
<td>-82.2%</td>
</tr>
<tr>
<td>TUI 按键 / 整屏读取</td>
<td>91 / 26</td>
<td>0 / 0</td>
<td>-100%</td>
</tr>
</table>
改善主要来自完全避开 TUI。两次任务范围不完全相同，不能把全部降幅归因于单一代码改动。

## 尚未改善的普通首检

首次磁盘检查：

- 会话 14：28.471 秒、172,781 input。
- 会话 15：42.756 秒、171,482 input。
Input 基本持平，但耗时增加约 50%。会话 15 中 Bridge 工具只占约 7.2 秒，其余约 35.5 秒来自模型首 token、工具发现和编排。
因此当前瓶颈已经明确：

> 系统控制面足够快；下一阶段应减少模型编排边界和上下文垃圾，而不是继续优化 Unix socket。

# 补充修复：新 tmux server 首次创建

在 API v9 后，`stb create verify33` 曾出现：

```text
TMUX_COMMAND_FAILED: no server running on .../default

```

原因是创建逻辑在 `new-session` 之前执行 `set-option -g`。新 socket 尚无 tmux server，因此失败。
修复后：

1. 先 `new-session` 启动 server。
2. 再设置全局和窗口 history-limit。
3. 开启鼠标并写入 managed identity。
4. 如果旧 tmux server 已消失，旧 Bridge state 先归档，不绑定到新 server。
修复后 `verify33` 实际创建成功，100,000 行历史和鼠标均生效。

# 迭代中形成的九条原则

1. **控制面是 tmux，不是 Terminal 模拟器。**
2. **Human Ctrl+C 是撤销执行权，不是普通命令失败。**
3. **安全约束必须由本地 Bridge 强制，不能只靠模型提示词。**
4. **观察不应抢占 lease，写入才需要授权。**
5. **不向未知目标环境注入 wrapper、临时脚本和隐藏协议。**
6. **完整历史留在本地，模型只消费有预算的增量。**
7. **确定性只读步骤可本地批量调度，语义决策才返回模型。**
8. **长任务在本地等待并通知，不用 token 轮询。**
9. **先寻找 CLI/CMD/batch，再人类辅助 TUI，Agent TUI 最后。**

# 当前状态

截至 2026-09-22：

- Bridge/MCP：`v0.14.0 / API v9`。
- 自动回归：67 项通过。
- Human Override、后续 turn 重授权、长任务审批、事件取消、持久历史和托管会话均已实操验证。
- 日常普通命令、长扫描和写入后验证体验稳定。
- 会话 15 已证明项目从 PoC 进入可日常使用阶段。

# 下一轮优化方向

1. `terminal_wait_job output_complete=true` 后禁止多余 status。
2. 真正长任务默认使用一次 10 分钟本地等待，不显式传短 60 秒预算。
3. 用同会话、同文件系统的历史 job 改善预计时间，但不取消 high I/O 人工批准。
4. 将性能基准拆成普通首检、长扫描、写入加验证和 TUI 四类。
5. 继续降低模型编排轮数。
6. 只做轻量 TUI 生命周期保护和 changed-row snapshot，不建设通用自动化。
7. 补齐 SSH Broken pipe、daemon restart 和远程上下文变化的长期真实回归。

# 结语

这个项目的每一版几乎都不是“预先设计完成后照图施工”，而是由真实会话推动：

- 全局监听不安全，于是转向 tmux。
- 事件只能知道中断，于是加入 lease。
- lease 无法识别后续用户消息，于是建立可信 turn identity。
- 完整历史太贵，于是建立 Context Policy。
- 脚本注入假设目标环境，于是 Task Block 改为纯本地元数据。
- 长等待消耗注意力，于是建立 job、通知和事件取消。
- 命令轮数太多，于是建立只读 Runner。
- TUI 消耗失控，于是建立程序能力画像和人类检查点策略。
最终形成的不是一个“更自动”的终端，而是一个**人始终拥有最高控制权、模型能力可被精确授权、上下文和注意力成本可管理的共享终端协作层**。
