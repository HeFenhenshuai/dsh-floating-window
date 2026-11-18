// Offline checks of the pure-logic halves of the macOS window: launch arguments,
// settings clamping, appearance resolution and cache maintenance. These need no
// window server and no running Host, so they run anywhere (including CI).
//
//   window-macos/test.sh
import AppKit
import Foundation

var failures = 0
func check(_ condition: Bool, _ label: String) {
    print("\(condition ? "PASS" : "FAIL") \(label)")
    if !condition { failures += 1 }
}

print("state dir:  \(Paths.stateDirectory.path)")
print("cache roots: \(Paths.cacheRoots.map(\.path))")

// --- launch arguments -------------------------------------------------------
let options = LaunchOptions.parse([
    "--dsh-auth-url=http://127.0.0.1:9/auth?token=x",
    "--dsh-page-url=http://127.0.0.1:9/dsh-floating-window/page/?parent=abc&theme=light",
    "--dsh-title=悬浮窗",
    "--dsh-header-name=x-dsh-desktop-renderer",
    "--dsh-header-value=cap-1",
])
check(options.authURL?.absoluteString.contains("token=x") == true, "auth url parsed")
check(options.pageURL?.path == "/dsh-floating-window/page", "page url parsed")
check(options.themeHint == "light", "theme hint parsed from the page url")
check(options.headerName == "x-dsh-desktop-renderer" && options.headerValue == "cap-1", "renderer header parsed")
check(options.title == "悬浮窗", "title parsed")
let minimal = LaunchOptions.parse(["--dsh-page-url=http://127.0.0.1:9/p"])
check(minimal.authURL == nil && minimal.headerName == nil, "optional arguments absent")
check(minimal.title == "悬浮窗", "default title")
let noPage = LaunchOptions.parse(["--dsh-title=x"])
check(noPage.pageURL == nil, "page url required")

// --- settings ---------------------------------------------------------------
let settingsURL = Paths.settingsFile
let original = try? Data(contentsOf: settingsURL)
try? """
{ "appearance": "auto", "alwaysOnTop": false, "opacity": 5, "defaultWidth": 10, "defaultHeight": 4000,
  "closeOnEscape": true, "showSessionTitle": false, "rememberGeometry": false, "ephemeralByDefault": true }
""".data(using: .utf8)?.write(to: settingsURL)
let parsed = WindowSettings.load(from: settingsURL)
check(parsed.appearance == "dsh", "legacy 'auto' normalizes to dsh")
check(parsed.alwaysOnTop == false, "boolean honoured")
check(parsed.opacity == 1.0, "opacity clamped to 1")
check(parsed.defaultWidth == 320, "width clamped to 320")
check(parsed.defaultHeight == 1600, "height clamped to 1600")
check(parsed.closeOnEscape && !parsed.showSessionTitle && !parsed.rememberGeometry, "flags honoured")
check(WindowSettings.stamp(of: settingsURL) != nil, "settings stamp readable")
if let original { try? original.write(to: settingsURL) } else { try? FileManager.default.removeItem(at: settingsURL) }
let broken = Paths.stateDirectory.appendingPathComponent("broken-settings.json")
try? "{ not json".data(using: .utf8)?.write(to: broken)
let fallback = WindowSettings.load(from: broken)
check(fallback.alwaysOnTop && fallback.opacity == 1.0, "broken file falls back to defaults")
try? FileManager.default.removeItem(at: broken)

// --- appearance ------------------------------------------------------------
let forcedLight = WindowSettings(appearance: "light")
check(DshTheme.resolveLight(forcedLight, hint: nil), "appearance=light wins")
let forcedDark = WindowSettings(appearance: "dark")
check(!DshTheme.resolveLight(forcedDark, hint: "light"), "appearance=dark wins over the hint")
let followSystem = WindowSettings(appearance: "system")
check(DshTheme.resolveLight(followSystem, hint: "dark") == DshTheme.systemUsesLight, "appearance=system follows macOS")
print("dsh settings file: \(DshTheme.settingsFile()?.path ?? "none")")
print("dsh preference:    \(DshTheme.currentPreference() ?? "unknown")")
check(DshTheme.currentPreference() == DshTheme.currentPreference(), "theme preference lookup is stable (cached)")

// --- cache maintenance -----------------------------------------------------
let fileManager = FileManager.default
for root in Paths.cacheRoots {
    try? fileManager.createDirectory(at: root.appendingPathComponent("WebKit/NetworkCache/Records"), withIntermediateDirectories: true)
    try? Data(repeating: 7, count: 4096).write(to: root.appendingPathComponent("WebKit/NetworkCache/Records/blob.bin"))
}
let before = CacheMaintenance.cacheBytes()
check(before >= 4096, "cache bytes counted (\(before))")
let summary = CacheMaintenance.clean()
print("clean summary: \(summary.text)")
check(summary.freedBytes >= 4096, "clean freed the cache")
check(CacheMaintenance.cacheBytes() == 0, "cache empty after clean")
check(!fileManager.fileExists(atPath: Paths.pendingCleanMarker.path), "no pending marker when nothing was locked")

print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
