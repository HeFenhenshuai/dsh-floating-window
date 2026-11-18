# macOS 原生外壳（AppKit + WKWebView）

插件的第三层：一个独立进程，把 `plugin/page/float.html` 装进一个真正置顶的 macOS 窗口。
不是 Electron 套壳，也不是 WebView 的临时代替品——就是 `NSWindow` + `WKWebView`。

```text
window/
├── dsh-floating-window.app/     # 预编译产物（host.js 直接 spawn Contents/MacOS/dsh-floating-window）
├── src/
│   ├── main.swift               # 入口：参数、日志、NSApplication
│   ├── LaunchOptions.swift      # --dsh-auth-url / --dsh-page-url / --dsh-title / --dsh-header-*
│   ├── AppDelegate.swift        # 窗口、WKWebView、轮询、关闭流程、几何记忆
│   ├── Bridge.swift             # document-start 注入：chrome.webview 兼容层、fetch/EventSource 能力头、顶部让位
│   ├── Theme.swift              # 深/浅调色板 + DSH ui-theme 解析（读取 profile 的 cordis.patch.yml）
│   ├── WindowSettings.swift     # float-settings.json 读取与钳制
│   ├── CacheMaintenance.swift   # 只清 WebKit 纯缓存 + 日志轮转 + 关窗后补清
│   ├── HeaderControls.swift     # 标题栏右侧三颗按钮（新建 / 置顶 / 清理）
│   ├── FloatWindow.swift        # NSWindow：置顶层级、多桌面、全屏悬浮
│   └── Log.swift                # window-log.txt（18MB 轮转）+ 状态目录
├── build.sh                     # 编译 + 打 ad-hoc 签名
├── test.sh                      # 纯逻辑自检（参数解析 / 设置钳制 / 主题 / 缓存清理，无需窗口）
├── make-icon.swift / make-icon.sh
└── icon.icns
```

## 编译

```bash
./build.sh                 # 当前架构
./build.sh --universal     # arm64 + x86_64（lipo 合并）
```

需要 Xcode Command Line Tools（`xcode-select --install`）。产物是 `dsh-floating-window.app`，
`plugin/host.js` 通过 `spawn` 直接运行 `Contents/MacOS/dsh-floating-window`（不是 `open`），
这样宿主能拿到 pid，插件卸载/DSH 退出时可以结束窗口进程。

## 运行时数据

| 内容 | 路径 |
| :--- | :--- |
| 设置 / 窗口位置 / 日志 | `~/Library/Application Support/dsh-floating-window/` |
| WebKit 网络缓存（清理对象） | `~/Library/Caches/com.dsh.floating-window/` |
| Cookie / LocalStorage（永不清理） | `~/Library/WebKit/com.dsh.floating-window/WebsiteData/` |

Bundle id 固定为 `com.dsh.floating-window`：它同时决定上面两个目录，`plugin/host.js` 里的
`BUNDLE_ID` 与它保持一致（缓存统计与清理要对得上）。改 bundle id 必须两处一起改。

## 窗口行为要点

| 行为 | 实现 |
| :--- | :--- |
| 置顶 | `window.level = .floating`，同时 `canJoinAllSpaces` + `fullScreenAuxiliary`：DSH 全屏或切桌面时仍在 |
| 拖拽标题栏 | `fullSizeContentView` 让 WebView 盖住了标题栏拖拽区，用本地事件监视器在红绿灯与右侧按钮之间补回 `performDrag` |
| 页面顶部让位 | 标题栏高度运行时测量（macOS 26 上是 32pt），注入 `body { padding-top }`，页面内容不会被红绿灯压住 |
| 页面桥 | 注入与 `window.chrome.webview` 同名的兼容层（走 `webkit.messageHandlers`），页面代码不用改 |
| 渲染器能力头 | WKWebView 没有全局请求拦截，用注入的 `fetch` / `EventSource` 包装补头；SSE 用 fetch 流式 shim |
| 关闭 | `windowShouldClose` 先跑页面清理脚本，超时 1.5s；关窗后补清上次没删掉的缓存 |
| 外观 | 读 `~/.dsh/profiles/*/cordis.patch.yml` 的 `ui-theme`，文件变了才重读；DSH 里换深浅色，窗口当场跟着换 |

## 排错

- 窗口日志：`~/Library/Application Support/dsh-floating-window/window-log.txt`（导航失败、鉴权、主题切换、页面报错都会记）。
- 命令行手工打开（需要宿主签发的 token URL）：

```bash
./dsh-floating-window.app/Contents/MacOS/dsh-floating-window \
  --dsh-auth-url='http://127.0.0.1:<port>/?token=<token>' \
  --dsh-page-url='http://127.0.0.1:<port>/dsh-floating-window/page/?theme=dark'
```

直接双击 `.app` 会白屏：页面必须靠宿主实时签发的 Token URL 换到浏览器信任 Cookie。
