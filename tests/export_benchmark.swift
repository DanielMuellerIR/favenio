// Dieselbe Eingabe und derselbe Serializer für Vorher/Nachher. Nur der
// Aufrufort wechselt; die Baseline hat keinen ExportWriter.
import Foundation
import Darwin

@main struct ExportBenchmark {
    static func main() throws {
        let format = HitExportFormat(rawValue: CommandLine.arguments[1])!
        let hits = (0..<100000).map { index in
            Hit(path: "/fixture/folder/file-\(index).txt", kind: "file", line: nil,
                size: 1000, filesystemPath: "/fixture/folder/file-\(index).txt",
                archiveMembers: [], isDirectory: false,
                modified: 1725500000, created: 1725400000)
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let start = ProcessInfo.processInfo.systemUptime
        var last = start
        var maxDelay = 0.0
        var ticks = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            maxDelay = max(maxDelay, now - last - 0.005)
            last = now
            ticks += 1
        }
        var completed = false
        var elapsed = 0.0
        #if AFTER
        let writer = ExportWriter()
        writer.write(hits, format: format, to: output) { result in
            if case .failure(let error) = result { fatalError(error.localizedDescription) }
            elapsed = ProcessInfo.processInfo.systemUptime - start
            completed = true
        }
        #else
        try exportData(for: hits, format: format).write(to: output, options: .atomic)
        elapsed = ProcessInfo.processInfo.systemUptime - start
        completed = true
        #endif
        // Auch VORHER muss der verspätete Timer einmal feuern dürfen, sonst
        // ergäbe eine komplett blockierte Main-Queue fälschlich Verzögerung 0.
        while (!completed || ticks == 0) && ProcessInfo.processInfo.systemUptime - start < 120 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
        }
        timer.invalidate()
        precondition(completed && ticks > 0)
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        let report: [String: Any] = ["format": format.rawValue, "hits": hits.count,
            "seconds": elapsed, "rss": usage.ru_maxrss, "max_delay": maxDelay,
            "bytes": attributes[.size]!, "ticks": ticks]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
}
