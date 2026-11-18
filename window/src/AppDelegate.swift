// Wiring: build the window, hand it the page, keep its appearance and its
// preferences in step with DSH, and run the close path.
//
// The window is a separate process on purpose. The DSH renderer is sandboxed and
// cannot open native windows, and this one has to keep floating over other
// applications while the main DSH window is behind, minimised or hidden.

import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private let options: LaunchOptions
    private var window: FloatWindow!
    private var webView: WKWebView!
    private var controls: HeaderControls!

    private var settings = WindowSettings()
    private var settingsStamp: Date?
    private var palette: Palette = .dark
    private var lightTheme = false
    private var pollTimer: Timer?
    private var escMonitor: Any?
    private var titlebarMonitor: Any?
    private var titlebarInset: CGFloat = 0
    private var titleAccessory: NSTitlebarAccessoryViewController?
    /** Last seen modification date of the Host's show-request marker. */
    private var lastShowRequest: Date?
    private let titleLabel = NSTextField(labelWithString: "悬浮窗")
    private var statusLabel: NSTextField?
    private var closingAfterCleanup = false
    private var pageCleanupStarted = false
    private var didLoadPage = false

    init(options: LaunchOptions) {
        self.options = options
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launch page=\(options.pageURL?.absoluteString ?? "nil") header=\(options.headerName ?? "-")")
        guard let pageURL = options.pageURL else {
            Log.write("no --dsh-page-url; nothing to show")
            NSApp.terminate(nil)
            return
        }

        buildMenu()
        settings = WindowSettings.load(from: Paths.settingsFile)
        settingsStamp = WindowSettings.stamp(of: Paths.settingsFile)
        lightTheme = DshTheme.resolveLight(settings, hint: options.themeHint)
        palette = lightTheme ? .light : .dark

        createWindow()
        attachWebView()
        beginSession(pageURL: pageURL)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Termination is ordered by the close path instead (windowWillClose): the
        // pending cache clean needs a moment after the web view's browser
        // processes exit, and quitting the moment the window disappears would cut
        // it short.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveGeometry()
    }

    // MARK: - Menu

    /// A menu bar is not decoration here: without an Edit menu, ⌘C / ⌘V / ⌘A
    /// (and ⌘Z in the composer) do not reach the web view at all.
    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 DSH 悬浮窗", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 DSH 悬浮窗", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "隐藏其他应用", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        appMenu.items.last?.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 DSH 悬浮窗", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Window

    private func createWindow() {
        let frame = initialFrame()
        window = FloatWindow(contentRect: frame,
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered,
                             defer: false)
        window.title = options.title
        window.titlebarAppearsTransparent = true
        // The native title is centered across the whole bar and would draw over
        // the trailing buttons, so this window draws its own title instead (and
        // keeps `window.title` for Mission Control, the Dock and ⌘-Tab).
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 320, height: 260)
        window.appearance = NSAppearance(named: lightTheme ? .aqua : .darkAqua)
        window.backgroundColor = palette.pageFill
        window.hasShadow = true
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.applyPin(settings.alwaysOnTop)

        controls = HeaderControls(palette: palette, pinned: settings.alwaysOnTop)
        controls.onNewChat = { [weak self] in self?.startNewConversation() }
        controls.onTogglePin = { [weak self] in self?.togglePin() }
        controls.onClean = { [weak self] in self?.cleanFromWindow() }
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = controls
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)

        // The title sits right after the traffic lights,
        // and truncates instead of pushing into the buttons.
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = palette.captionText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 28))
        holder.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -4),
            titleLabel.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        let titleAccessory = NSTitlebarAccessoryViewController()
        titleAccessory.view = holder
        titleAccessory.layoutAttribute = .leading
        window.addTitlebarAccessoryViewController(titleAccessory)
        self.titleAccessory = titleAccessory
        updateTitleWidth()
        window.layoutIfNeeded()
    }

    private func attachWebView() {
        // The title bar height varies with the OS: measure it instead of assuming
        // 28pt, so the page always starts exactly below the traffic lights.
        let inset = max(0, window.frame.height - window.contentLayoutRect.height)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(self, name: Bridge.handlerName)
        configuration.userContentController.addUserScript(Bridge.userScript(options: options, topInset: inset))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.appearance = window.appearance
        if #available(macOS 12.0, *) { webView.underPageBackgroundColor = palette.pageFill }
        webView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(webView)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                webView.topAnchor.constraint(equalTo: content.topAnchor),
                webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        Log.write("web view attached; titlebar inset=\(inset)")
        self.webView = webView
        titlebarInset = inset
        installTitlebarMonitor()
    }

    private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(webView)
        fadeIn()
        startPolling()
    }

    /// Open at 70% of the target opacity and ease up, so the first frame does not
    /// pop (and a slow first paint is less visible).
    private func fadeIn() {
        let target = CGFloat(settings.opacity)
        window.alphaValue = max(0.35, target * 0.7)
        let started = Date()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let next = self.window.alphaValue + (target - self.window.alphaValue) * 0.28
            if abs(target - next) < 0.012 || Date().timeIntervalSince(started) > 0.6 {
                self.window.alphaValue = target
                timer.invalidate()
                return
            }
            self.window.alphaValue = next
        }
    }

    // MARK: - Navigation

    private func beginSession(pageURL: URL) {
        showWindow()
        if let authURL = options.authURL {
            var request = URLRequest(url: authURL)
            applyHeader(to: &request)
            webView.load(request)
            Log.write("navigating auth url")
            // Whatever happens with the token URL (redirect, 404, a slow Host),
            // the page load must not wait forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.loadPage(pageURL)
            }
        } else {
            loadPage(pageURL)
        }
    }

    private func loadPage(_ pageURL: URL) {
        guard !didLoadPage else { return }
        didLoadPage = true
        var request = URLRequest(url: pageURL)
        applyHeader(to: &request)
        webView.load(request)
        Log.write("navigating page url")
    }

    private func applyHeader(to request: inout URLRequest) {
        guard let name = options.headerName, let value = options.headerValue,
              !name.isEmpty, !value.isEmpty else { return }
        request.setValue(value, forHTTPHeaderField: name)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !didLoadPage, let pageURL = options.pageURL {
            loadPage(pageURL)
            return
        }
        Log.write("loaded \(webView.url?.absoluteString ?? "-")")
        hideStatus()
        window.makeFirstResponder(webView)
        pushTheme()
        pushSettings()
        webView.evaluateJavaScript("(function(){var i=document.getElementById('input'); if (i) i.focus(); return true;})()")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.write("navigation failed: \(error.localizedDescription) url=\(webView.url?.absoluteString ?? "-")")
        if !didLoadPage, let pageURL = options.pageURL {
            loadPage(pageURL)
            return
        }
        showStatus("页面加载失败：\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log.write("provisional navigation failed: \(error.localizedDescription) url=\(webView.url?.absoluteString ?? "-")")
        if !didLoadPage, let pageURL = options.pageURL {
            loadPage(pageURL)
            return
        }
        showStatus("页面加载失败：\(error.localizedDescription)")
    }

    /// A one-line strip over the page when it cannot be loaded at all: a blank
    /// dark window would say nothing, and the log is not where a user looks.
    private func showStatus(_ text: String) {
        if statusLabel == nil {
            let label = NSTextField(labelWithString: "")
            label.font = NSFont.systemFont(ofSize: 12)
            label.textColor = palette.danger
            label.backgroundColor = palette.layerFill
            label.drawsBackground = true
            label.isBezeled = false
            label.isEditable = false
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            guard let content = window.contentView else { return }
            content.addSubview(label)
            let inset = max(0, window.frame.height - window.contentLayoutRect.height)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                label.topAnchor.constraint(equalTo: content.topAnchor, constant: inset + 8),
                label.heightAnchor.constraint(equalToConstant: 22),
            ])
            statusLabel = label
        }
        statusLabel?.stringValue = text
        statusLabel?.isHidden = false
    }

    private func hideStatus() {
        statusLabel?.isHidden = true
    }

    // MARK: - Settings / appearance polling

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        installEscapeMonitor()
    }

    /**
     * The title bar's drag region, taken back explicitly.
     *
     * A `fullSizeContentView` window puts the browser over the title bar, and on
     * this OS the frame's own title-bar view swallows a press in that strip
     * without starting a drag (the traffic lights still work, because they are
     * controls). A local monitor runs before that dispatch, so a press in the
     * strip — between the traffic lights and our own controls — becomes a real
     * window drag, and a double click honours the system's title-bar action.
     */
    private func installTitlebarMonitor() {
        guard titlebarMonitor == nil else { return }
        titlebarMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let point = event.locationInWindow
            guard point.y >= window.frame.height - self.titlebarInset - 1 else { return event }
            // Leave the traffic lights (leading) and our own buttons (trailing) to
            // AppKit: they are controls and must receive their own clicks.
            if point.x < 84 { return event }
            if point.x > window.frame.width - 132 { return event }
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                switch action {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
                return nil
            }
            window.performDrag(with: event)
            return nil
        }
    }

    private func installEscapeMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.settings.closeOnEscape,
                  self.window.isKeyWindow, !self.closingAfterCleanup else { return event }
            self.window.performClose(nil)
            return nil
        }
    }

    private func poll() {
        pollSettings()
        pollTheme()
        pollTitle()
        pollShowRequest()
    }

    /**
     * The Host touches `show-request` when the user asks for the window again
     * while it is already open (the composer button, a second launch attempt).
     * Answering it is what the window is for: come to the front instead of
     * silently ignoring the request.
     */
    private func pollShowRequest() {
        let stamp = WindowSettings.stamp(of: Paths.showRequestFile)
        guard stamp != lastShowRequest else { return }
        lastShowRequest = stamp
        guard stamp != nil else { return }
        Log.write("raise request: window brought forward")
        bringToFront()
    }

    /// Show the window and make it the frontmost application's key window.
    private func bringToFront() {
        if !window.isVisible { window.makeKeyAndOrderFront(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(webView)
    }

    /// The settings page writes `float-settings.json` through the Host half; the
    /// window picks a change up within a second, no IPC involved.
    private func pollSettings() {
        let stamp = WindowSettings.stamp(of: Paths.settingsFile)
        guard stamp != settingsStamp else { return }
        settingsStamp = stamp
        settings = WindowSettings.load(from: Paths.settingsFile)
        Log.write("settings changed: appearance=\(settings.appearance) pin=\(settings.alwaysOnTop) opacity=\(settings.opacity)")
        applyLiveSettings()
        syncTheme(reason: "settings changed")
        pushSettings()
    }

    /// DSH's own appearance lives in the profile's patch file; re-read it when it
    /// moves, so switching light/dark in DSH repaints this window immediately.
    private func pollTheme() {
        syncTheme(reason: "poll")
    }

    private func pollTitle() {
        let pageTitle = webView.title ?? ""
        let wanted = settings.showSessionTitle && !pageTitle.isEmpty ? pageTitle : options.title
        if window.title != wanted { window.title = wanted }
        if titleLabel.stringValue != wanted { titleLabel.stringValue = wanted }
    }

    /// The title accessory is a fixed-width view in the title bar, so it has to be
    /// resized by hand when the window's width changes.
    private func updateTitleWidth() {
        guard window != nil, let titleAccessory else { return }
        let trailing = controls?.frame.width ?? 106
        let width = max(48, window.frame.width - 78 - trailing - 8)
        titleAccessory.view.frame.size = NSSize(width: width, height: 28)
    }

    func windowDidResize(_ notification: Notification) {
        updateTitleWidth()
    }

    private func syncTheme(reason: String) {
        let next = DshTheme.resolveLight(settings, hint: options.themeHint)
        guard next != lightTheme || reason == "startup" else { return }
        applyTheme(light: next, reason: reason)
    }

    private func applyTheme(light: Bool, reason: String) {
        lightTheme = light
        palette = light ? .light : .dark
        Log.write("theme -> \(light ? "light" : "dark") (\(reason))")
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        if webView != nil { webView.appearance = window.appearance }
        window.backgroundColor = palette.pageFill
        if #available(macOS 12.0, *), webView != nil { webView.underPageBackgroundColor = palette.pageFill }
        controls.setPalette(palette, pinned: settings.alwaysOnTop)
        titleLabel.textColor = palette.captionText
        window.invalidateShadow()
        pushTheme()
    }

    private func applyLiveSettings() {
        window.applyPin(settings.alwaysOnTop)
        window.alphaValue = CGFloat(settings.opacity)
        controls.setPinned(settings.alwaysOnTop)
        pollTitle()
    }

    // MARK: - Page messages

    private func pushTheme() {
        push("{\"type\":\"theme\",\"theme\":\"\(lightTheme ? "light" : "dark")\"}")
    }

    private func pushSettings() {
        let json = "{\"type\":\"settings\",\"settings\":{"
            + "\"ephemeralByDefault\":\(settings.ephemeralByDefault ? "true" : "false"),"
            + "\"showSessionTitle\":\(settings.showSessionTitle ? "true" : "false"),"
            + "\"closeOnEscape\":\(settings.closeOnEscape ? "true" : "false")}}"
        push(json)
    }

    private func pushStats() {
        push("{\"type\":\"cache-stats\",\"cacheBytes\":\(CacheMaintenance.cacheBytes()),\"logBytes\":\(Log.size())}")
    }

    /// Hand one JSON frame to the page (it listens through the bridge shim).
    private func push(_ json: String) {
        guard webView != nil else { return }
        webView.evaluateJavaScript("window.__DSH_FLOAT_NATIVE_ONMESSAGE__ && window.__DSH_FLOAT_NATIVE_ONMESSAGE__(\(json));")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Bridge.handlerName else { return }
        let body = message.body
        guard let payload = body as? [String: Any], let type = payload["type"] as? String else { return }
        switch type {
        case "log":
            if let text = payload["text"] as? String { Log.write("page: \(text)") }
        case "theme-request":
            pushTheme()
            pushSettings()
        case "theme-observed":
            if let theme = payload["theme"] as? String, theme == "light" || theme == "dark" {
                applyTheme(light: theme == "light", reason: "page (dsh theme)")
            }
        case "close-request":
            DispatchQueue.main.async { [weak self] in self?.window.performClose(nil) }
        case "raise-main-window":
            DispatchQueue.main.async { [weak self] in self?.raiseMainApp() }
        case "clean-request":
            DispatchQueue.main.async { [weak self] in self?.cleanFromWindow() }
        case "stats-request":
            DispatchQueue.main.async { [weak self] in self?.pushStats() }
        default:
            Log.write("page message: \(payload)")
        }
    }

    // MARK: - Commands

    /**
     * Bring the DSH app itself to the front. A request that can only be answered
     * in the main window (an approval, an `ask_user_question`) is useless if the
     * user has to hunt for that window behind everything else; the renderer
     * cannot activate the OS app, but this process can.
     */
    private func raiseMainApp() {
        guard let path = options.parentApp, !path.isEmpty else {
            Log.write("raise main: no --dsh-parent-app given")
            return
        }
        let target = URL(fileURLWithPath: path).standardizedFileURL
        // `NSRunningApplication.activate` is silently refused for an app that is
        // not itself frontmost (macOS 14+), so this goes through the same call
        // `open -a` uses: it re-activates the running instance.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        Log.write("raising main window: \(target.lastPathComponent)")
        NSWorkspace.shared.openApplication(at: target, configuration: configuration) { app, error in
            if let error {
                Log.write("raise main failed: \(error.localizedDescription)")
            } else {
                Log.write("raised main: \(app?.localizedName ?? target.lastPathComponent)")
            }
        }
    }

    /// Clicking the Dock icon of a running window brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { bringToFront() }
        return true
    }

    private func startNewConversation() {
        guard webView != nil else { return }
        webView.evaluateJavaScript("window.__DSH_FLOAT_NEW_THREAD__ ? window.__DSH_FLOAT_NEW_THREAD__() : null")
        window.makeFirstResponder(webView)
    }

    private func togglePin() {
        let pinned = !settings.alwaysOnTop
        // A header click is a live preference: mirror it into the settings file so
        // the settings page and the next launch agree with what the window shows.
        settings.alwaysOnTop = pinned
        saveSettings(pinned: pinned)
        applyLiveSettings()
        Log.write("pin -> \(pinned ? "on" : "off")")
    }

    private func saveSettings(pinned: Bool) {
        // Write the whole object (not just the pin) so the file is complete even
        // when the settings page was never opened: the Host half normalizes it
        // anyway, and the next launch reads every key from here.
        let payload: [String: Any] = [
            "appearance": settings.appearance,
            "alwaysOnTop": pinned,
            "rememberGeometry": settings.rememberGeometry,
            "opacity": settings.opacity,
            "defaultWidth": settings.defaultWidth,
            "defaultHeight": settings.defaultHeight,
            "ephemeralByDefault": settings.ephemeralByDefault,
            "showSessionTitle": settings.showSessionTitle,
            "closeOnEscape": settings.closeOnEscape,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        try? data.write(to: Paths.settingsFile, options: .atomic)
        settingsStamp = WindowSettings.stamp(of: Paths.settingsFile)
    }

    private func cleanFromWindow() {
        let summary = CacheMaintenance.clean()
        Log.write("clean: \(summary.text)")
        push("{\"type\":\"clean-result\",\"text\":\(summary.text.dshJSONLiteral)}")
    }

    // MARK: - Geometry

    private func initialFrame() -> NSRect {
        var width = CGFloat(settings.defaultWidth)
        var height = CGFloat(settings.defaultHeight)
        var origin: NSPoint?
        if settings.rememberGeometry, let data = try? Data(contentsOf: Paths.stateFile),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
           let x = raw["x"], let y = raw["y"], let w = raw["width"], let h = raw["height"], w > 0, h > 0 {
            width = max(320, CGFloat(w))
            height = max(260, CGFloat(h))
            origin = NSPoint(x: x, y: y)
        }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: origin?.x ?? 0, y: origin?.y ?? 0, width: width, height: height)
        if origin == nil || !isOnSomeScreen(frame) {
            return NSRect(x: screen.maxX - width - 24,
                          y: screen.minY + max(0, (screen.height - height) / 2),
                          width: width,
                          height: height)
        }
        return frame
    }

    /// True when a meaningful part of the window sits inside a connected screen.
    private func isOnSomeScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { screen in
            let area = screen.visibleFrame
            return frame.maxX > area.minX + 60 && frame.minX < area.maxX - 40
                && frame.maxY > area.minY + 40 && frame.minY < area.maxY - 40
        }
    }

    private func saveGeometry() {
        guard settings.rememberGeometry, window != nil, window.isVisible else { return }
        let frame = window.frame
        let payload: [String: Double] = [
            "x": Double(frame.origin.x), "y": Double(frame.origin.y),
            "width": Double(frame.width), "height": Double(frame.height),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        try? data.write(to: Paths.stateFile, options: .atomic)
    }

    // MARK: - Close path

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closingAfterCleanup { return true }
        closingAfterCleanup = true
        Log.write("close requested")
        saveGeometry()
        runPageCleanup { [weak self] in
            self?.window.close()
        }
        return false
    }

    /// Give the page one chance to run its own cleanup; the window does not wait
    /// on a page that is gone (browser crash, navigation in flight).
    private func runPageCleanup(then completion: @escaping () -> Void) {
        guard webView != nil, !pageCleanupStarted else {
            DispatchQueue.main.async { completion() }
            return
        }
        pageCleanupStarted = true
        var finished = false
        let finish = {
            if finished { return }
            finished = true
            DispatchQueue.main.async { completion() }
        }
        webView.evaluateJavaScript("(function(){ return (window.__DSH_FLOAT_CLEANUP__ ? window.__DSH_FLOAT_CLEANUP__() : true); })()") { _, error in
            if let error { Log.write("cleanup skipped: \(error.localizedDescription)") }
            DispatchQueue.main.async { finish() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { finish() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        Log.write("window became key")
    }

    func windowWillClose(_ notification: Notification) {
        Log.write("closed")
        pollTimer?.invalidate()
        pollTimer = nil
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
        if let titlebarMonitor { NSEvent.removeMonitor(titlebarMonitor) }
        titlebarMonitor = nil
        // The web view (and its browser processes) are gone from here on, which is
        // when a clean that could not delete locked files can finish the job.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            CacheMaintenance.finishPendingClean()
            NSApp.terminate(nil)
        }
    }
}
