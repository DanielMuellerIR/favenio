import AppKit
import CoreGraphics

if CommandLine.arguments[1] == "--terminate" {
    let pid = Int32(CommandLine.arguments[2])!
    guard let app = NSRunningApplication(processIdentifier: pid) else { exit(1) }
    exit(app.terminate() ? 0 : 1)
}

let pid = Int32(CommandLine.arguments[1])!
let title = CommandLine.arguments[2]
guard let app = NSRunningApplication(processIdentifier: pid) else { exit(1) }
let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
guard let window = windows.first(where: {
    ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        && (title.isEmpty || ($0[kCGWindowName as String] as? String)?.contains(title) == true)
}), let number = window[kCGWindowNumber as String] as? Int else { exit(2) }
app.activate(options: [.activateIgnoringOtherApps])
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
process.arguments = ["-l", String(number), "-o", "-x", CommandLine.arguments[3]]
try process.run(); process.waitUntilExit()
app.hide()
let until = Date(timeIntervalSinceNow: 1)
while !app.isHidden && Date() < until { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }
exit(process.terminationStatus == 0 && app.isHidden ? 0 : 3)
