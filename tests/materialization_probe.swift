// Headless-Probe des asynchronen Materialisierungsmanagers. Keine App, kein
// Fenster: Alle Aufträge laufen über MaterializationManager.request() bzw.
// materializeHitSelection(_:rows:completion:), die Completion kommt auf der
// Main-RunLoop an. Gestartet von tests/test_materialization.py und
// tests/benchmark_materialization.py.
import Foundation
import Darwin
import AppKit

/// Beobachtet den tatsächlichen Controllerzustand ohne Vorschaufenster.
final class MaterializationControllerProbe: HitListController {
    var states: [Bool] = []
    override func presentMaterializationState() { states.append(isMaterializing) }
}

#if !FAVENIO_TEST_SUITE
@main
#endif
struct MaterializationProbe {
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
        let temp = MaterializationManager.shared.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        return names.filter { $0.hasPrefix("Favenio-") }.count
    }

    /// Wartet ohne Main-RunLoop auf den Cache. Damit ist der Worker fertig,
    /// während seine Main-Completion noch garantiert nicht zugestellt wurde.
    static func publishedURL(_ target: Hit) -> URL {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let url = MaterializationManager.shared.knownURL(for: target) { return url }
            Thread.sleep(forTimeInterval: 0.001)
        }
        fatalError("Ausgepackte Datei wurde nicht im Cache veröffentlicht")
    }

    static func main() {
        run(CommandLine.arguments)
    }

    static func run(_ arguments: [String]) {
        let mode = arguments[1]
        let manager = MaterializationManager.shared
        if let temporary = ProcessInfo.processInfo.environment["TMPDIR"] {
            manager.temporaryDirectory = URL(fileURLWithPath: temporary, isDirectory: true)
        }
        var outcome: MaterializationOutcome?
        var callbackCount = 0
        func received() {
            precondition(Thread.isMainThread, "Materialisierungs-Callback läuft außerhalb von Main")
            callbackCount += 1
        }
        let start = ProcessInfo.processInfo.systemUptime
        switch mode {
        case "preview-sync":
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            let controller = MaterializationControllerProbe()
            controller.hits = [hit(arguments[2], [arguments[3]]),
                Hit(path: arguments[2], kind: "file", line: nil, size: nil,
                    filesystemPath: arguments[2], archiveMembers: [], isDirectory: false)]
            var stale = 0
            var latest: MaterializedHitSelection?
            controller.requestPreview(rows: [0]) { _ in stale += 1 }
            controller.requestPreview(rows: [1]) { received(); latest = $0 }
            var drained = false
            DispatchQueue.main.async { drained = true }
            _ = spin(until: { drained })
            report["states"] = controller.states
            report["materializing"] = controller.isMaterializing
            report["latest_urls"] = latest?.urls.map { $0.path } ?? []
            report["stale"] = stale
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
            manager.request(hit(arguments[2], Array(arguments[3...]))) { received(); outcome = $0 }
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
            manager.request(hit(arguments[2], [arguments[3]])) { received(); outcome = $0 }
            _ = spin(until: { outcome != nil })
            report = describe(outcome)
        case "broken", "same-file", "budget":
            if mode == "budget" { manager.extraArguments = ["--max-archive-member-bytes", "10"] }
            let target = hit(arguments[2], [arguments[3]])
            let request = manager.request(target) { received(); outcome = $0 }
            report["deferred"] = request != nil
            _ = spin(until: { outcome != nil })
            report.merge(describe(outcome)) { $1 }
            if mode == "same-file" {
                // Zweite Anforderung: aus dem Cache, sofort und synchron.
                var second: MaterializationOutcome?
                let again = manager.request(target) { received(); second = $0 }
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
                current = materializeHitSelection(hits, rows: [index]) { received(); selections[index] = $0 }
            }
            _ = spin(until: { selections.allSatisfy { $0 != nil } })
            report["completed"] = selections.filter { $0 != nil }.count
            report["cancelled"] = selections.filter { $0?.cancelled == true }.count
            report["last_urls"] = selections[19]?.urls.map { $0.path } ?? []
            report["last_cancelled"] = selections[19]?.cancelled ?? true
        case "stderr-flood":
            manager.cliPath = arguments[2]
            manager.request(hit(arguments[3], [arguments[4]])) { received(); outcome = $0 }
            _ = spin(until: { outcome != nil })
            report = describe(outcome)
        case "cancel":
            manager.cliPath = arguments[2]
            let pidFile = arguments[5]
            let request = manager.request(hit(arguments[3], [arguments[4]])) { received(); outcome = $0 }
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
            manager.request(target) { received(); first = $0 }
            manager.request(target) { received(); second = $0 }
            _ = spin(until: { first != nil && second != nil })
            report["first"] = describe(first)
            report["second"] = describe(second)
        case "cleanup":
            manager.cliPath = arguments[2]
            let before = favenioTempDirectories()
            manager.request(hit(arguments[3], [arguments[4]])) { received(); outcome = $0 }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            manager.cleanup()
            let afterCleanup = favenioTempDirectories()
            _ = spin(until: { outcome != nil })
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
            report = describe(outcome)
            report["dirs_before"] = before
            report["dirs_after_cleanup"] = afterCleanup
            report["dirs_end"] = favenioTempDirectories()
        case "late-selection", "late-cancel", "late-cleanup", "reentrant-cancel", "reentrant-cleanup":
            manager.cliPath = arguments[2]
            let target = hit(arguments[3], [arguments[4]])
            var selection: MaterializedHitSelection?
            var first: MaterializationOutcome?
            var second: MaterializationOutcome?
            var secondRequest: MaterializationRequest?
            var group: MaterializationSelectionRequest?
            var firstRequest: MaterializationRequest?
            if mode == "late-selection" {
                group = materializeHitSelection([target], rows: [0]) {
                    received(); selection = $0
                }
            } else {
                firstRequest = manager.request(target) { result in
                    received(); first = result
                    if mode == "reentrant-cancel" { secondRequest?.cancel() }
                    if mode == "reentrant-cleanup" { manager.cleanup() }
                }
                secondRequest = manager.request(target) { received(); second = $0 }
                precondition(firstRequest != nil && secondRequest != nil)
            }
            // Der Fake-Kern darf erst nach beiden Anforderungen fertig werden.
            try! Data().write(to: URL(fileURLWithPath: arguments[5]))
            let url = publishedURL(target)
            precondition(callbackCount == 0)
            if mode == "late-selection" { group?.cancel() }
            if mode == "late-cancel" { firstRequest?.cancel(); firstRequest?.cancel() }
            if mode == "late-cleanup" { manager.cleanup() }
            _ = spin(until: { mode == "late-selection" ? selection != nil : first != nil && second != nil })
            // Auch wiederholter Abbruch nach Zustellung darf nicht erneut melden.
            firstRequest?.cancel(); secondRequest?.cancel(); group?.cancel()
            var drained = false
            DispatchQueue.main.async { drained = true }
            _ = spin(until: { drained })
            report["first"] = describe(first)
            report["second"] = describe(second)
            report["selection_cancelled"] = selection?.cancelled ?? false
            report["file_exists"] = FileManager.default.fileExists(atPath: url.path)
            report["cached"] = manager.knownURL(for: target) != nil
            if mode == "late-cancel" {
                var cached: MaterializationOutcome?
                let request = manager.request(target) { received(); cached = $0 }
                report["cache_synchronous"] = request == nil && cached == .ready(url)
            }
        default:
            report["error"] = "unbekannter Modus"
        }
        report["callbacks"] = callbackCount
        report["on_main"] = callbackCount > 0
        report["temporary_root"] = manager.temporaryDirectory.path
        print(String(decoding: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        manager.cleanup()
    }
}
