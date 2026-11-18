// Cache and log housekeeping, shared by the window's own button and the
// settings page (which asks the Host half; the two agree on the same folders).
//
// What is deleted is only WebKit's rendering cache: WebKit regenerates it on the
// next request, and it holds no login state. Cookies, Local Storage and the
// window's own state files are never touched — a clean must never log the user
// out or lose the last session id.
//
// A clean issued while the window runs cannot delete files WebKit holds open, so
// it leaves `clean-pending.txt` behind and the window finishes the job when it
// closes (or on the next start, before the web view exists).

import Foundation

struct CleanSummary {
    let freedBytes: Int64
    let lockedParts: Int
    let rotatedLog: Bool

    /// One line the settings page and the page's toast can show as-is.
    var text: String {
        if freedBytes <= 0 && !rotatedLog {
            return lockedParts > 0 ? "缓存正被浮窗占用，关闭窗口后自动清理" : "没有需要清理的内容"
        }
        var parts = ["已清理 \(ByteText.mb(freedBytes))"]
        if rotatedLog { parts.append("日志已轮转") }
        if lockedParts > 0 { parts.append("另有 \(lockedParts) 项将在关闭窗口后清理") }
        return parts.joined(separator: "，")
    }
}

enum ByteText {
    static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
    }
}

enum CacheMaintenance {
    /// Bytes in a folder tree; a missing folder counts as zero.
    static func folderBytes(_ url: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    static func cacheBytes() -> Int64 {
        Paths.cacheRoots.reduce(0) { $0 + folderBytes($1) }
    }

    /// Delete the cache folders, rotate an oversized log, and remember what the
    /// running browser still holds.
    static func clean() -> CleanSummary {
        let fileManager = FileManager.default
        var freed: Int64 = 0
        var locked = 0
        for root in Paths.cacheRoots {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            let size = folderBytes(root)
            do {
                try fileManager.removeItem(at: root)
                freed += size
            } catch {
                locked += 1
            }
        }
        var rotated = false
        if Log.size() >= Log.rotateBytes {
            Log.rotateIfHuge()
            rotated = true
        }
        writePendingMarker(locked > 0)
        Log.write("clean: freed=\(freed) locked=\(locked) rotated=\(rotated)")
        return CleanSummary(freedBytes: freed, lockedParts: locked, rotatedLog: rotated)
    }

    static func writePendingMarker(_ pending: Bool) {
        let marker = Paths.pendingCleanMarker
        if pending {
            try? Data("pending".utf8).write(to: marker)
        } else {
            try? FileManager.default.removeItem(at: marker)
        }
    }

    /// Run at start (before WebKit exists) and after the window closed.
    static func finishPendingClean() {
        guard FileManager.default.fileExists(atPath: Paths.pendingCleanMarker.path) else { return }
        let summary = clean()
        Log.write("pending clean: \(summary.text)")
    }
}
