// Headless-Probe des asynchronen Materialisierungsmanagers. Keine App, kein
// Fenster: Alle Aufträge laufen über MaterializationManager.request() bzw.
// materializeHitSelection(_:rows:completion:), die Completion kommt auf der
// Main-RunLoop an. Gestartet von tests/test_materialization.py und
// tests/benchmark_materialization.py.
import Foundation
import Darwin

@main struct MaterializationProbe {
    static var report: [String: Any] = [:]

    static func hit(_ path: String, _ members: [String]) -> Hit {
        Hit(path: path + "!/" + members.joined(separator: "!/"), kind: "member",
            line: nil, size: nil, filesystemPath: path, archiveMembers: members,
            isDirectory: false)
    }

    /// Dreht die Main-RunLoop, bis `done` wahr ist oder die Frist verstreicht.
    static func spin(until done: () -> Bool, seconds: Double = 15) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !done() && ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
        }
        return done()
    }

    static func describe(_ outcome: MaterializationOutcome?) -> [String: Any] {
        switch outcome {
        case .ready(let url)?:
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
            return ["state": "ready", "path": url.path, "bytes": size]
        case .failed(let reason)?: return ["state": "failed", "reason": reason]
        case .cancelled?: return ["state": "cancelled"]
        case nil: return ["state": "pending"]
        }
    }

    static func favenioTempDirectories() -> Int {
        let temp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        return names.filter { $0.hasPrefix("Favenio-") }.count
    }

    static func main() {
        let arguments = CommandLine.arguments
        let mode = arguments[1]
        let manager = MaterializationManager.shared
        var outcome: MaterializationOutcome?
        var callbacksOnMain = true
        let start = ProcessInfo.processInfo.systemUptime
        switch mode {
        case "benchmark":
            // Wie der synchrone Benchmark: Ein 5-ms-Timer misst, wie lange
            // Main nicht drankommt, während der Kern auspackt.
            var last = start
            var delay = 0.0
            let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
                let now = ProcessInfo.processInfo.systemUptime
                delay = max(delay, now - last - 0.005); last = now
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            let callStart = ProcessInfo.processInfo.systemUptime
            manager.request(hit(arguments[2], Array(arguments[3...]))) { outcome = $0 }
            let blocked = ProcessInfo.processInfo.systemUptime - callStart
            let finished = spin(until: { outcome != nil }, seconds: 120)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            timer.invalidate()
            report = describe(outcome)
            report["mode"] = "async"
            report["blocked_seconds"] = blocked
            report["max_delay"] = delay
            report["seconds"] = ProcessInfo.processInfo.systemUptime - start
            report["ok"] = finished && report["state"] as? String == "ready"
            report["bytes"] = report["bytes"] ?? -1
        case "start-error":
            manager.interpreter = "/no-such-favenio-interpreter"
            manager.request(hit(arguments[2], [arguments[3]])) { outcome = $0 }
            _ = spin(until: { outcome != nil })
            report = describe(outcome)
        case "broken", "same-file", "budget":
            if mode == "budget" { manager.extraArguments = ["--max-archive-member-bytes", "10"] }
            let target = hit(arguments[2], [arguments[3]])
            let request = manager.request(target) { callbacksOnMain = callbacksOnMain && Thread.isMainThread; outcome = $0 }
            report["deferred"] = request != nil
            _ = spin(until: { outcome != nil })
            report.merge(describe(outcome)) { $1 }
            if mode == "same-file" {
                // Zweite Anforderung: aus dem Cache, sofort und synchron.
                var second: MaterializationOutcome?
                let again = manager.request(target) { second = $0 }
                report["second"] = describe(second)
                report["second_deferred"] = again != nil
                report["known"] = manager.knownURL(for: target)?.path ?? ""
            }
        case "rapid":
            // 20 schnelle Auswahlwechsel wie bei Quick Look: Jede neue
            // Anforderung bricht die vorige ab; nur die letzte darf ankommen.
            var selections: [MaterializedHitSelection?] = Array(repeating: nil, count: 20)
            var current: MaterializationSelectionRequest?
            let hits = (0..<20).map { hit(arguments[2], ["member-\($0).txt"]) }
            for index in 0..<20 {
                current?.cancel()
                current = materializeHitSelection(hits, rows: [index]) { selections[index] = $0 }
            }
            _ = spin(until: { selections.allSatisfy { $0 != nil } })
            report["completed"] = selections.filter { $0 != nil }.count
            report["cancelled"] = selections.filter { $0?.cancelled == true }.count
            report["last_urls"] = selections[19]?.urls.map { $0.path } ?? []
            report["last_cancelled"] = selections[19]?.cancelled ?? true
        case "stderr-flood":
            manager.cliPath = arguments[2]
            manager.request(hit(arguments[3], [arguments[4]])) { outcome = $0 }
            _ = spin(until: { outcome != nil })
            report = describe(outcome)
        case "cancel":
            manager.cliPath = arguments[2]
            let pidFile = arguments[5]
            let request = manager.request(hit(arguments[3], [arguments[4]])) { outcome = $0 }
            // Erst abbrechen, wenn der Kern wirklich läuft (er schreibt seine PID).
            _ = spin(until: { FileManager.default.fileExists(atPath: pidFile) }, seconds: 5)
            let cancelStart = ProcessInfo.processInfo.systemUptime
            request?.cancel()
            _ = spin(until: { outcome != nil })
            report = describe(outcome)
            report["cancel_seconds"] = ProcessInfo.processInfo.systemUptime - cancelStart
            let pid = Int32((try? String(contentsOfFile: pidFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
            // SIGTERM → normales Ende im Kern; spätestens nach 1 s SIGKILL.
            let gone = spin(until: { kill(pid, 0) != 0 && errno == ESRCH }, seconds: 3)
            report["process_gone"] = gone
        case "shared":
            manager.cliPath = arguments[2]
            let target = hit(arguments[3], [arguments[4]])
            var first: MaterializationOutcome?
            var second: MaterializationOutcome?
            manager.request(target) { first = $0 }
            manager.request(target) { second = $0 }
            _ = spin(until: { first != nil && second != nil })
            report["first"] = describe(first)
            report["second"] = describe(second)
        case "cleanup":
            manager.cliPath = arguments[2]
            let before = favenioTempDirectories()
            manager.request(hit(arguments[3], [arguments[4]])) { outcome = $0 }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            manager.cleanup()
            let afterCleanup = favenioTempDirectories()
            _ = spin(until: { outcome != nil })
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
            report = describe(outcome)
            report["dirs_before"] = before
            report["dirs_after_cleanup"] = afterCleanup
            report["dirs_end"] = favenioTempDirectories()
        default:
            report["error"] = "unbekannter Modus"
        }
        report["on_main"] = callbacksOnMain
        print(String(decoding: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        manager.cleanup()
    }
}
