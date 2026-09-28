// uc-notify: shows a notification with the UC Watchdog icon.
// Usage: uc-notify <title> <message>. Built by install.sh into
// ~/.local/share/uc-watchdog/UC Watchdog.app (needs swiftc from the Command Line Tools).
import Cocoa

class Delegate: NSObject, NSUserNotificationCenterDelegate {
    func userNotificationCenter(_ c: NSUserNotificationCenter, shouldPresent n: NSUserNotification) -> Bool { true }
}

let args = CommandLine.arguments
let n = NSUserNotification()
n.title = args.count > 1 ? args[1] : "Universal Control"
n.informativeText = args.count > 2 ? args[2] : ""
let center = NSUserNotificationCenter.default
let delegate = Delegate()
center.delegate = delegate
center.deliver(n)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
