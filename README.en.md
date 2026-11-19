<div align="center">

# DSH Floating Window

[简体中文](./README.md) · **English**

**Keep a DSH conversation in its own always-on-top desktop window.**

Read streaming replies and continue the same conversation while you work in an IDE, terminal, or browser.

**Download** · [Windows v1.0.0 (ZIP)](https://github.com/HeFenhenshuai/dsh-floating-window/releases/download/v1.0.0/dsh-floating-window-1.0.zip) · [macOS v1.0.0 (ZIP)](https://github.com/HeFenhenshuai/dsh-floating-window/releases/download/macos-v1.0.0/dsh-floating-window-macos-v1.0.0.zip)

[![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20macOS-0078d4.svg)](#system-requirements)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![DeepSeek Harness Plugin](https://img.shields.io/badge/Plugin-DSH%20Desktop-blue.svg)](#installation)

<br/>

<p align="center">
  <img src="./docs/preview.png" width="370" alt="Translucent floating chat window pinned above another application" />
  &emsp;
  <img src="./docs/sessions.png" width="370" alt="Dark-themed session picker with workspace groups and search" />
</p>

<p><em>Left: a pinned conversation. Right: search and switch between sessions grouped by workspace.</em></p>

</div>

---

## Why use a floating window?

When you switch from DeepSeek Harness (DSH) Desktop to an editor or browser, the main chat window can get buried. The floating window runs in its own native process, so you can keep a reply in view or ask a follow-up even when DSH is minimized.

The plugin works with your existing DSH sessions. You can read earlier messages, attach images, start a session, or switch conversations. When you want more room, one click opens the same conversation in the main window.

## Features

- **Window controls.** Drag the title bar to move the window or drag a corner to resize it. Use the title bar to start a session, pin or unpin the window, clear the cache, minimize, or close. The window remembers its opacity and can restore its size and position. You can also enable `Esc` to close it.
- **Session switching.** Open the session picker in the upper-left corner to search your history and switch conversations. Use the **Main window (主窗口)** button to continue the current session in DSH Desktop.
- **Images and streaming replies.** Drop, paste, or select up to four images to attach to a message. Images appear in the transcript as replies stream in. Long reasoning and tool-call sections collapse to a single line.
- **Appearance.** Follow the DSH theme, follow the system theme, or choose light or dark mode. When following DSH, the floating window and its title bar update when you change the DSH theme. Window opacity is adjustable from 60% to 100%.
- **Cache and logs.** Check cache and log sizes in Settings. On Windows, cleanup targets seven WebView2 rendering and shader cache directories. On macOS, it clears WebKit rendering caches. Both versions preserve cookies and local storage.

## System requirements

| Platform | Supported system | Runtime |
| --- | --- | --- |
| Windows | Windows 10 or 11 | DSH Desktop and the WebView2 Runtime |
| macOS | macOS 12 or later on Apple Silicon (M-series Macs) | DSH Desktop and the built-in WKWebView |

Enable the DSH conversation plugin (`@deepseek-ai/dsh-client-ui-conversation`) on either platform so the floating-window button can appear beside the chat input.

## Installation

### Ask DSH to install from GitHub

Copy the line for your platform into a DSH Desktop conversation.

**Windows**

```text
Please install the DSH Floating Window plugin from the main branch of this repository: https://github.com/HeFenhenshuai/dsh-floating-window
```

**macOS (Apple Silicon)**

```text
Please install the DSH Floating Window plugin from the macos branch of this repository: https://github.com/HeFenhenshuai/dsh-floating-window/tree/macos
```

Once installation finishes, fully quit and reopen DSH Desktop. Click **Floating window (浮窗)** beside the chat input.

## Quick start

1. **Open the window.** Click **浮窗** to the right of the main chat input. The window opens with your current conversation.
2. **Switch sessions.** Click the conversation name in the upper-left corner to browse or search previous sessions. Click **＋** to start a new one.
3. **Return to DSH.** Click **主窗口** at the top of the floating window to open the same session in the main window.
4. **Adjust the window.** Open DSH Settings and select **悬浮窗** in the sidebar to set the theme, opacity, and pinning preference or check cache usage.

## Settings

Open **DSH Settings → 悬浮窗** to change these options.

| Setting | Accepted values | Default | Effect | Takes effect |
| --- | --- | --- | --- | --- |
| Appearance (`appearance`) | `dsh`, `system`, `light`, `dark` | `dsh` | Follow DSH, follow the system, or choose a fixed theme | Immediately |
| Always on top (`alwaysOnTop`) | Boolean | `true` | Keep the window above other applications | Immediately |
| Opacity (`opacity`) | 0.6–1.0 | `1.0` | Adjust the opacity of the whole window | Immediately |
| Remember size and position (`rememberGeometry`) | Boolean | `true` | Restore the previous window dimensions and screen position | Next time the window opens |
| Default size (`defaultWidth`, `defaultHeight`) | Width 320–1600 px, height 260–1600 px | Windows 620 × 900, macOS 406 × 571 | Set the initial size when saved dimensions are unavailable or disabled | Next time the window opens |
| Close with Esc (`closeOnEscape`) | Boolean | `false` | Close the floating window when it has focus and you press `Esc` | Immediately |

## FAQ

<details>
<summary><b>Why does clicking the floating-window button do nothing or show an error?</b></summary>

1. Open DSH Desktop. Opening a native window requires a renderer credential supplied by the desktop app.
2. Fully quit and reopen DSH Desktop after installing the plugin.
3. Check the folder you selected during installation. It should contain both `plugin/` and `window/`. Look for `window/dsh-floating-window.exe` on Windows or `window/dsh-floating-window.app` on macOS.

</details>

<details>
<summary><b>Why does the window open to a blank page or show “Forbidden”?</b></summary>

Open the window using **浮窗** beside the DSH Desktop chat input. DSH supplies the session credentials during launch. Double-clicking the standalone executable or app bundle skips that step.

</details>

<details>
<summary><b>Will clearing the cache sign me out or delete my conversations?</b></summary>

No. Cleanup removes WebView2 rendering caches on Windows and WebKit rendering caches on macOS. Both versions preserve sign-in information and conversation data.

</details>

## Architecture and source

The plugin has three parts: a Node.js host, a chat interface, and a native window. Each platform has its own branch.

- **Windows** uses the `main` branch. The native window is written in C# with WinForms and WebView2. The directory tree below shows the Windows layout.
- **macOS** uses the `macos` branch. The native window is written in Swift with AppKit and WKWebView. [Swift source](https://github.com/HeFenhenshuai/dsh-floating-window/tree/macos/window/src) · [Build script](https://github.com/HeFenhenshuai/dsh-floating-window/blob/macos/window/build.sh)

```text
dsh-floating-window/
├── plugin/
│   ├── host.js                  # Handles routes, authentication, and native window launch
│   ├── client.js                # Adds the chat input button and settings panel
│   └── page/float.html          # Streaming chat, attachments, and session picker
├── window/
│   ├── dsh-floating-window.exe  # Prebuilt Windows executable
│   └── src/FloatWindow.cs       # Native window implementation (C# 5, WinForms, WebView2)
└── docs/
    ├── preview.png              # Floating conversation in dark mode
    └── sessions.png             # Session picker and search
```

## Credits and license

- **Design inspiration.** The Doubao (豆包) desktop app inspired the frameless, always-on-top interaction, quick session switching, and one-click return to the main window.
- **Upstream project.** DSH Floating Window grew out of [dsh-float-chat](https://github.com/cyh3436332528/dsh-float-chat) by [@cyh3436332528](https://github.com/cyh3436332528).
- Released under the [MIT License](./LICENSE).
