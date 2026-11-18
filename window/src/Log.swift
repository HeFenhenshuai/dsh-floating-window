// dsh-floating-window — macOS native shell.
//
// Small, dependency-free helpers shared by every other file: where the window
// keeps its state, and the append-only log that makes a broken window
// diagnosable from the outside (`window-log.txt`, rotated at 18 MB, three files).

import Foundation

enum Paths {
    /// Application Support/dsh-floating-window: settings, geometry and the log.
    /// Deliberately outside the plugin directory so a plugin update never wipes
    /// the user's window preferences.
    static let stateDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = base.appendingPathComponent("dsh-floating-window", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var settingsFile: URL { stateDirectory.appendingPathComponent("float-settings.json") }
    static var stateFile: URL { stateDirectory.appendingPathComponent("window-state.txt") }
    static var logFile: URL { stateDirectory.appendingPathComponent("window-log.txt") }
    static var pendingCleanMarker: URL { stateDirectory.appendingPathComponent("clean-pending.txt") }

    /// The window's WebKit cache folders (see CacheMaintenance): everything under
    /// these is regenerated on demand and holds no login state.
    static var cacheRoots: [URL] {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches", isDirectory: true)
        return [caches.appendingPathComponent("com.dsh.floating-window", isDirectory: true)]
    }
}

/// Append-only diagnostics. Every entry is best effort: a log that cannot be
/// written must never take the window down with it.
enum Log {
    private static let queue = DispatchQueue(label: "com.dsh.floating-window.log")
    /// Keep in step with host.js's LOG_CAP_BYTES (18 MB).
    static let rotateBytes: Int64 = 18 * 1024 * 1024

    static func rotateIfHuge() {
        let path = Paths.logFile.path
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64,
              size >= rotateBytes else { return }
        let folder = Paths.stateDirectory
        let oldest = folder.appendingPathComponent("window-log.2.txt")
        let previous = folder.appendingPathComponent("window-log.1.txt")
        try? FileManager.default.removeItem(at: oldest)
        if FileManager.default.fileExists(atPath: previous.path) {
            try? FileManager.default.moveItem(at: previous, to: oldest)
        }
        try? FileManager.default.moveItem(at: Paths.logFile, to: previous)
    }

    static func write(_ message: String) {
        let stamp = DateFormatter.dshClock.string(from: Date())
        let line = "\(stamp) \(message)\n"
        queue.async {
            let path = Paths.logFile.path
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            defer { try? handle.close() }
            if (try? handle.seekToEnd()) != nil, let data = line.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
    }

    static func size() -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: Paths.logFile.path)[.size] as? Int64) ?? 0
    }
}

extension DateFormatter {
    /// `HH:mm:ss`, the clock every log line carries.
    static let dshClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

extension String {
    /// Minimal JSON string literal for the few one-line messages this process
    /// builds by hand (tool output shown in the page, cache summaries).
    var dshJSONLiteral: String {
        var out = ""
        for character in self {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(character)
            }
        }
        return "\"\(out)\""
    }
}
