# Shared Terminal Bridge：系列导览与阅读目录

<p align="center"><a href="https://github.com/sharpbai/shared-terminal-bridge">STB Core</a> · <a href="https://github.com/sharpbai/shared-terminal-bridge-rdc">RDC Adapter</a> · <a href="https://github.com/sharpbai/shared-terminal-bridge-docs"><strong>Documentation</strong></a></p>

> **系列导览**：本页是《Shared Terminal Bridge：人与 AI 共用真实终端的演进记录》的总目录。十篇文章按照“系统边界 → 人工接管 → 本地安全 → 上下文与等待 → 跨环境接入 → 实操收敛”的顺序，记录 STB 从问题原型走向可用系统的全过程。

## 项目背景：为什么要做 Shared Terminal Bridge

现有的 Codex 与 ChatGPT 已经非常适合以“会话”为单位完成开发、研究、方案设计和项目管理。模型可以围绕一组资料持续分析，在对话中形成计划、代码、文档和决策；对主要发生在信息与文件层面的工作，这种形态已经足够自然。
但运维和交互式 IT 支持并不只发生在会话里。它们还依赖一个持续存在、可以被人和 Agent 共同观察与操作的真实环境，例如：

- SSH 到一台服务器，延续当前目录、环境变量、sudo 状态和前台进程；
- 查看正在变化的日志、磁盘、网络、服务或部署状态；
- 在执行过程中等待、批准、中断、调整方案并继续；
- 人工接管同一个终端，补充只有现场人员才知道的信息；
- 将来连接 PowerShell、Windows 远程管理或其他交互式运维界面；
- 在不同 AI 客户端之间继续同一项工作，而不丢失目标机器上的真实上下文。
单个模型会话可以理解意图，却不天然拥有这种连续的操作上下文。如果每次对话都重新建立 Shell、重新复制输出、重新说明机器状态，Agent 看见的只是一次性的文本片段；如果模型另起一个隐藏终端，人又无法方便地观察、协助和接管。
因此我需要的并不是另一个聊天窗口，也不只是“让模型执行一条命令”，而是两项可以长期扩展的基础能力：

1. **一个集中且有上下文的 Agent 环境**：任务目标、终端历史、当前执行状态、人类事件、授权状态和审计记录可以持续存在，并由 Codex、ChatGPT 或未来的其他 Agent 复用。
2. **一个可扩展的操作界面**：今天可以通过 tmux 和 SSH 操作 Unix Shell，未来可以扩展到 PowerShell、Windows 远程环境以及其他适合 IT 支持的交互入口，同时保持相同的观察、授权、撤权和人工接管语义。
Shared Terminal Bridge 由此产生。它把模型的推理能力与真实操作环境连接起来，让 Agent 能够在可观察、可中断、可审计的边界内执行人的意图；同时不要求目标环境理解 AI，也不让某一个模型会话成为终端状态和控制权的所有者。

> **目标不是让 Agent 取代人的终端，而是为交互式 IT 支持建立一个共享、连续、可扩展的执行环境。**

## 一句话理解这套系统

Shared Terminal Bridge（STB）不重新开发一个 AI Terminal，而是让 Human、Codex 与 ChatGPT 围绕同一个真实 tmux 会话协作：tmux 保存事实，本地 Bridge 强制执行授权与撤权，模型负责理解、规划和解释，人始终拥有最高优先级的接管权。

## 推荐阅读路线

### 路线 A：从问题到安全模型

适合第一次了解 STB，建议依次阅读 **1 → 2 → 3 → 4**。这条路线解释为什么选择 tmux、怎样识别真人 Ctrl+C、怎样用 Execution Lease 阻止旧决策，以及如何封装为 Codex 可调用的本地服务。

### 路线 B：关注速度、Token 与长期任务

建议阅读 **5 → 6 → 7**。这部分集中讨论 AI Context Policy、Task Block、等待机制、审批和 TUI 的成本控制。

### 路线 C：关注 ChatGPT 与跨环境使用

建议阅读 **8 → 9 → 10**。这部分从 Codex 本地 MCP 扩展到 ChatGPT STB-RDC，并通过十五轮实操总结当前架构、性能账本与下一阶段路线图。

---

## 第一阶段：确定事实中心与人工最高控制权

### 01 · [Shared Terminal Bridge（一）：为什么不重新开发一个 AI Terminal](docs/01-why-not-ai-terminal.md)

从最初的问题出发：为什么不重新开发 Web Terminal 或 AI Terminal，而是保留人的 iTerm2 使用习惯，以 tmux 作为 Human 与 AI 共享的真实事实中心。
**关键词**：共享 Shell、tmux、事实中心、默认观察、可见执行。
**承上启下**：确定了系统边界后，下一个问题是怎样可靠识别“人正在夺回控制权”。

### 02 · [Shared Terminal Bridge（二）：Ctrl+C 不是命令失败，而是人类撤权](docs/02-human-ctrl-c.md)

记录从 iTerm2 Python API、全局按键监听到 tmux root key table 的探索，最终在输入路径上可靠区分 Human Ctrl+C 与 Agent Ctrl+C。
**关键词**：HumanEventLayer、来源分流、Unix Socket、fail-open。
**承上启下**：能够识别人类中断还不够，必须让中断之后尚未抵达终端的旧模型决策失效。

### 03 · [Shared Terminal Bridge（三）：Execution Lease 与 Generation 如何阻止过期的 AI 决策](docs/03-execution-lease-generation.md)

解释 Execution Lease、generation 和本地校验：人类按下 Ctrl+C 后，旧 generation 的动作即使已经由模型决定，也会在进入 pane 前被拒绝；后续新的用户消息则可获得新 generation。
**关键词**：Execution Lease、generation、stale action、Human Override。
**承上启下**：核心安全语义经过 PoC 验证后，需要合并为稳定的本地服务并提供给模型使用。

---

## 第二阶段：从本地服务走向高效日常使用

### 04 · [Shared Terminal Bridge（四）：从本地 PoC 到 Codex 可调用的安全终端服务](docs/04-local-poc-to-codex.md)

把 Human Event、Execution Lease、受控写入、观察与审计合并为 Local Bridge，并通过最小 MCP 和 stb 管理工具交给 Codex 使用。
**关键词**：Local Bridge、最小 MCP、托管 tmux、观察与写入分离、审计。
**承上启下**：工具可用以后，主要成本从“能否安全执行”转向“模型每轮应该读取多少终端内容”。

### 05 · [Shared Terminal Bridge（五）：AI Context Policy 与 Task Block 如何降低终端 Token 消耗](docs/05-ai-context-policy-task-block.md)

引入 AI Context Policy 与 terminal_task_block，避免把完整 scrollback、重复输出和空增量持续放进模型上下文，将任务目标、状态、证据和预算结构化。
**关键词**：AI Context Policy、Task Block、read delta、上下文预算、Token。
**承上启下**：短任务的上下文得到控制后，长命令仍会产生审批、等待、取消和模型空转问题。

### 06 · [Shared Terminal Bridge（六）：长任务、审批、等待与无 Token 关注机制](docs/06-long-jobs-approval-waiting.md)

处理长任务的完整生命周期：完整命令审批、事件驱动取消、完成通知、低 Token 等待、十分钟启发式复查以及超出合理预期后的重新评估。
**关键词**：长任务、审批、等待、取消、完成通知、启发式复查。
**承上启下**：命令行工作流已较顺畅，下一类高成本交互来自全屏 TUI。

### 07 · [Shared Terminal Bridge（七）：TUI 为什么昂贵，以及人机协作的轻量路径](docs/07-tui-lightweight-collaboration.md)

分析 TUI 为什么会带来屏幕重绘、布局错位、观察轮数与 Token 放大，并确定轻量路线：优先 CLI/CMD，其次由人协助操作，最后才由模型直接操作 TUI。
**关键词**：TUI、CLI 优先、人机协作、低成本显示、Token 控制。
**承上启下**：本地 Codex 使用方式基本成形后，架构开始面向“任意环境触发真实机器并共享上下文”的需求。

---

## 第三阶段：跨客户端扩展与工程收敛

### 08 · [Shared Terminal Bridge（八）：从 Codex MCP 到 ChatGPT STB-RDC](docs/08-codex-mcp-to-chatgpt-stb-rdc.md)

说明为什么要从 Codex 本地 MCP 扩展到 ChatGPT STB-RDC：Codex 是单机本地环境，而 ChatGPT 需要在任意环境触发实体机器、方便共享上下文，同时继续复用同一个 tmux、HumanEventLayer、Execution Lease 与 Job 语义。
**关键词**：Codex MCP、ChatGPT、RDC、跨环境访问、共享上下文。
**承上启下**：接入方式改变以后，需要重新检验核心安全语义能否跨客户端保持一致。

### 09 · [Shared Terminal Bridge（九）：从 PoC 到可用工具，十五轮实操如何驱动架构收敛](docs/09-fifteen-iterations.md)

复盘十五轮真实终端实操：从 Ctrl+C、租约续授、历史观察、脚本注入问题，到长任务、审批、等待、TUI 和性能优化，记录每轮问题如何推动架构收敛。
**关键词**：十五轮实操、回归基准、问题驱动、交互性能、架构收敛。
**承上启下**：真实使用已经验证系统可用，最后需要把当前能力、性能成本与未来方向固化成阶段性快照。

### 10 · [Shared Terminal Bridge（十）：当前架构、性能账本与下一阶段路线图](docs/10-current-architecture-roadmap.md)

汇总当前架构、核心安全不变量、性能与 Token 账本、Codex MCP / STB-RDC 双客户端结构，以及下一阶段的工程路线。
**关键词**：当前架构、性能账本、API v9、v0.14.0、路线图。

---

## 十篇文章之间的主线

```text
问题边界
  ↓
tmux 成为共享事实中心
  ↓
可信识别 Human Ctrl+C
  ↓
Execution Lease 撤销旧决策
  ↓
Local Bridge + 最小 MCP 产品化
  ↓
Context Policy + Task Block 降低模型负担
  ↓
事件驱动的审批、等待与取消
  ↓
CLI 优先的人机 TUI 协作
  ↓
从 Codex 本地扩展到 ChatGPT STB-RDC
  ↓
十五轮实操回归与架构收敛
  ↓
当前架构快照与下一阶段路线

```

## 核心设计原则

1. **tmux 是事实中心**：模型会话、客户端与传输方式可以变化，真实 Shell 状态不随之迁移。
2. **人类控制权最高**：Human Ctrl+C 是撤权事件，不是普通命令失败。
3. **安全由本地强制**：Bridge 使用 generation 校验阻止 stale action，而不是依赖提示词。
4. **观察与写入分离**：查看历史不需要持有执行租约，写入必须得到当前回合授权。
5. **命令在人面前可见**：不使用隐藏 Shell，不向目标环境注入临时控制脚本。
6. **上下文按需供应**：优先读增量、任务摘要和结构化结果，避免垃圾进入模型上下文。
7. **长等待事件驱动**：完成、取消与人工介入通过事件唤醒，模型不持续轮询。
8. **终端体验保持轻量**：优先标准 CLI；TUI 以人工协作和低成本观察为主。
9. **客户端可替换**：Codex MCP 与 ChatGPT STB-RDC 共享同一套本地安全语义。
10. **真实实操驱动演进**：每个重要机制都保留验收记录，并纳入后续基准测试。

## 从哪里开始

- **只想快速理解系统**：阅读第 1、2、3、10 篇。
- **准备实现相似系统**：按第 1–6 篇顺序阅读。
- **关注 Token 与交互效率**：重点阅读第 5、6、7、9 篇。
- **关注 ChatGPT 远程接入**：重点阅读第 8、9、10 篇。
- **准备参与后续演进**：先读第 10 篇，再按其中的路线图回看相关专题。

## 关联设计与验证资料

- [人与 Codex 共用终端的交互式运维架构260920](references/interactive-ops-architecture-260920.md)
- [Shared Terminal Bridge 迭代史：从 Ctrl+C PoC 到 API v9](references/stb-iteration-history-api-v9.md)
- [Shared Terminal Bridge：人与 Codex 共用 tmux 的交互式运维架构与实测](references/stb-codex-tmux-architecture-and-validation.md)
- [STB-RDC：ChatGPT 共享终端适配层 v0.1 及验收260922](references/stb-rdc-v0.1-acceptance-260922.md)

> 本目录是系列的稳定入口。后续新增文章时，应继续在这里补充阶段、阅读顺序与主线关系；原有十篇保留为阶段性历史，不覆盖其当时的设计结论。
