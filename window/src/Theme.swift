// Appearance. Two palettes that match the page's own CSS variables, and the
// resolution order the plugin uses:
//
//   the 悬浮窗 settings page's "配色方案" first (light / dark / follow system /
//   follow DSH) → DSH's own ui-theme preference (read from the profile patch
//   file, so a change in DSH's settings reaches this window within a second) →
//   the theme= hint the Host put in the page URL → the macOS system appearance.
//
// The window itself is a normal macOS window, so "appearance" also drives
// AppKit: the native title bar, traffic lights and scrollbars come from
// NSAppearance, and the page is told separately through the bridge.

import AppKit

struct Palette {
    let pageFill: NSColor
    let layerFill: NSColor
    let captionText: NSColor
    let buttonText: NSColor
    let dimText: NSColor
    let accent: NSColor
    let danger: NSColor
    let hairline: NSColor

    static let dark = Palette(
        pageFill: NSColor(srgbRed: 15 / 255, green: 17 / 255, blue: 21 / 255, alpha: 1),
        layerFill: NSColor(srgbRed: 27 / 255, green: 27 / 255, blue: 28 / 255, alpha: 1),
        captionText: NSColor(srgbRed: 233 / 255, green: 233 / 255, blue: 236 / 255, alpha: 1),
        buttonText: NSColor(srgbRed: 170 / 255, green: 176 / 255, blue: 186 / 255, alpha: 1),
        dimText: NSColor(srgbRed: 154 / 255, green: 154 / 255, blue: 164 / 255, alpha: 1),
        accent: NSColor(srgbRed: 75 / 255, green: 139 / 255, blue: 245 / 255, alpha: 1),
        danger: NSColor(srgbRed: 229 / 255, green: 83 / 255, blue: 75 / 255, alpha: 1),
        hairline: NSColor(white: 1, alpha: 0.10))

    static let light = Palette(
        pageFill: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        layerFill: NSColor(srgbRed: 245 / 255, green: 246 / 255, blue: 247 / 255, alpha: 1),
        captionText: NSColor(srgbRed: 15 / 255, green: 17 / 255, blue: 21 / 255, alpha: 1),
        buttonText: NSColor(srgbRed: 88 / 255, green: 94 / 255, blue: 102 / 255, alpha: 1),
        dimText: NSColor(srgbRed: 110 / 255, green: 116 / 255, blue: 124 / 255, alpha: 1),
        accent: NSColor(srgbRed: 65 / 255, green: 118 / 255, blue: 230 / 255, alpha: 1),
        danger: NSColor(srgbRed: 217 / 255, green: 45 / 255, blue: 32 / 255, alpha: 1),
        hairline: NSColor(white: 0, alpha: 0.10))
}

enum DshTheme {
    /// The profile patch file DSH rewrites the moment the user changes the
    /// appearance, and the legacy fallback `~/.dsh/settings.yaml`.
    static func settingsFile() -> URL? {
        let fileManager = FileManager.default
        let dsh = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dsh", isDirectory: true)
        let profiles = dsh.appendingPathComponent("profiles", isDirectory: true)
        var best: URL?
        var newest = Date.distantPast
        if let names = try? fileManager.contentsOfDirectory(at: profiles, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for directory in names {
                let candidate = directory.appendingPathComponent("cordis.patch.yml")
                guard let text = try? String(contentsOf: candidate, encoding: .utf8) else { continue }
                guard text.contains("ui-theme") else { continue }
                let written = (try? candidate.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if best == nil || written > newest {
                    best = candidate
                    newest = written
                }
            }
        }
        if best == nil {
            let legacy = dsh.appendingPathComponent("settings.yaml")
            if fileManager.fileExists(atPath: legacy.path) { best = legacy }
        }
        return best
    }

    /// `light` / `dark` / `system` from the `ui-theme` section; nil when the file
    /// cannot be read at all.
    static func preference(at file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var headerIndent = -1
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix(while: { $0 == " " }).count
            if headerIndent < 0 {
                // Both dialects: the profile patch layer's `- id: ui-theme` and
                // the legacy settings file's `ui-theme:`.
                if trimmed == "- id: ui-theme" || trimmed == "ui-theme:" { headerIndent = indent }
                continue
            }
            if trimmed.isEmpty { continue }
            if indent <= headerIndent { return "system" }  // section ended without a preference
            if trimmed.hasPrefix("preference:") {
                let value = trimmed.dropFirst("preference:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    .lowercased()
                return value
            }
        }
        return "system"
    }

    /// macOS's own "appearance" switch (System Settings → Appearance). Uses
    /// `NSApplication.shared` rather than the `NSApp` global, so the same code can
    /// run in the offline logic test where no app object exists yet.
    static var systemUsesLight: Bool {
        let match = NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        return match == .aqua
    }

    /* ── 每秒轮询的成本控制 ──────────────────────────────────────────────
     * The window checks the appearance once a second. A full profile scan (read
     * every profile's patch file) on every tick would be wasteful, so the found
     * file and its modification date are remembered: a known file is only re-read
     * when it actually moves, and the profiles directory is scanned again at most
     * every five seconds.
     */
    private static var cachedPath: URL?
    private static var cachedStamp: Date?
    private static var cachedPreference: String?
    private static var lastScan = Date.distantPast

    static func currentPreference() -> String? {
        if let path = cachedPath {
            let stamp = (try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
            if stamp == cachedStamp { return cachedPreference }
            if let stamp {
                let preference = preference(at: path)
                cachedStamp = stamp
                cachedPreference = preference
                return preference
            }
            cachedPath = nil
        }
        guard Date().timeIntervalSince(lastScan) >= 5 else { return cachedPreference }
        lastScan = Date()
        guard let found = settingsFile() else {
            cachedPreference = nil
            return nil
        }
        cachedPath = found
        cachedStamp = (try? found.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
        cachedPreference = preference(at: found)
        return cachedPreference
    }

    /// Resolve the appearance this window should paint right now.
    static func resolveLight(_ settings: WindowSettings, hint: String?) -> Bool {
        switch settings.appearance {
        case "light": return true
        case "dark": return false
        case "system": return systemUsesLight
        default: break  // "dsh": DSH's own preference decides
        }
        if let preference = currentPreference() {
            if preference == "light" { return true }
            if preference == "dark" { return false }
            if preference == "system" { return systemUsesLight }
        }
        if let hint = hint { return hint == "light" }
        return systemUsesLight
    }
}
