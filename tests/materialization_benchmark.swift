// Headless-Messung des synchronen und asynchronen Materialisierungswegs.
// Ausgabedaten werden nach der Zeitmessung vollständig gehasht.
import Foundation
import Darwin
import CryptoKit

@main struct MaterializationBenchmark {
    static func main() throws {
        let arguments = CommandLine.arguments
        let hit = Hit(path: arguments[1] + "!/" + arguments[2...].joined(separator: "!/"),
                      kind: "member", line: nil, size: nil,
                      filesystemPath: arguments[1],
                      archiveMembers: Array(arguments[2...]), isDirectory: false)
        defer { cleanupMaterializedHits() }
        let start = ProcessInfo.processInfo.systemUptime
        var last = start
        var delay = 0.0
        // Ein 5-ms-Timer misst, wie lange Main während des Auspackens wartet.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            delay = max(delay, now - last - 0.005); last = now
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        let callStart = ProcessInfo.processInfo.systemUptime
        let url: URL?
        let mode: String
        let blocked: Double
        #if ASYNC
        mode = "async"
        var result: MaterializationOutcome?
        MaterializationManager.shared.request(hit) {
            precondition(Thread.isMainThread && result == nil)
            result = $0
        }
        blocked = ProcessInfo.processInfo.systemUptime - callStart
        while result == nil && ProcessInfo.processInfo.systemUptime - callStart < 110 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
        }
        if case .ready(let ready)? = result { url = ready } else { url = nil }
        #else
        mode = "sync"
        url = materializeHit(hit)
        blocked = ProcessInfo.processInfo.systemUptime - callStart
        #endif
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        timer.invalidate()
        let seconds = ProcessInfo.processInfo.systemUptime - start
        guard let url else {
            throw NSError(domain: "MaterializationBenchmark", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Materialisierung nicht erfolgreich abgeschlossen"])
        }
        let root = ProcessInfo.processInfo.environment["TMPDIR"]!
        precondition(url.path.hasPrefix(root), "Ausgabe liegt außerhalb der eigenen Temp-Wurzel")
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var size = 0
        while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
            digest.update(data: chunk)
            size += chunk.count
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let report: [String: Any] = ["mode": mode, "blocked_seconds": blocked,
            "seconds": seconds, "max_delay": delay, "ok": true, "bytes": size, "sha256": hash]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
}
