// The window's own preferences. The shapes and defaults mirror
// `SETTINGS_DEFAULTS` in plugin/host.js:
// the 悬浮窗 settings page writes this JSON, the window process reads it once a
// second, and a broken or half-written file always falls back to defaults.

import Foundation

struct WindowSettings {
    var appearance = "dsh"          // dsh | system | light | dark
    var alwaysOnTop = true
    var rememberGeometry = true
    var opacity = 1.0               // 0.6 – 1.0
    var defaultWidth = 406
    var defaultHeight = 571
    var ephemeralByDefault = false  // retired key kept for schema compatibility
    var showSessionTitle = true
    var closeOnEscape = false

    /// Read the file; anything missing, malformed or out of range becomes the
    /// default for that key alone.
    static func load(from url: URL) -> WindowSettings {
        var settings = WindowSettings()
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return settings
        }
        if let appearance = raw["appearance"] as? String {
            let wanted = appearance == "auto" ? "dsh" : appearance
            if ["dsh", "system", "light", "dark"].contains(wanted) { settings.appearance = wanted }
        }
        settings.alwaysOnTop = raw["alwaysOnTop"] as? Bool ?? settings.alwaysOnTop
        settings.rememberGeometry = raw["rememberGeometry"] as? Bool ?? settings.rememberGeometry
        settings.ephemeralByDefault = raw["ephemeralByDefault"] as? Bool ?? settings.ephemeralByDefault
        settings.showSessionTitle = raw["showSessionTitle"] as? Bool ?? settings.showSessionTitle
        settings.closeOnEscape = raw["closeOnEscape"] as? Bool ?? settings.closeOnEscape
        if let opacity = raw["opacity"] as? Double { settings.opacity = min(1, max(0.6, opacity)) }
        if let width = raw["defaultWidth"] as? Double { settings.defaultWidth = Int(min(1600, max(320, width)).rounded()) }
        if let height = raw["defaultHeight"] as? Double { settings.defaultHeight = Int(min(1600, max(260, height)).rounded()) }
        return settings
    }

    /// File modification date, so the one-second poll reads the disk only when
    /// the settings page actually wrote something.
    static func stamp(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }
}
