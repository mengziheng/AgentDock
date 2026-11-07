# AgentDock

简体中文 · [English](README.en.md)

[![CI](https://github.com/mengziheng/AgentDock/actions/workflows/ci.yml/badge.svg)](https://github.com/mengziheng/AgentDock/actions/workflows/ci.yml)

**把分散在多个 AI 应用里的对话，收进一个工作台。**

同时用 Codex、Orca 和 Devin 做几件事，很容易忘记哪条对话还在跑、哪条已经交付、哪条正等你回答。AgentDock 把这些对话集中到一个原生 macOS 窗口，需要你处理时发出系统通知。

本地运行 · 只读扫描 · 无账号 · 无遥测 · 中英文界面 · MIT 开源

![AgentDock 工作台：同时查看执行中、待输入、异常和待验收的对话](docs/images/dashboard-light.png)

<sub>截图由项目代码渲染，任务均为虚构。</sub>

<details>
<summary>查看深色模式</summary>

![AgentDock 深色模式](docs/images/dashboard-dark.png)

</details>

## 它能帮你做什么

- **少切几个窗口。** 在一处查看各应用的对话标题、所在项目和当前状态，可以按标题、项目或对话 ID 搜索。
- **不用盯着窗口。** 跟进中的对话结束、等你回答或出错时，AgentDock 发送系统通知，点击通知即可打开该对话。Dock 图标上的数字是“待输入”和“异常”的总数。
- **记住还没验收的结果。** 正在执行或等你回答的对话会自动加入跟进，结束后继续保留，直到你点“确认验收”。可以一次验收整个列表，误点后 8 秒内可以撤销。
- **回到原应用处理。** Codex 的对话可以直接跳转；Devin 会尝试跳转到对应会话；Orca 会打开应用并复制对话标题，方便你查找。

### 四种状态

| 状态 | 你需要做什么 |
|---|---|
| **执行中** | 让它继续工作，稍后再看 |
| **待验收** | 检查本轮结果，满意后确认验收 |
| **待输入** | 回到对话，回答问题或作出选择 |
| **异常** | 打开详情，查看报错、中断或状态不确定的原因 |

“确认验收”只移除 AgentDock 的跟进记录，原对话保持不变。同一对话开始新一轮执行时，它会重新出现。

## 支持的应用

| 应用 | 能识别的内容 | 测试过的版本 |
|---|---|---|
| **官方 Codex**（ChatGPT 桌面应用） | 桌面对话、所在项目和每一轮的状态 | 26.1027.30824 |
| **其他兼容 Codex 的应用** | 在本机配置文件中登记后，识别方式与官方 Codex 相同，见[配置方法](docs/compatibility.md#其他兼容-codex-的应用) | — |
| **Orca** | 远程终端里的 Agent，以及本机标签页里运行的 Codex CLI 对话 | 1.4.243 |
| **Devin** | 本地会话的执行中、待输入、已完成、已中断和模型供应商拒绝 | 3.12.17 |

测试环境为 macOS 26.6.2（Apple Silicon）。AgentDock 读取的是各应用的本地存储，应用升级可能改变存储格式；如果识别结果不对，请先对照上表核对版本。

**已知限制**

- Codex 等你批准命令、Devin 等你授权工具时，显示为“执行中”。这两个应用不会把这类请求写进本地记录。
- Orca 的本机标签页只识别运行 Codex CLI 的；其他 Agent 只能识别已经结束的休眠会话。
- 这是实验性预览版，重要任务请在原应用中确认。完整的识别规则见[兼容性与识别限制](docs/compatibility.md)。

## 安装

需要：

- macOS 13 或更新版本
- Xcode 16 或更新版本；也可以只装 Command Line Tools，但需要包含 Swift 6
- Python 3（安装 Command Line Tools 时会一并装上）

```bash
git clone https://github.com/mengziheng/AgentDock.git
cd AgentDock
bash scripts/install-app.sh "$HOME/Applications/AgentDock.app"
open "$HOME/Applications/AgentDock.app"
```

安装脚本从源码构建 App，用本机临时签名（ad-hoc），不会添加登录项。目前没有经过 Apple 签名和公证的安装包，只能从源码安装。

首次打开时 macOS 会询问是否允许通知；拒绝了也不影响其他功能，之后可以在“系统设置 → 通知”中开启。界面语言跟随系统，支持简体中文和英文。需要开机自动打开时，在“系统设置 → 通用 → 登录项”中添加 `AgentDock.app`。

## 更新

先退出 AgentDock，然后在源码目录运行：

```bash
git pull
bash scripts/install-app.sh "$HOME/Applications/AgentDock.app"
```

跟进和验收记录会保留。

## 卸载

1. 退出 AgentDock，删除 `AgentDock.app`。
2. 如果添加过登录项，在“系统设置 → 通用 → 登录项”中移除。
3. 删除 AgentDock 自己的本地记录：

   ```bash
   defaults delete com.local.AgentDock
   rm -rf "$HOME/Library/Application Support/AgentDock"
   ```

   第一条删除跟进和验收记录，第二条删除兼容 Codex 应用的配置文件。各来源应用里的对话不受影响。

## 遇到问题

- **侧栏的来源旁显示橙点**：表示没有读到这个应用的数据。点窗口右下角的“接入详情”查看原因，常见原因是没装这个应用、还没在这台电脑上用过，或者应用升级后存储格式变了。
- **状态看起来不对**：点开卡片，看详情里的“状态依据”，它说明了这个判断来自哪条记录。
- **想检查各来源的识别情况**：在源码目录运行下面的命令。它连续扫描两次并输出耗时，再按应用列出对话数量和各状态的计数，不会输出标题、路径或对话内容。

  ```bash
  swift build -c release --product AgentDockScan
  .build/release/AgentDockScan
  ```

- **仍然解决不了**：提交 Issue，写明来源应用的版本和复现步骤，附上上面的诊断输出，并移除截图里的真实工作内容。

## 对话数据留在本机

AgentDock 没有后端服务，不调用模型，也不会上传对话或日志。它以只读方式读取来源应用的数据库和状态文件，跟进与验收记录只保存在本机。

这些本地记录可能包含对话标题、路径、首条消息和错误摘要，系统通知也会显示对话标题。读取了哪些位置见[本地数据说明](docs/compatibility.md#本地数据)，隐私问题见 [SECURITY.md](SECURITY.md)。

## 开发与贡献

```bash
swift build -c release
scripts/test.sh
```

`scripts/test.sh` 运行 `swift test`；只装了 Command Line Tools 时，它会补上 Swift Testing 框架的路径。装有 Xcode 时也可以直接运行 `swift test`。测试只使用合成数据，每次推送和 Pull Request 都会在 GitHub Actions 上构建并测试。欢迎反馈状态误判、版本兼容和使用体验，参见 [CONTRIBUTING.md](CONTRIBUTING.md)。

[MIT License](LICENSE) · 非官方独立项目，与所列应用及其供应商没有隶属或背书关系。
