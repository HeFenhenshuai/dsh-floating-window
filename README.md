<div align="center">

# DSH Floating Window

**简体中文** · [English](./README.en.md)

**把 DSH 会话弹出为独立的桌面置顶悬浮窗**

跨窗口多任务办公利器 · 压在任何 IDE / 浏览器之上 · 完整会话同步 · 实时流式响应

**本安装包** · `windows-v1.1.0`

**GitHub 下载** · [Windows v1.0.0 下载（ZIP）](https://github.com/HeFenhenshuai/dsh-floating-window/releases/download/v1.0.0/dsh-floating-window-1.0.zip) · [macOS v1.0.0 下载（ZIP）](https://github.com/HeFenhenshuai/dsh-floating-window/releases/download/macos-v1.0.0/dsh-floating-window-macos-v1.0.0.zip)

[![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20macOS-0078d4.svg)](#系统要求)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![DeepSeek Harness Plugin](https://img.shields.io/badge/Plugin-DSH%20Desktop-blue.svg)](#安装指南)

<br/>

<p align="center">
  <img src="./docs/preview.png" width="370" alt="悬浮窗置顶实机界面" style="border-radius: 8px; box-shadow: 0 6px 20px rgba(0,0,0,0.25); margin: 6px;" />
  &emsp;
  <img src="./docs/sessions.png" width="370" alt="多会话下拉切换与即时搜索" style="border-radius: 8px; box-shadow: 0 6px 20px rgba(0,0,0,0.25); margin: 6px;" />
</p>

<p><em>左：半透明置顶悬浮窗主界面 &emsp;|&emsp; 右：深色多会话切换、工作区归类与即时搜索</em></p>

</div>

---

## windows-v1.1.0 更新说明

- **四边、四角缩放。** 拖动左右边只调宽度，拖动上下边只调高度。拖动四角可同时调宽高。热区贴着窗口外缘，鼠标移上去会显示缩放光标。
- **新对话分区。** 初始使用 DSH 内置的「默认工作区」。可在浮窗「＋」旁选择，也可到 DSH「设置 → 悬浮窗 → 行为 → 新对话默认分区」点「更改」。两处共用同一份设置，选择后自动保存。
- **唤回已有浮窗。** 浮窗最小化或被遮挡时，再点主窗口输入框旁的「浮窗」，原窗口会恢复并置前，继续显示原会话。
- **回主窗口确认。** 当前会话等待审批或回答问题时，浮窗会显示「去主窗口确认」。点击后，DSH 主窗口会打开同一会话。

---

## 💡 为什么需要它？

在使用 DSH（DeepSeek Harness）Desktop 时，一旦你切到代码编辑器、终端或浏览器查阅资料，DSH 窗口就会被遮挡；最小化后更是无法随时提问或查看结果。

**DSH Floating Window** 专为桌面多任务场景打造，**交互构成参考了「豆包」桌面端悬浮窗的优秀设计**：
- **真正的原生独立进程**：始终压在所有应用最顶层，DSH 最小化后依然可用。
- **全功能打通官方会话**：直接操作 DSH 真实会话，支持会话切换、历史追溯、多模态图文输入与新建会话。
- **随时交接回主窗口**：一键将浮窗中进行的对话无缝切回 DSH 主界面（如同豆包浮窗的「在主窗口中打开」体验）。

---

## ✨ 核心特性

- 🪟 **原生桌面级悬浮窗**
  - **窗口移动与缩放**：拖动标题栏空白处可移动窗口。Windows 版支持从四边和四角缩放。
  - **独立控制按钮**：标题栏自带「新建会话」、「始终置顶切换（图钉）」、「一键清理缓存」、「最小化」与「关闭」。
  - **快捷交互**：可选开启按 `Esc` 快速关闭浮窗；位置、大小与不透明度自动记忆。
- 💬 **全功能会话管理**
  - **多会话无缝流转**：左上角下拉菜单直观浏览全部会话，支持搜索与会话切换。
  - **多模态图文支持**：支持拖入、粘贴或点击图标发送图片附件（最多 4 张），完整展示对话中的图片。
  - **流式回答与推理聚合**：实时流式输出；长篇的「思考过程」与「工具调用」自动折叠为一行，界面清爽聚焦。
  - **一键回主窗口**：右上角「主窗口」按钮可随时将当前会话交还给 DSH 主界面继续操作。
- 🎨 **外观与深度自适应**
  - 四态主题切换：`跟随 DSH` / `跟随 系统` / `浅色` / `深色`。
  - 在 DSH 中修改主题外观，悬浮窗与原生标题栏**毫秒级即时联动**，无需重启。
  - 支持调整窗口整体不透明度（60% ~ 100%）。
- 🧹 **安全无害的缓存管理**
  - 设置页实时查看浏览器缓存与日志体积。
  - 专属清理逻辑：仅清理 7 类纯渲染与着色器缓存，**绝不清除 Cookie 与 LocalStorage**，不会导致退出登录或丢失会话关联。

---

## 📋 系统要求

| 平台 | 系统要求 | 运行环境 |
| --- | --- | --- |
| Windows | Windows 10 / 11 | DSH Desktop 和 WebView2 Runtime |
| macOS | macOS 12 或更高版本 | DSH Desktop，使用系统自带的 WKWebView |

两个版本都需要启用 DSH 的会话插件 `@deepseek-ai/dsh-client-ui-conversation`，浮窗按钮会出现在聊天输入框旁。

---

## 📥 安装指南

### 从 Windows 安装包安装

1. 解压 `dsh-floating-window-windows-v1.1.0.zip`。
2. 在 DSH 的插件页添加本地插件，选择解压后包含 `package.json` 的 `dsh-floating-window-windows` 文件夹。
3. 完全退出并重新打开 DSH Desktop，再点输入框旁的「浮窗」。

### 把仓库链接发给 DSH 安装

按你的系统复制下面一句，直接发到 DSH Desktop 的聊天框：

- **Windows**：请帮我安装 DSH 悬浮窗插件，使用这个仓库的 `main` 分支：https://github.com/HeFenhenshuai/dsh-floating-window
- **macOS（M 系列 Mac）**：请帮我安装 DSH 悬浮窗插件，使用这个仓库的 `macos` 分支：https://github.com/HeFenhenshuai/dsh-floating-window/tree/macos

DSH 完成安装后，完全退出并重新打开 DSH Desktop，再点击聊天输入框旁的「浮窗」。

---

## 🚀 快速上手

1. **唤起浮窗**：重启 DSH 后，在主窗口输入框右侧会新增一颗 **浮窗** 按钮，点击即可弹出独立窗口，并默认同步当前会话上下文。
2. **多会话切换**：点击浮窗左上角当前会话名（如 `新对话 ▾`），即可在下拉列表中切换历史会话或点击「＋」新建会话。
3. **切回主窗口**：点击浮窗顶部的「**主窗口**」按钮，当前会话将立刻切回 DSH 主界面打开。
4. **自定义设置**：进入 DSH「设置」→ 左侧导航选择「**悬浮窗**」，可自由调节主题、不透明度、置顶状态及查看缓存占用。

---

## ⚙️ 配置项一览

插件的配置可直接在 **DSH 设置 → 悬浮窗** 中可视化修改：

| 配置项 | 类型 / 取值范围 | 默认值 | 说明 | 生效时机 |
| :--- | :--- | :--- | :--- | :--- |
| **外观方案** (`appearance`) | `dsh` / `system` / `light` / `dark` | `dsh` | 浮窗颜色主题（`dsh` 即跟随 DSH 外观） | 即时生效 |
| **始终置顶** (`alwaysOnTop`) | boolean | `true` | 是否保持压在其他所有应用窗口之上 | 即时生效 |
| **不透明度** (`opacity`) | number (0.6 ~ 1.0) | `1.0` | 窗口整体透明度滑块 | 即时生效 |
| **记住窗口位置** (`rememberGeometry`) | boolean | `true` | 下次打开时是否恢复上次拖拽的尺寸与坐标 | 下次开窗 |
| **默认尺寸** (`defaultWidth` / `Height`) | 宽度 320~1600 / 高度 260~1600 | Windows：620 × 900；macOS：406 × 571 | 未记忆几何尺寸时的初始窗口大小 (px) | 下次开窗 |
| **新对话默认分区（Windows）** (`defaultWorkspaceId`) | 工作区 | 默认工作区 | 从浮窗新建会话时使用的分区 | 保存后生效 |
| **按 Esc 关闭** (`closeOnEscape`) | boolean | `false` | 浮窗激活状态下按 `Esc` 键直接关闭窗口 | 即时生效 |

---

## ❓ 常见问题 (FAQ)

<details>
<summary><b>Q1: 点击「浮窗」按钮后没有反应，或提示打开失败？</b></summary>

1. **请确认是否在 DSH Desktop（桌面版）中运行**：Web 版由于缺少安全渲染器头，接口会直接拒绝开窗请求。
2. **请确认是否已重启 DSH**：初次安装插件后必须完全退出并重启 DSH Desktop。
3. **检查文件完整性**：打开安装插件时选择的文件夹。Windows 版应包含 `window/dsh-floating-window.exe`，macOS 版应包含 `window/dsh-floating-window.app`。`plugin/` 和 `window/` 需要放在一起。
</details>

<details>
<summary><b>Q2: 悬浮窗打开后显示白屏或提示 forbidden？</b></summary>

* 请从 DSH Desktop 聊天输入框右侧的「浮窗」按钮打开窗口。这样 DSH 会为当前会话提供登录凭证。直接双击 Windows 的 `.exe` 或 macOS 的 `.app` 启动时，窗口拿不到这份凭证。
</details>

<details>
<summary><b>Q3: 清理缓存会不会把我退出登录或删掉对话？</b></summary>

* **不会**。Windows 版清理 WebView2 的渲染缓存，macOS 版清理 WebKit 的渲染缓存。两个版本都会保留登录信息和会话数据。
</details>

---

## 🏗️ 架构与源码编译
本项目采用三层协同架构：
Windows 和 macOS 版本分别维护在两个分支中：

- **Windows** 使用 `main` 分支，原生窗口基于 C#、WinForms 和 WebView2。下面的目录图和编译命令适用于 Windows 版。
- **macOS** 使用 `macos` 分支，原生窗口基于 Swift、AppKit 和 WKWebView。[查看 Swift 源码](https://github.com/HeFenhenshuai/dsh-floating-window/tree/macos/window/src) · [查看构建脚本](https://github.com/HeFenhenshuai/dsh-floating-window/blob/macos/window/build.sh)

```text
dsh-floating-window/
├── plugin/
│   ├── host.js              # Node.js 宿主端：负责路由转发、鉴权令牌、拉起原生窗口进程
│   ├── client.js            # DSH 前端扩展：输入框浮窗入口按钮、设置页面板
│   └── page/float.html      # 悬浮窗内容页：精简版流式聊天界面、多模态附件、会话切换
├── window/                  # Windows 原生窗口进程
│   ├── dsh-floating-window.exe  # 预编译的原生外壳程序
│   └── src/FloatWindow.cs   # 窗口源码（约 2000 行，WinForms + WebView2，C# 5）
└── docs/
    ├── preview.png          # 实机效果图（深色悬浮窗主界面）
    └── sessions.png         # 实机效果图（深色多会话切换与搜索）
```

---

## 🤝 致谢与开源协议

- **项目维护者** [@HeFenhenshuai](https://github.com/HeFenhenshuai)
- **交互设计与灵感**：本插件的悬浮窗交互构成与使用场景参考了 **豆包（Doubao）桌面端悬浮窗**（无边框置顶悬浮、多会话即时流转、一键交接回主窗口打开）。
- **上游开源项目**：本项目基于社区项目 [dsh-float-chat](https://github.com/cyh3436332528/dsh-float-chat)（原作者 [@cyh3436332528](https://github.com/cyh3436332528)）的初始实现演进与维护，特此鸣谢。
- 遵循 [MIT License](./LICENSE) 开源协议。
