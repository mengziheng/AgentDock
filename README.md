<p align="center">
  <img src="Resources/AgentDock.iconset/icon_256x256.png" width="112" alt="AgentDock 图标">
</p>

<h1 align="center">AgentDock</h1>

<p align="center">
  <b>一个窗口，看清所有 AI 对话的进度。</b><br>
  同时开着 Codex、Orca、Devin 时，哪条还在跑、哪条做完了、哪条在等你回答，一眼就能看到。
</p>

<p align="center">
  <a href="https://github.com/mengziheng/AgentDock/actions/workflows/ci.yml"><img src="https://github.com/mengziheng/AgentDock/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License"></a>
</p>

<p align="center">简体中文 · <a href="README.en.md">English</a></p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/dashboard-dark.png">
  <img src="docs/images/dashboard-light.png" alt="AgentDock 工作台示例：执行中、待输入、异常和待验收的对话">
</picture>

## 功能

- **集中查看**：各应用里的对话按状态分成四组，可以按标题、项目或对话 ID 搜索。
- **主动提醒**：对话做完、等你回答或出错时发系统通知，点一下就回到那条对话。Dock 图标显示待输入和异常的数量。
- **不漏结果**：做完的对话一直留在列表里，直到你确认验收；可以一次全部验收，误点后能撤销。
- **数据不出本机**：直接读取各应用保存在本机的记录，不需要账号，不上传任何内容。

| 状态 | 含义 | 你要做的 |
|---|---|---|
| 执行中 | Agent 还在工作 | 稍后再看 |
| 待验收 | 这一轮已经做完 | 检查结果，确认验收 |
| 待输入 | Agent 在等你回答 | 回到对话作答 |
| 异常 | 出错、中断或状态不明 | 打开详情看原因 |

## 支持的应用

| 应用 | 能识别什么 | 测试版本 |
|---|---|---|
| 官方 Codex | 桌面对话和每一轮的状态，可直接跳转到对话 | 26.1027.30824 |
| Orca | 远程终端里的 Agent，以及本机标签页里的 Codex CLI | 1.4.243 |
| Devin | 执行中、待输入、完成、中断和模型拒绝，会尝试跳转到会话 | 3.12.17 |
| 其他兼容 Codex 的应用 | 写进配置文件后，与官方 Codex 相同（[配置方法](docs/compatibility.md#其他兼容-codex-的应用)） | — |

测试环境为 macOS 26.6.2（Apple Silicon）。Codex 等你批准命令、Devin 等你授权工具时会显示为“执行中”，因为这两个应用不在本机记录这类请求。完整说明见[兼容性与识别限制](docs/compatibility.md)。

## 安装

需要 macOS 13 及以上，以及 Xcode 16 或包含 Swift 6 的 Command Line Tools。

```bash
git clone https://github.com/mengziheng/AgentDock.git
cd AgentDock
bash scripts/install-app.sh "$HOME/Applications/AgentDock.app"
open "$HOME/Applications/AgentDock.app"
```

目前没有经过 Apple 签名的安装包，需要从源码安装。首次打开时请允许通知；界面语言跟随系统，支持中文和英文。

<details>
<summary><b>更新与卸载</b></summary>

**更新**：退出 AgentDock，在源码目录运行 `git pull`，再执行一次上面的安装命令。跟进记录会保留。

**卸载**：退出并删除 `AgentDock.app`，然后清除本地记录（各应用里的对话不受影响）：

```bash
defaults delete com.local.AgentDock
rm -rf "$HOME/Library/Application Support/AgentDock"
```

</details>

<details>
<summary><b>遇到问题</b></summary>

- **侧栏的来源旁显示橙点**：没有读到这个应用的数据。点窗口右下角的“接入详情”查看原因。
- **状态看起来不对**：点开卡片，详情里的“状态依据”说明了判断来自哪条记录。
- **检查各来源的识别情况**：运行下面的命令，它只输出各应用的对话数量和状态计数，不包含对话内容。

  ```bash
  swift build -c release --product AgentDockScan && .build/release/AgentDockScan
  ```

- 仍然解决不了，请[提交 Issue](https://github.com/mengziheng/AgentDock/issues)，写明应用版本和复现步骤。

</details>

## 隐私

AgentDock 没有服务器，不调用模型，只以只读方式读取本机数据。它保存的跟进记录可能包含对话标题和路径，系统通知也会显示对话标题。详见 [SECURITY.md](SECURITY.md)。

## 参与开发

```bash
swift build -c release
scripts/test.sh
```

测试只使用虚构数据。欢迎反馈识别错误和兼容性问题，参见 [CONTRIBUTING.md](CONTRIBUTING.md)。

<sub>MIT License · 独立项目，与所列应用及其开发商没有关联。截图中的任务均为虚构。</sub>
