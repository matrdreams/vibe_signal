# Vibe Signal macOS App 技术方案

## 1. 背景与目标

这个项目要做一个 macOS 顶部状态栏应用，用一个类似红绿灯的状态图标展示 Codex 的运行状态：

- 红色：Codex 正在等待人为授权，或正在向用户提问，需要用户介入。
- 黄色：Codex 正在思考、生成回复、调用工具、执行命令或处理文件。
- 绿色：Codex 当前空闲，没有需要用户处理的活跃任务。

这个需求看起来像一个简单菜单栏工具，但真正的难点不是 UI，而是状态来源。一个稳定的方案必须回答几个问题：

- 用户可能在多个终端、多个项目里同时运行 Codex。
- Codex CLI 的内部协议、app-server 协议和通知能力会随版本变化。
- 后续可能希望支持 Claude Code、Aider、Cursor CLI、OpenAI Codex app-server、普通脚本等其他 agent。
- 菜单栏应用应该轻、稳定、低耗电，不应该强依赖重型运行时。

因此推荐把系统设计成 **通用 Agent 状态总线 + macOS 菜单栏客户端 + Codex 适配器**，而不是一个直接耦合 Codex 内部实现的菜单栏 app。

## 2. 推荐结论

推荐技术栈：

| 模块 | 推荐技术 | 说明 |
| --- | --- | --- |
| macOS 状态栏 UI | Swift + AppKit `NSStatusItem` | 最适合动态菜单栏图标，原生、轻量、稳定 |
| 设置页/弹窗 | SwiftUI | 用于设置、会话列表、诊断面板 |
| 状态 Hub | Swift 或 Go | 负责接收各类 agent 状态，归约成全局状态 |
| 本地 IPC | Unix domain socket + JSONL | 简单、稳定、适合本机进程通信 |
| 状态快照 | 原子 JSON 文件，后续可升级 SQLite | 方便菜单栏 app 启动时恢复最后状态 |
| Codex 普通 CLI 支持 | Codex hooks adapter | 稳定、适配用户直接在终端运行 `codex` 的习惯 |
| Codex 精确状态支持 | Codex app-server bridge，可选增强 | 更高保真，但作为增强 adapter，不作为唯一依赖 |
| 开机启动 | `SMAppService` | macOS 13+ 官方 Login Item 方案 |
| 自动更新 | Sparkle，可选 | 非 Mac App Store 分发时使用 |

如果项目只面向 macOS，建议 Hub 和菜单栏 app 都用 Swift 写，工程最简单。  
如果希望状态总线未来跨平台复用，建议 **Go 写 Hub/CLI，Swift 写 macOS 菜单栏 app**。

当前更推荐的路线是：

1. 第一阶段实现 `Codex hooks adapter + local status hub + Swift menu bar app`。
2. 第二阶段增加 `Codex app-server bridge`，提高 waiting/user input/thread 状态准确性。
3. 第三阶段开放通用 CLI/API，支持更多 agent。

## 3. 架构总览

整体结构：

```text
Codex CLI / Claude Code / Aider / custom scripts
        |
        | adapter / hook / bridge
        v
vibe-signal emit
        |
        | Unix domain socket + JSONL
        v
Local Vibe Signal Hub
        |
        | in-memory sessions + JSON snapshot
        v
macOS Menu Bar App
        |
        v
NSStatusItem red/yellow/green icon
```

职责拆分：

- **Adapter**：把某个 agent 的原始事件转换成统一状态事件。
- **Status Hub**：接收状态事件，维护每个 session 的最新状态，计算全局状态。
- **Menu Bar App**：只负责展示 Hub 给出的状态，不直接理解 Codex 内部细节。

这样做的好处：

- Codex hooks、Codex app-server、其他 agent 都只是不同输入源。
- 菜单栏 app 不需要因为 Codex 协议变化频繁改动。
- 以后支持其他 agent 时只需要新增 adapter。
- Hub 可以做 TTL、去重、优先级、状态回退和诊断。

## 4. 状态模型

### 4.1 统一状态枚举

对 UI 层只暴露少数稳定状态：

```text
blocked  -> 红色
working  -> 黄色
idle     -> 绿色
error    -> 红色或灰红色
unknown  -> 灰色
```

推荐 UI 映射：

| 状态 | 图标颜色 | 含义 |
| --- | --- | --- |
| `blocked` | 红色 | 需要用户操作，例如授权、回答问题、选择选项 |
| `working` | 黄色 | agent 正在执行，不需要立即干预 |
| `idle` | 绿色 | 没有活跃任务 |
| `error` | 红色或红色闪烁 | agent 或 adapter 出错 |
| `unknown` | 灰色 | Hub 启动但没有任何状态，或状态已过期 |

### 4.2 统一事件格式

每个 adapter 向 Hub 发送统一 JSONL 事件。建议第一版格式：

```json
{
  "schemaVersion": 1,
  "source": "codex",
  "adapter": "codex-hooks",
  "sessionId": "session-abc",
  "workspace": "/Users/kun/Code/example",
  "state": "blocked",
  "reason": "approval",
  "message": "Waiting for shell command approval",
  "startedAt": "2026-05-24T10:30:00Z",
  "updatedAt": "2026-05-24T10:30:05Z",
  "ttlMs": 300000,
  "metadata": {
    "model": "gpt-5.4",
    "turnId": "turn-123",
    "toolName": "Bash"
  }
}
```

字段说明：

| 字段 | 必需 | 说明 |
| --- | --- | --- |
| `schemaVersion` | 是 | 方便未来升级协议 |
| `source` | 是 | agent 来源，例如 `codex`、`claude`、`aider` |
| `adapter` | 是 | 具体适配器，例如 `codex-hooks`、`codex-app-server` |
| `sessionId` | 是 | 一个 agent 会话的稳定 ID |
| `workspace` | 否 | 工作目录，用于菜单展示 |
| `state` | 是 | `blocked` / `working` / `idle` / `error` / `unknown` |
| `reason` | 是 | 更细原因，例如 `approval`、`question`、`thinking`、`tool`、`done` |
| `message` | 否 | 人类可读描述 |
| `startedAt` | 否 | 当前状态开始时间 |
| `updatedAt` | 是 | 状态更新时间 |
| `ttlMs` | 否 | 状态过期时间，防止异常退出后永久黄灯/红灯 |
| `metadata` | 否 | source-specific 信息，UI 不强依赖 |

### 4.3 状态原因枚举

推荐 reason：

| reason | 对应 state | 说明 |
| --- | --- | --- |
| `approval` | `blocked` | 等待命令、文件修改、权限等授权 |
| `question` | `blocked` | agent 正在询问用户问题 |
| `thinking` | `working` | 模型正在生成或推理 |
| `tool` | `working` | 正在调用工具 |
| `command` | `working` | 正在执行 shell 命令 |
| `file_change` | `working` | 正在修改文件 |
| `review` | `working` | 自动审查或 approval review |
| `done` | `idle` | turn 已结束 |
| `session_start` | `idle` 或 `working` | 会话开始 |
| `error` | `error` | adapter 或 agent 出错 |
| `stale` | `unknown` | 状态过期 |

## 5. 全局状态归约规则

Hub 需要维护所有 session 的最新状态，然后归约成一个菜单栏图标状态。

优先级：

```text
blocked > error > working > idle > unknown
```

建议规则：

1. 只考虑未过期 session。
2. 任意 session 为 `blocked`，全局状态就是红色。
3. 没有 blocked，但任意 session 为 `working`，全局状态就是黄色。
4. 所有有效 session 都是 `idle`，全局状态就是绿色。
5. 没有有效 session，则显示灰色或绿色。产品体验上建议灰色表示“没有观测到 Codex”。

菜单栏图标只显示聚合状态颜色，不在图标旁显示数字。点击信号灯后，下拉菜单展示当前活跃 session 列表：

```text
Vibe Signal: Needs input

Active Sessions
● Red     example-api      Waiting for approval
● Yellow  web-ui           Running tests
● Yellow  vibe_signal     Thinking

Recent Idle
● Green   docs             Idle 3m ago

Open Workspace
Settings
Quit
```

### 5.1 多 session 展示规则

多个 Codex session 同时存在时，菜单栏信号灯只承担一个职责：提示用户当前整体是否需要注意。具体 session 明细放在点击后的下拉菜单中。

图标展示规则：

- 不显示 session 数字。
- 不显示项目名。
- 不显示文本状态。
- 只显示红/黄/绿/灰聚合状态。

下拉菜单展示规则：

1. 菜单打开时从 Hub 读取最新 snapshot，或使用 Hub 推送过来的内存状态重建菜单。
2. `blocked`、`working`、`error` 状态的 session 视为 active session，必须展示。
3. `idle` 默认不视为 active，可以隐藏；为了帮助用户确认最近结束的任务，可选展示在 `Recent Idle` 分组。
4. `unknown` 或过期 session 默认不展示在 active 列表，可放入诊断区域。
5. session 排序按状态优先级和更新时间排序：`blocked` 在最前，其次 `error`，再是 `working`，最后是最近 idle。
6. 同一 workspace 有多个 session 时不合并，除非后续明确设计 workspace grouping；MVP 保持每个 session 一行，避免隐藏重要状态。

active session 定义：

| state | 是否 active | 菜单展示 |
| --- | --- | --- |
| `blocked` | 是 | `Active Sessions`，红色，排最前 |
| `error` | 是 | `Active Sessions`，红色或警示色 |
| `working` | 是 | `Active Sessions`，黄色 |
| `idle` | 否 | 可选 `Recent Idle` |
| `unknown` | 否 | 可选诊断区域 |

示例聚合：

| Session A | Session B | Session C | 菜单栏图标 | 下拉菜单重点 |
| --- | --- | --- | --- | --- |
| `idle` | `idle` | `idle` | 绿色 | 可显示最近 idle，或显示无活跃会话 |
| `working` | `idle` | `idle` | 黄色 | 展示 working session |
| `working` | `working` | `idle` | 黄色 | 展示两个 working session |
| `blocked` | `working` | `idle` | 红色 | blocked session 排第一，working session 继续展示 |
| `blocked` | `blocked` | `working` | 红色 | 两个 blocked session 都展示 |

技术可行性：

- Codex hooks adapter 能提供 `session_id` 和 `cwd`，足够区分多个终端中的多个 Codex session。
- Hub 以 `sessionId` 为 key 存储状态，因此天然支持多 session。
- AppKit `NSStatusItem` 的菜单可以在每次打开前动态重建，展示当前 active session 列表。
- 如果 Codex 被强杀没有发送 `Stop`，Hub 通过 TTL 将该 session 从 active 降级为 stale，避免永久显示黄灯或红灯。

## 6. Codex 适配方案

### 6.1 第一阶段：Codex hooks adapter

这是推荐 MVP。原因：

- hooks 是 Codex 当前稳定 feature。
- 用户继续在终端运行普通 `codex`，不需要通过菜单栏 app 启动。
- hooks 能覆盖关键生命周期：session start、prompt submit、tool use、permission request、post tool use、stop。
- hooks 输入包含 `session_id`、`transcript_path`、`cwd`、`hook_event_name`、`model` 等字段，足够构造状态事件。

Codex hooks 到状态的映射：

| Codex hook | 状态 | reason | 说明 |
| --- | --- | --- | --- |
| `SessionStart` | `idle` | `session_start` | 会话已被观测到 |
| `UserPromptSubmit` | `working` | `thinking` | 用户提交 prompt，agent 即将开始 |
| `PreToolUse` | `working` | `tool` | 工具调用前 |
| `PermissionRequest` | `blocked` | `approval` | 等待用户授权 |
| `PostToolUse` | `working` | `thinking` | 工具调用结束，模型可能继续 |
| `Stop` | `idle` | `done` | 当前 turn 停止 |
| `SubagentStart` | `working` | `tool` | 子 agent 开始 |
| `SubagentStop` | `working` 或 `idle` | `done` | 子 agent 停止 |

示例 hook 配置：

```toml
# ~/.codex/config.toml

[[hooks.SessionStart]]
matcher = "startup|resume|clear|compact"

[[hooks.SessionStart.hooks]]
type = "command"
command = "/usr/local/bin/vibe-signal-codex-hook"
timeout = 5
statusMessage = "Updating Vibe Signal status"

[[hooks.UserPromptSubmit]]

[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = "/usr/local/bin/vibe-signal-codex-hook"
timeout = 5

[[hooks.PreToolUse]]
matcher = ".*"

[[hooks.PreToolUse.hooks]]
type = "command"
command = "/usr/local/bin/vibe-signal-codex-hook"
timeout = 5

[[hooks.PermissionRequest]]
matcher = ".*"

[[hooks.PermissionRequest.hooks]]
type = "command"
command = "/usr/local/bin/vibe-signal-codex-hook"
timeout = 5
statusMessage = "Updating Codex approval status"

[[hooks.PostToolUse]]
matcher = ".*"

[[hooks.PostToolUse.hooks]]
type = "command"
command = "/usr/local/bin/vibe-signal-codex-hook"
timeout = 5

[[hooks.Stop]]

[[hooks.Stop.hooks]]
type = "command"
command = "/usr/local/bin/vibe-signal-codex-hook"
timeout = 5
```

`vibe-signal-codex-hook` 的职责：

1. 从 stdin 读取 Codex hook JSON。
2. 根据 `hook_event_name`、`tool_name`、`cwd`、`session_id` 等字段映射状态。
3. 调用 `vibe-signal emit` 或直接写 Unix socket。
4. 不阻塞 Codex 主流程；超时要短。
5. 如果 Hub 不存在，静默失败或写入 fallback snapshot。

伪代码：

```text
input = read_json(stdin)
eventName = input.hook_event_name

switch eventName:
  SessionStart:
    state = idle, reason = session_start
  UserPromptSubmit:
    state = working, reason = thinking
  PreToolUse:
    state = working, reason = tool
  PermissionRequest:
    state = blocked, reason = approval
  PostToolUse:
    state = working, reason = thinking
  Stop:
    state = idle, reason = done
  default:
    state = working, reason = tool

emit({
  source: "codex",
  adapter: "codex-hooks",
  sessionId: input.session_id,
  workspace: input.cwd,
  state,
  reason,
  updatedAt: now(),
  ttlMs: state == idle ? 600000 : 300000,
  metadata: {
    model: input.model,
    turnId: input.turn_id,
    toolName: input.tool_name,
    transcriptPath: input.transcript_path
  }
})
```

hooks adapter 的限制：

- `Stop` 表示 turn 停止，但不一定能判断最后消息是不是一个问题。
- 如果 Codex 崩溃或用户强杀，可能没有 Stop 事件，需要 TTL 回收。
- hooks 是 turn-scope 事件，精确度不如 app-server 的实时状态流。
- 用户第一次启用 hook 后可能需要在 Codex 内信任 hook。

### 6.2 第二阶段：Codex app-server bridge

Codex app-server 是更高保真的状态来源。它提供 JSON-RPC 事件流，可观察：

- `thread/status/changed`
- `turn/started`
- `turn/completed`
- `item/started`
- `item/completed`
- `serverRequest/resolved`
- approval/user input 相关 server requests

关键状态：

| app-server 事件/字段 | 映射状态 |
| --- | --- |
| `thread/status/changed` with `activeFlags: ["waitingOnApproval"]` | `blocked` / `approval` |
| `thread/status/changed` with `activeFlags: ["waitingOnUserInput"]` | `blocked` / `question` |
| `thread/status/changed` with `type: "active"` | `working` |
| `turn/started` | `working` / `thinking` |
| `item/started` for command/tool | `working` / `tool` |
| `turn/completed` | 可能 `idle`，需结合 thread 状态 |
| `thread/status/changed` with `type: "idle"` | `idle` |

app-server bridge 的定位：

- 不作为第一阶段唯一状态源。
- 作为 Codex 精确状态增强 adapter。
- 可以通过设置开关启用。
- 如果 app-server 连接失败，不影响 hooks adapter 和菜单栏主功能。

需要注意：

- 本地 `codex app-server` 命令仍有 experimental 标记。
- WebSocket transport 官方文档也提示 experimental/unsupported。
- 如果直接绑定该协议，后续 Codex 更新可能需要适配。
- 因此 app-server bridge 应独立封装，并带版本检测。

## 7. Status Hub 设计

### 7.1 职责

Status Hub 是一个本地后台服务，负责：

- 监听 Unix domain socket。
- 接收 adapter 发来的 JSONL 状态事件。
- 校验 schema。
- 更新 session 状态。
- 计算全局状态。
- 写入状态 snapshot。
- 向菜单栏 app 提供当前状态和增量变化。

### 7.2 进程模型

两种实现方式：

#### 方案 A：Hub 嵌入菜单栏 app

菜单栏 app 启动后同时启动 socket server。

优点：

- 工程简单。
- 只有一个 app bundle。
- 适合 MVP。

缺点：

- 菜单栏 app 退出后 hooks 无法上报状态。
- adapter 需要处理 Hub 不在线的情况。

#### 方案 B：Hub 是单独 Login Item / helper

Hub 作为 app bundle 内的 helper，由 `SMAppService` 注册开机启动。

优点：

- UI 和后台服务生命周期解耦。
- Hub 可以在菜单栏 UI 重启时继续存在。
- 更适合长期产品化。

缺点：

- 工程结构更复杂。
- 需要处理 XPC/Unix socket 权限和 helper 管理。

推荐：

- MVP 用方案 A。
- 当功能稳定后升级到方案 B。

### 7.3 Socket 路径

建议路径：

```text
~/Library/Application Support/VibeSignal/vibe-signal.sock
```

或者更通用：

```text
~/Library/Application Support/VibeSignal/hub.sock
```

如果考虑路径长度和 Unix socket 限制，可以使用：

```text
/tmp/vibe-signal-$UID.sock
```

但 `/tmp` 生命周期不稳定，macOS 重启后会清理。推荐应用支持目录 + 启动时清理旧 socket。

### 7.4 Snapshot 文件

建议路径：

```text
~/Library/Application Support/VibeSignal/state.json
```

写入方式：

1. 写到 `state.json.tmp`。
2. `fsync`。
3. 原子 rename 到 `state.json`。

snapshot 示例：

```json
{
  "schemaVersion": 1,
  "globalState": "blocked",
  "updatedAt": "2026-05-24T10:30:05Z",
  "sessions": [
    {
      "source": "codex",
      "adapter": "codex-hooks",
      "sessionId": "abc",
      "workspace": "/Users/kun/Code/example",
      "state": "blocked",
      "reason": "approval",
      "message": "Waiting for approval",
      "updatedAt": "2026-05-24T10:30:05Z",
      "ttlMs": 300000
    }
  ]
}
```

### 7.5 TTL 与异常退出

TTL 非常重要。没有 TTL，Codex 被强杀时可能永久显示黄色或红色。

建议：

| 状态 | 默认 TTL |
| --- | --- |
| `blocked` | 30 分钟 |
| `working` | 5 分钟 |
| `idle` | 24 小时，或不参与过期 |
| `error` | 10 分钟 |
| `unknown` | 立即可替换 |

Hub 每隔 5-10 秒扫描一次状态：

- `working` 过期后降级为 `unknown` 或 `idle`，菜单中标注 stale。
- `blocked` 过期后仍可保留为红色一段更长时间，因为用户可能确实离开了。
- 如果 session 长时间没有更新，可以从菜单中折叠或隐藏。

## 8. macOS 菜单栏应用设计

### 8.1 UI API 选择

状态栏图标推荐用 AppKit `NSStatusItem`，不是纯 SwiftUI `MenuBarExtra`。

原因：

- `NSStatusItem` 对动态图片、模板图片、自定义绘制、tooltip 控制更直接。
- 红黄绿状态灯需要频繁更新 icon。
- 菜单栏 app 这种小工具，AppKit 更成熟可控。
- SwiftUI 可以用在设置页和弹窗，不必承担状态栏 icon 的核心职责。

### 8.2 图标设计

图标可以是一个 3 灯横排或竖排的 traffic-light 样式：

```text
● ● ●
```

当前状态的灯点亮，其他灯低透明度：

- 红色状态：红灯亮，黄/绿暗。
- 黄色状态：黄灯亮，红/绿暗。
- 绿色状态：绿灯亮，红/黄暗。
- unknown：三灯灰色。

注意事项：

- 菜单栏背景可能是浅色、深色或透明。
- 图标尺寸建议 18x18 pt，提供 @2x。
- 动态绘制比准备多张 png 更灵活。
- 可用 Core Graphics 或 SwiftUI view render 成 `NSImage`。

### 8.3 菜单内容

第一版菜单建议：

```text
Vibe Signal: Waiting for approval

Active Sessions
  ● Red     example-api      Approval required
  ● Yellow  vibe_signal     Thinking

Recent Idle
  ● Green   docs             Idle 3m ago

Open Logs
Settings...
Start at Login      ✓
Quit
```

菜单内容应围绕当前活跃会话组织。`blocked`、`working`、`error` 会话必须展示；`idle` 会话默认隐藏或放入 `Recent Idle`。不要在菜单里做太多复杂交互。这个应用的主要价值是 glanceable status。

### 8.4 通知策略

可选功能：

- 进入 `blocked` 时发送 macOS notification。
- 从 `blocked` 恢复到 `working` 或 `idle` 时不通知，避免噪音。
- 同一 session 的 blocked 通知做 debounce，例如 60 秒内只发一次。

通知文案：

```text
Codex needs input
example-api is waiting for approval
```

### 8.5 启动与权限

开机启动：

- macOS 13+ 使用 `SMAppService`。
- 在设置页提供 “Launch at Login” 开关。

文件权限：

- 读取/写入 `~/Library/Application Support/VibeSignal`。
- 不需要读取项目源码。
- hooks adapter 会收到 Codex 提供的 `cwd` 和 metadata，但不需要读取文件内容。

网络权限：

- MVP 不需要网络。
- app-server bridge 如果只连接本地 socket，也不需要外网。

## 9. CLI 与 Adapter 设计

建议提供一个小 CLI：

```text
vibe-signal emit --source codex --state working --reason thinking
vibe-signal snapshot
vibe-signal doctor
vibe-signal install-codex-hooks
vibe-signal uninstall-codex-hooks
```

职责：

- `emit`：给 hooks 和第三方脚本使用。
- `snapshot`：打印当前 Hub 状态，方便调试。
- `doctor`：检查 socket、配置文件、Codex hooks、权限。
- `install-codex-hooks`：自动修改或提示修改 Codex config。

如果 CLI 用 Swift：

- 可以和 app 共用状态模型。
- 打包在 `.app/Contents/MacOS/vibe-signal`。
- 安装 hook 时可以创建 symlink 到 `/usr/local/bin` 或使用完整路径。

如果 CLI 用 Go：

- 单文件二进制，脚本调用方便。
- 未来更容易跨平台。
- 需要和 Swift app 共享 JSON schema，而不是共享代码。

## 10. 安全与隐私

原则：

- 状态事件不包含 prompt 正文。
- 不保存 command 完整输出。
- workspace 路径可选脱敏。
- 不上传任何数据。
- 本地 socket 只允许当前用户访问。

metadata 建议限制：

允许：

- session id
- workspace basename 或完整路径
- hook event name
- tool name
- model slug
- turn id
- timestamp

避免：

- 用户 prompt 全文
- shell command 全文，除非用户显式开启
- 文件 diff
- token 或认证信息
- 终端输出

socket 文件权限：

```text
0600 for state files
0700 for parent directory
current user only for socket
```

## 11. 实现阶段

### Phase 0：验证原型

目标：

- 能通过一个 CLI 手动发状态。
- 菜单栏图标能变红黄绿。

任务：

- 建 Swift macOS app。
- 创建 `NSStatusItem`。
- 实现动态 traffic-light icon。
- 实现本地状态模型。
- 临时从 JSON snapshot 读状态。

完成标准：

- 运行 `vibe-signal emit --state blocked` 后图标变红。
- 运行 `vibe-signal emit --state working` 后图标变黄。
- 运行 `vibe-signal emit --state idle` 后图标变绿。

### Phase 1：Codex hooks MVP

目标：

- 普通终端里的 Codex 能自动更新状态。

任务：

- 实现 Unix socket Hub。
- 实现 `vibe-signal emit`。
- 实现 `vibe-signal-codex-hook`。
- 提供 hooks 配置模板。
- 加 TTL 回收。
- 菜单显示 session 列表。

完成标准：

- 用户在终端运行 `codex`。
- 提交 prompt 后黄灯。
- Codex 请求 approval 时红灯。
- Codex turn 完成后绿灯。

### Phase 2：安装与诊断

目标：

- 用户可以可靠安装、启用和排错。

任务：

- `vibe-signal doctor`。
- `install-codex-hooks`。
- 设置页显示 Codex hook 状态。
- launch at login。
- 日志面板。

完成标准：

- 新机器上 1-2 步完成安装。
- hook 没启用、Hub 没启动、socket 不可写时能给出明确诊断。

### Phase 3：Codex app-server bridge

目标：

- 提升状态准确性，特别是 user input / approval / multi-thread。

任务：

- 实现 app-server client。
- 监听 `thread/status/changed`、`turn/*`、`item/*`。
- 处理 app-server 版本检测。
- 与 hooks adapter 去重。

完成标准：

- app-server 可用时优先使用高保真状态。
- app-server 不可用时自动回退 hooks。

### Phase 4：通用 agent 支持

目标：

- 不再只是 Codex 状态灯，而是通用 agent 状态灯。

任务：

- 文档化 JSONL 协议。
- 支持 Claude Code hook adapter。
- 支持 Aider adapter。
- 支持自定义 shell integration。

完成标准：

- 第三方脚本可以通过 `vibe-signal emit` 控制状态。
- 菜单按 source 分组展示。

## 12. 测试策略

### 12.1 单元测试

重点测试：

- 状态事件 JSON decode。
- schema version 兼容。
- 状态优先级归约。
- TTL 过期。
- 重复事件去重。
- session 删除/隐藏。

### 12.2 集成测试

用 fixtures 模拟 Codex hook stdin：

- `SessionStart`
- `UserPromptSubmit`
- `PreToolUse`
- `PermissionRequest`
- `PostToolUse`
- `Stop`

验证 Hub snapshot 和全局状态。

### 12.3 UI 测试

验证：

- 红黄绿图标在浅色/深色菜单栏可见。
- 菜单内容不会过宽。
- 多 session 排序稳定。
- 长 workspace 名称能截断。

### 12.4 手工测试场景

- 单个 Codex 会话正常完成。
- Codex 请求 shell approval。
- Codex 请求文件修改 approval。
- 多个终端同时运行 Codex。
- 强杀 Codex 进程。
- 菜单栏 app 重启。
- Hub socket 文件残留。
- 电脑睡眠后恢复。

## 13. 风险与应对

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| Codex hooks 配置变化 | adapter 失效 | `doctor` 检测版本与 hook 可用性 |
| 用户未信任 hooks | 状态不上报 | 设置页明确提示，并提供操作说明 |
| Codex 强杀没有 Stop | 永久黄灯/红灯 | TTL 自动降级 |
| app-server 协议变化 | 精确 adapter 失效 | app-server bridge 作为可选增强，不影响 MVP |
| 多 session 状态冲突 | 图标误导 | 明确红 > 黄 > 绿优先级，菜单展示细节 |
| socket 不可写 | hooks 阻塞或失败 | hook 超时短，失败静默，写 fallback log |
| 泄露 prompt/command | 隐私风险 | 默认不采集正文和输出 |

## 14. 为什么不是其他方案

### 14.1 直接读取终端文本

不推荐。

问题：

- 依赖终端渲染和文本格式。
- 不同 terminal/tmux/zellij 表现不同。
- 很难区分“正在思考”和“等待用户”。
- 需要辅助功能权限或复杂 shell 集成。

### 14.2 只用 Codex `notify`

不推荐作为主方案。

问题：

- notify 更偏向 turn complete 通知。
- 对 approval/request user input 的覆盖不如 hooks/app-server。
- 不适合作为持续状态流。

### 14.3 只用 Codex app-server

适合高保真增强，但不建议作为 MVP 唯一依赖。

问题：

- 本地 CLI 标记 app-server/remote-control 相关能力为 experimental。
- 用户普通终端直接运行 `codex` 时，不一定自然接入这个状态流。
- 协议变化可能导致菜单栏 app 频繁跟随更新。

### 14.4 Electron

不推荐。

问题：

- 对状态栏小工具过重。
- 内存、启动速度和打包体积都不划算。
- macOS 原生状态栏细节仍要处理。

### 14.5 Tauri

可行，但不是最优。

适合：

- 未来需要复杂跨平台 UI。
- 已经有 Web 前端资产。

当前不推荐的原因：

- 本项目主要 UI 是菜单栏图标和小菜单。
- Swift/AppKit 更直接、更稳定。
- 引入 Rust + WebView + 前端构建链收益有限。

## 15. 推荐项目结构

如果采用 Swift-only：

```text
vibe_signal/
  ARCHITECTURE.md
  VibeSignal.xcodeproj
  VibeSignal/
    App/
      VibeSignalApp.swift
      AppDelegate.swift
    MenuBar/
      StatusItemController.swift
      TrafficLightIconRenderer.swift
      StatusMenuBuilder.swift
    Hub/
      VibeSignalHub.swift
      UnixSocketServer.swift
      StateStore.swift
      StatusReducer.swift
    Adapters/
      CodexHookMapper.swift
    CLI/
      VibeSignalCLI.swift
    Shared/
      VibeSignalEvent.swift
      AgentSession.swift
      GlobalStatus.swift
    Settings/
      SettingsView.swift
      LaunchAtLoginController.swift
    Diagnostics/
      Doctor.swift
      LogStore.swift
  Tests/
    StatusReducerTests.swift
    CodexHookMapperTests.swift
    StateStoreTests.swift
```

如果采用 Go Hub + Swift UI：

```text
vibe_signal/
  ARCHITECTURE.md
  hub/
    cmd/vibe-signal/
    internal/socket/
    internal/state/
    internal/adapters/codexhooks/
  macos/
    VibeSignal.xcodeproj
    VibeSignal/
  schemas/
    vibe-signal-event.schema.json
```

## 16. 参考资料

- Codex CLI: https://developers.openai.com/codex/cli
- Codex hooks: https://developers.openai.com/codex/hooks
- Codex config reference: https://developers.openai.com/codex/config-reference
- Codex app-server: https://developers.openai.com/codex/app-server
- Apple `NSStatusItem`: https://developer.apple.com/documentation/appkit/nsstatusitem
- Apple XPC: https://developer.apple.com/documentation/xpc
- Apple `SMAppService`: https://developer.apple.com/documentation/servicemanagement/smappservice
- Tauri tray: https://v2.tauri.app/learn/system-tray/
- Electron Tray: https://www.electronjs.org/docs/api/tray/

## 17. 当前建议

最稳妥的下一步不是马上写完整 macOS app，而是先实现最小闭环：

1. 定义 `VibeSignalEvent` JSON schema。
2. 写一个本地 Hub，可以接收 `vibe-signal emit`。
3. 写一个 `NSStatusItem` app，订阅 Hub 状态并渲染红黄绿图标。
4. 写 Codex hooks adapter，把真实 Codex 生命周期接进来。

这个闭环完成后，就已经能解决核心问题。后续再加 app-server bridge、安装器、诊断、自动更新和多 agent 支持。
