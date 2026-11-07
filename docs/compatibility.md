# 兼容性与识别限制

AgentDock 通过来源应用已有的本地记录识别对话，采用非官方集成。当前在 Apple Silicon macOS 环境开发验证；README 中的接入范围表示已有实现，未覆盖各应用的全部版本、配置和状态组合。

## 官方 Codex

- 读取桌面对话库、轮次库、执行日志和项目元数据。每次最多读取 500 条未归档的 Codex Desktop 对话，排除子 Agent 等来源。
- 执行日志中的较新事件可覆盖滞后的轮次数据库；完成、报错和中断分别展示。
- 日志里有尚未得到回答的提问工具调用（`request_user_input`、`AskUserQuestion`）时，显示“待输入”；收到回答或轮次结束后更新。
- 未结束的轮次是否仍在执行，由来源应用的进程判断：应用正在运行，且启动时间早于本轮最后一次活动，就显示“执行中”，不论日志多久没有更新。应用已退出，或在本轮最后一次活动之后重启过，就显示“已中断”。
- 使用 `codex://threads/<id>` 打开指定对话，并显式交给对应应用处理。深链及数据库格式可能随版本变化。
- 原应用明确归档的对话会从跟进列表移除。

## 其他兼容 Codex 的应用

有些桌面应用沿用 Codex 的本地数据格式（`state_5.sqlite`、`thread_history_1.sqlite` 和 rollout 日志）。在 `~/Library/Application Support/AgentDock/codex-apps.json` 中登记后，AgentDock 按官方 Codex 的规则识别它们。文件内容是一个数组：

```json
[
  {
    "name": "My Codex Fork",
    "bundleID": "com.example.codex-fork",
    "dataDirectory": "~/.codex-fork",
    "threadHandlerBundleID": "com.example.codex-fork.runtime",
    "processBundleID": "com.example.codex-fork.runtime",
    "applicationPath": "/Applications/Codex Fork.app"
  }
]
```

| 字段 | 含义 |
|---|---|
| `name` | 界面上显示的应用名称 |
| `bundleID` | 应用的 bundle ID，也用作跟进记录中的来源标识 |
| `dataDirectory` | 存放 `state_5.sqlite` 的目录，开头的 `~` 表示用户主目录 |
| `threadHandlerBundleID` | 可选。接收 `codex://threads/<id>` 的应用；多个应用注册了同一个 URL scheme 时用它指定目标。默认等于 `bundleID` |
| `processBundleID` | 可选。实际执行轮次的进程，用于判断未结束的轮次是否仍在执行。默认等于 `threadHandlerBundleID` |
| `applicationPath` | 可选。系统找不到上述 bundle ID 对应的应用时使用的路径 |

文件无法解析时，“接入详情”里会显示错误原因，其他来源照常工作。修改后无需重启，下一次刷新即生效。

## Orca

- 读取 `local-default` profile 的本地会话、休眠记录和远程终端 Agent 快照。
- `working` 显示执行中；`waiting` 且终端标题含 `Action Required` 时显示待输入。
- 曾识别为 Agent 的同一终端清除 `agentStatus` 后，当前实现推断该轮结束。历史快照和 AgentDock 已保存记录用于衔接轮询之间的状态变化。
- 远程快照可能滞后；断连或格式变化会影响结束推断。它不是远端执行完成的独立回执。
- 转圈字符与 `Action Required` 前缀仅从显示标题中清理；原始标题仍用于状态识别。
- 当前打开 Orca 并复制标题，需在 Orca 内查找对应对话。

## Devin

- 读取本地 UI 会话列表与 CLI 会话库。每个会话从主消息链的最新一条消息往回读，直到最近一条用户消息，以此确定本轮状态：
  - 最新消息是不带工具调用的助手回复：本轮已完成。
  - 最新消息是向用户提问的工具调用（`ask_user_question`）：待输入。
  - 其他情况且有 Devin 进程持有会话锁：执行中。
  - 其他情况且没有进程持有会话锁：已中断。
- Devin 的后台进程会一直持有它打开过的所有会话的锁，所以会话锁只用来确认还有进程可能在处理本轮，单凭持锁不会判断为执行中。
- 对近期日志中的 `ContentFilter / Provider refusal` 做会话关联。拒绝之后没有新的助手回复、也没有新的用户消息时显示失败。
- 日志关联属于启发式逻辑，尚未覆盖全部并发场景。
- 尝试 Cascade 编辑器会话地址；指定对话跳转仍需跨版本验证。

## 跟进、通知与时间显示

- 执行中和待输入对话自动加入跟进，结束后保留至确认验收。同一已验收轮次不重复加入，检测到新轮次后重新加入。确认验收后 8 秒内可以撤销。
- 首次启动不会导入全部历史完成对话；Orca 可从快照恢复部分轮询间漏检的执行。
- 跟进中的对话进入待验收、待输入或异常时发送系统通知；AgentDock 每次启动后的第一次扫描只记录当前状态，不发通知。
- 来源读取失败时保留已有快照。来源读取成功但对话消失时：已经结束的对话保留最后状态；仍在执行或等待输入的对话改为“状态待确认”。
- 异常分组包括明确失败、中断以及监测不确定状态。“状态待确认”的详情会解释缺少哪些执行证据。
- 8 秒轮询之间开始又结束的短轮次可能漏检。
- 执行中卡片的动态时间从本轮开始时算起；来源没有记录开始时间时，从最近一次活动算起，鼠标悬停会说明使用的是哪种。结束卡片显示固定记录时间；Orca 推断完成的时间可能是结束前最后一次活动。
- 只有文件或数据库记录发生变化的对话会重新解析，其余沿用上一次结果；Devin 日志每次只读新追加的内容。

## 本地数据

AgentDock 不建立后端服务，不进行遥测、自动上传或模型调用。来源数据库使用 SQLite 只读连接打开，在本机解析相关字段和日志；解析日志时可能接触消息片段。

| 来源 | 读取位置 |
|---|---|
| Codex | `~/.codex/state_5.sqlite`、`thread_history_1.sqlite`、`.codex-global-state.json` 以及数据库记录指向的 rollout 日志 |
| 其他兼容 Codex 的应用 | `codex-apps.json` 中 `dataDirectory` 下的同类文件 |
| Orca | `~/Library/Application Support/orca/profiles/local-default/profile-state.db` 和同目录轮换备份 |
| Devin | `~/Library/Application Support/Devin/User/globalStorage/state.vscdb`、`~/.local/share/devin/cli/sessions.db`、`session_locks/` 和近期 `logs/` |

AgentDock 自己的配置是 `~/Library/Application Support/AgentDock/codex-apps.json`。跟踪快照位于 `com.local.AgentDock` UserDefaults 的 `AgentDock.trackingLedger` 键，可能包含标题、路径、对话 ID、首条消息和错误摘要，应按私有数据管理。打开第三方应用后，它按自身设置运行。

## 来源诊断

```bash
swift build -c release --product AgentDockScan
.build/release/AgentDockScan
```

它读取真实本地来源，连续扫描两次并输出耗时（第二次使用缓存），再按应用列出对话数量和各状态计数。输出中没有标题、路径或对话内容，但分享前仍应检查。请勿上传完整数据库、执行日志或偏好设置。

## 安装与图标

默认安装位置为 `/Applications/AgentDock.app`，需要相应目录的写入权限。使用 README 中的 `$HOME/Applications/AgentDock.app` 可安装到当前用户目录。

脚本向 LaunchServices 与 Spotlight 注册 App，使用本机 ad-hoc 签名，不安装登录启动项、不自动重启已有进程。当前没有 Apple Developer ID 签名、公证的官方安装包，请从可信源码构建，无需关闭系统安全保护。

界面文案以英文为源语言，简体中文翻译位于 `Resources/zh-Hans.lproj/Localizable.strings`，安装脚本会把它复制进 App。

图标可在 macOS 上重新生成：

```bash
swift scripts/generate-icon.swift Resources
iconutil -c icns Resources/AgentDock.iconset -o Resources/AgentDock.icns
```

返回 [README](../README.md)。
