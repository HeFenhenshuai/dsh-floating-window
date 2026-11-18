// Entry point of the macOS floating window.
//
// Usage: dsh-floating-window --dsh-auth-url=<token url> --dsh-page-url=<page url>
//                            [--dsh-title=<text>]
//                            [--dsh-header-name=<header>] [--dsh-header-value=<value>]

import AppKit

let options = LaunchOptions.parse(CommandLine.arguments)
Log.rotateIfHuge()
Log.write("start args=\(CommandLine.arguments.dropFirst().joined(separator: " | "))")
// Before WebKit exists the cache files are not held open, so a clean left over
// from the last run can finish here.
CacheMaintenance.finishPendingClean()

let application = NSApplication.shared
let delegate = AppDelegate(options: options)
application.delegate = delegate
// A regular app: it gets a Dock icon and a ⌘-Tab entry, so a minimised float
// can always be found again.
application.setActivationPolicy(.regular)
application.run()
