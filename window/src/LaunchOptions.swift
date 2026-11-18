// Launch arguments, exactly the ones host.js spawns the window with:
//
//   dsh-floating-window --dsh-auth-url=<token url> --dsh-page-url=<page url>
//                       [--dsh-title=<text>]
//                       [--dsh-header-name=<header>] [--dsh-header-value=<value>]
//
// The auth URL is the Host's one-shot browser-trust URL: loading it mints the
// cookie every later request from this window carries. The page URL is the
// compact conversation page served by the plugin's host half.

import Foundation

struct LaunchOptions {
    var authURL: URL?
    var pageURL: URL?
    var title: String = "悬浮窗"
    var headerName: String?
    var headerValue: String?
    /// The DSH app bundle this window belongs to (`--dsh-parent-app`), so a
    /// "handle it in the main window" request can activate that app.
    var parentApp: String?
    /// First-paint appearance hint carried in the page URL (`?theme=light|dark`).
    var themeHint: String?

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        for argument in arguments {
            if argument.hasPrefix("--dsh-auth-url=") {
                options.authURL = URL(string: String(argument.dropFirst("--dsh-auth-url=".count)))
            } else if argument.hasPrefix("--dsh-page-url=") {
                let raw = String(argument.dropFirst("--dsh-page-url=".count))
                options.pageURL = URL(string: raw)
            } else if argument.hasPrefix("--dsh-title=") {
                let value = String(argument.dropFirst("--dsh-title=".count))
                if !value.isEmpty { options.title = value }
            } else if argument.hasPrefix("--dsh-header-name=") {
                options.headerName = String(argument.dropFirst("--dsh-header-name=".count))
            } else if argument.hasPrefix("--dsh-header-value=") {
                options.headerValue = String(argument.dropFirst("--dsh-header-value=".count))
            } else if argument.hasPrefix("--dsh-parent-app=") {
                let value = String(argument.dropFirst("--dsh-parent-app=".count))
                if !value.isEmpty { options.parentApp = value }
            }
        }
        // The DSH half already decides the first paint; a `theme=` in the page URL
        // is only the fallback for when the settings file cannot be read.
        if let page = options.pageURL,
           let components = URLComponents(url: page, resolvingAgainstBaseURL: false),
           let theme = components.queryItems?.first(where: { $0.name == "theme" })?.value,
           theme == "light" || theme == "dark" {
            options.themeHint = theme
        }
        if options.title.isEmpty { options.title = "悬浮窗" }
        return options
    }
}
