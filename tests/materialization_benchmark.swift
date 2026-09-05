// Headless-Messung des SYNCHRONEN Materialisierungswegs (materializeHit),
// wie ihn die Apps bis 0.31.4 in Öffnen, Quick Look und Drag-and-drop auf dem
// Main-Thread riefen. Kompiliert gegen alten und neuen Kern.
// Aufruf: <binary> <filesystemPath> <member> [<member> …]
import Foundation
import Darwin

@main struct MaterializationBenchmark {
    static func main() {
        let arguments = CommandLine.arguments
        let hit = Hit(path: arguments[1] + "!/" + arguments[2...].joined(separator: "!/"),
                      kind: "member", line: nil, size: nil,
                      filesystemPath: arguments[1],
                      archiveMembers: Array(arguments[2...]), isDirectory: false)
        let start = ProcessInfo.processInfo.systemUptime
        var last = start
        var delay = 0.0
        // Ein 5-ms-Timer auf dem Main-RunLoop misst, wie lange Main nicht
        // drankommt — genau die Zeit, in der ein Fenster einfriert.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            delay = max(delay, now - last - 0.005); last = now
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        let callStart = ProcessInfo.processInfo.systemUptime
        let url = materializeHit(hit)
        let blocked = ProcessInfo.processInfo.systemUptime - callStart
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        timer.invalidate()
        let size = url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? -1
        let report: [String: Any] = ["mode": "sync", "blocked_seconds": blocked,
                                     "max_delay": delay, "ok": url != nil, "bytes": size]
        print(String(decoding: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        cleanupMaterializedHits()
        if url == nil { exit(1) }
    }
}
