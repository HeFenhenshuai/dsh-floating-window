// The window's own controls, living in the native title bar (trailing side).
//
// macOS already owns the left side of the bar — close / minimize / zoom traffic
// lights, drag, double-click zoom and resizing from any edge all come from the
// system, so this half only adds what DSH needs on top of a title: a new
// conversation, the always-on-top pin, and the cache clean-up. Icons are SF
// Symbols drawn in the palette's tint, with the same hover language as the rest
// of the window.

import AppKit

final class HeaderControls: NSView {
    private let newButton = TitlebarHoverButton()
    private let pinButton = TitlebarHoverButton()
    private let cleanButton = TitlebarHoverButton()
    private let progress = NSProgressIndicator()

    var onNewChat: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onClean: (() -> Void)?

    private var palette: Palette

    init(palette: Palette, pinned: Bool) {
        self.palette = palette
        super.init(frame: NSRect(x: 0, y: 0, width: 106, height: 28))
        wantsLayer = true
        layer?.masksToBounds = false

        configure(newButton, symbol: "plus", tooltip: "新对话（继承当前会话的上下文）", action: #selector(newChatTapped))
        configure(pinButton, symbol: pinned ? "pin.fill" : "pin", tooltip: "始终置顶：开 / 关", action: #selector(pinTapped))
        configure(cleanButton, symbol: "trash", tooltip: "清理浏览器缓存与日志", action: #selector(cleanTapped))

        // ＋ sits closest to the page, the destructive one furthest: the same
        // ordering of the original header, read left to right.
        let buttons = [newButton, pinButton, cleanButton]
        var x = 4.0
        for button in buttons {
            button.frame = NSRect(x: x, y: 3, width: 30, height: 22)
            addSubview(button)
            x += 33
        }
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.frame = NSRect(x: 4, y: 6, width: 16, height: 16)
        addSubview(progress)
        applyTints(pinned: pinned)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 106, height: 28) }

    private func configure(_ button: TitlebarHoverButton, symbol: String, tooltip: String, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = action
        button.toolTip = tooltip
        button.setButtonType(.momentaryChange)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            button.image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        }
    }

    /// Repaint every tint after a palette or pin change.
    func applyTints(pinned: Bool) {
        newButton.contentTintColor = palette.buttonText
        cleanButton.contentTintColor = palette.dimText
        pinButton.contentTintColor = pinned ? palette.accent : palette.dimText
        newButton.hoverFill = palette.layerFill.withAlphaComponent(0.85)
        pinButton.hoverFill = palette.layerFill.withAlphaComponent(0.85)
        cleanButton.hoverFill = palette.layerFill.withAlphaComponent(0.85)
        newButton.needsDisplay = true
        pinButton.needsDisplay = true
        cleanButton.needsDisplay = true
    }

    func setPinned(_ pinned: Bool) {
        pinButton.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin",
                                  accessibilityDescription: "始终置顶")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        applyTints(pinned: pinned)
    }

    func setPalette(_ palette: Palette, pinned: Bool) {
        self.palette = palette
        applyTints(pinned: pinned)
    }

    /// A short red flash: this is the only control that deletes anything.
    private func flashDanger() {
        guard let danger = palette.danger.copy() as? NSColor else { return }
        cleanButton.contentTintColor = danger
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            self.cleanButton.contentTintColor = self.palette.dimText
        }
    }

    func setCleaning(_ cleaning: Bool) {
        if cleaning { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        newButton.isHidden = cleaning
    }

    @objc private func newChatTapped() { onNewChat?() }
    @objc private func pinTapped() { onTogglePin?() }
    @objc private func cleanTapped() {
        flashDanger()
        onClean?()
    }
}

/// A borderless symbol button with a rounded hover fill, matching the page's
/// own icon buttons instead of AppKit's default bezel.
final class TitlebarHoverButton: NSButton {
    var hoverFill: NSColor = .clear
    private var hovering = false
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            hoverFill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}
