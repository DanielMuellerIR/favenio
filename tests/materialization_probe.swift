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
    var issues: [String] = []
    override func presentActionIssue(summary: String, detail: String?) { issues.append(summary) }
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
        case "action-reset", "action-cancel", "action-cancel-then-reset":
            manager.cliPath = arguments[2]
            let target = hit(arguments[3], [arguments[4]])
            let controller = MaterializationControllerProbe()
            controller.hits = [target]
            controller.contextRow = 0
            var performed = false
            controller.withActionSelection { _ in performed = true }
            precondition(controller.isMaterializing)
            // Ein unabhängiger Anforderer hält den Auftrag offen. Seine
            // Completion belegt, dass auch die alten Callbacks abgearbeitet sind.
            manager.request(target) { received(); outcome = $0 }
            controller.cancelMaterializations(reportCancellation: mode != "action-reset")
            if mode == "action-cancel-then-reset" {
                controller.cancelMaterializations(reportCancellation: false)
            }
            try! Data().write(to: URL(fileURLWithPath: arguments[5]))
            precondition(spin(until: { outcome != nil }))
            report["issues"] = controller.issues
            report["performed"] = performed
            report["materializing"] = controller.isMaterializing
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
                if case .ready(let url)? = outcome {
                    report["content"] = try! String(contentsOf: url, encoding: .utf8)
                }
                // Zweite Anforderung: aus dem Cache, sofort und synchron.
                var second: MaterializationOutcome?
                let again = manager.request(target) {
                    received(); second = $0
                    // Eine synchrone Cache-Completion darf den Manager
                    // erneut fragen; sie darf seinen Lock nicht halten.
                    report["reentrant_known"] = manager.knownURL(for: target)?.path ?? ""
                }
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
            // Die Datei kann bereits existieren, bevor die PID geschrieben ist.
            // Erst mit gültiger PID abbrechen; kill(-1, 0) prüfte sonst fremde
            // Prozesse und meldete einen erfolgreichen Abbruch als Fehlschlag.
            var pid: Int32 = 0
            let started = spin(until: {
                guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
                      let candidate = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                      candidate > 0 else { return false }
                pid = candidate
                return true
            }, seconds: 5)
            let cancelStart = ProcessInfo.processInfo.systemUptime
            request?.cancel()
            _ = spin(until: { outcome != nil })
            report = describe(outcome)
            report["cancel_seconds"] = ProcessInfo.processInfo.systemUptime - cancelStart
            report["started"] = started
            // SIGTERM → normales Ende im Kern; spätestens nach 1 s SIGKILL.
            // Die Frist misst NICHT das Verhalten — der Manager schickt
            // SIGTERM sofort und SIGKILL nach 1 s —, sondern nur, wie schnell
            // die Maschine das zustellt. Mit 3 s fiel der Test am 2026-09-10
            // unter paralleler Baulast einmal durch, isoliert dagegen
            // dreimal hintereinander gruen. Grosszuegig warten und trotzdem
            // die Frage beantworten: Ist der Prozess weg?
            let gone = started && spin(until: { kill(pid, 0) != 0 && errno == ESRCH },
                            seconds: 20)
            report["process_gone"] = gone
        case "shared":
            manager.cliPath = arguments[2]
            let target = hit(arguments[3], [arguments[4]])
            var first: MaterializationOutcome?
            var second: MaterializationOutcome?
            manager.request(target) { received(); first = $0 }
            manager.request(target) { received(); second = $0 }
            // Beide Aufträge sind angemeldet, bevor der Kern fertig werden darf.
            try! Data().write(to: URL(fileURLWithPath: arguments[5]))
            _ = spin(until: { first != nil && second != nil })
            report["first"] = describe(first)
            report["second"] = describe(second)
        case "concurrency":
            // Viele Auftraege auf einmal, wie eine grosse Auswahl sie
            // ausloest. Jeder Kern-Aufruf schreibt sein Zeitfenster mit;
            // der Test rechnet daraus die groesste Ueberlappung aus und
            // haelt sie gegen den Deckel.
            manager.cliPath = arguments[2]
            let count = Int(arguments[4]) ?? 20
            var finished = 0
            var readyCount = 0
            for index in 0..<count {
                let target = hit(arguments[3], ["member-\(index).txt"])
                manager.request(target) { outcome in
                    received()
                    finished += 1
                    if case .ready = outcome { readyCount += 1 }
                }
            }
            _ = spin(until: { finished == count }, seconds: 90)
            report["done"] = finished
            report["ready"] = readyCount
            report["cap"] = MaterializationManager.maximumConcurrentExtractions
        case "shared-variants":
            // Dieselbe Datei in ZWEI Trefferfassungen: einmal wie aus einer
            // Namenssuche, einmal wie aus einer Inhaltssuche mit Zeilennummer
            // und Maßen. Die Identität ist dieselbe, also gehören dazu EIN
            // Unterprozess und EINE Datei. Bis 0.34.14 war der Cache auf den
            // ganzen Hit-Wert verschlüsselt und packte zweimal aus.
            manager.cliPath = arguments[2]
            let plain = hit(arguments[3], [arguments[4]])
            let withLine = Hit(path: plain.path, kind: "member", line: 12,
                               size: nil, filesystemPath: plain.filesystemPath,
                               archiveMembers: plain.archiveMembers,
                               isDirectory: false, width: 640, height: 480,
                               modified: 1_700_000_000)
            precondition(plain != withLine, "Die beiden Fassungen sind gleich")
            precondition(plain.identity == withLine.identity,
                         "Die beiden Fassungen haben verschiedene Identitäten")
            var firstVariant: MaterializationOutcome?
            var secondVariant: MaterializationOutcome?
            manager.request(plain) { received(); firstVariant = $0 }
            manager.request(withLine) { received(); secondVariant = $0 }
            // Beide Aufträge sind angemeldet, bevor der Kern fertig werden darf.
            try! Data().write(to: URL(fileURLWithPath: arguments[5]))
            _ = spin(until: { firstVariant != nil && secondVariant != nil })
            report["first"] = describe(firstVariant)
            report["second"] = describe(secondVariant)
            // Und danach kennt knownURL BEIDE Fassungen ohne neues Auspacken.
            report["known_plain"] = manager.knownURL(for: plain)?.path ?? ""
            report["known_with_line"] = manager.knownURL(for: withLine)?.path ?? ""
        case "cleanup":
            manager.cliPath = arguments[2]
            let before = favenioTempDirectories()
            manager.request(hit(arguments[3], [arguments[4]])) { received(); outcome = $0 }
            let pidFile = arguments[5]
            precondition(spin(until: {
                guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
                      let pid = Int32(text) else { return false }
                return pid > 0
            }, seconds: 5), "Kern hat keine PID veröffentlicht")
            let pid = Int32(try! String(contentsOfFile: pidFile, encoding: .utf8))!
            manager.cleanup()
            let afterCleanup = favenioTempDirectories()
            _ = spin(until: { outcome != nil })
            // Die Frist misst NICHT das Verhalten — der Manager schickt
            // SIGTERM sofort und SIGKILL nach 1 s —, sondern nur, wie schnell
            // die Maschine das zustellt. Mit 3 s fiel der Test am 2026-09-10
            // unter paralleler Baulast einmal durch, isoliert dagegen
            // dreimal hintereinander gruen. Grosszuegig warten und trotzdem
            // die Frage beantworten: Ist der Prozess weg?
            let gone = spin(until: { kill(pid, 0) != 0 && errno == ESRCH },
                            seconds: 20)
            report = describe(outcome)
            report["process_gone"] = gone
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
