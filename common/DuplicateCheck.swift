import AppKit
import Darwin

struct DuplicateProgress: Decodable {
    let type: String
    let schemaVersion: Int
    let phase: String
    let done: Int
    let total: Int
    let readBytes: Int64
    let currentID: String?
}

struct DuplicateResult: Decodable {
    struct Group: Decodable {
        let id: String
        let memberIDs: [String]
        let sha256: String
        let size: Int64
        let physicalFiles: Int
        let byteVerified: Bool
    }
    struct File: Decodable {
        let sourceGeneration: [String: String]
        let size: Int64
        let linkKind: String
        let linkCount: Int
        let guardGeneration: [String: String]?
    }
    struct Issue: Decodable { let id: String?; let reason: String; let message: String }
    let type: String
    let schemaVersion: Int
    let state: String
    let complete: Bool
    let checkedAt: String
    let scopeCount: Int
    let hashedFiles: Int
    let readBytes: Int64
    let groups: [Group]
    let files: [String: File]
    let issueCount: Int
    let issues: [Issue]

    func validate(ids: Set<String>, guarded: [String: ContentSourceGeneration] = [:]) -> Bool {
        guard type == "duplicateResult", [1, 2].contains(schemaVersion),
              ["completed", "partial", "limited", "cancelled"].contains(state),
              complete == (state == "completed"), scopeCount == ids.count,
              (0...scopeCount).contains(hashedFiles), (0...(64 * 1024 * 1024 * 1024 + 1)).contains(readBytes),
              (0...scopeCount + 1).contains(issueCount), issues.count == min(32, issueCount),
              (state != "completed" || issueCount == 0), (state != "partial" || issueCount > 0),
              (!["limited", "cancelled"].contains(state) || groups.isEmpty),
              ISO8601DateFormatter().date(from: checkedAt) != nil else { return false }
        var members = Set<String>(), groupIDs = Set<String>()
        for group in groups {
            guard groupIDs.insert(group.id).inserted, group.memberIDs.count >= 2,
                  group.byteVerified, group.size >= 0,
                  (1...group.memberIDs.count).contains(group.physicalFiles),
                  group.sha256.utf8.count == 64,
                  group.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
            var physical = Set<String>()
            for id in group.memberIDs {
                guard ids.contains(id), members.insert(id).inserted, let file = files[id],
                      file.size == group.size, file.linkCount > 0,
                      ["regular", "hardlink", "symbolic"].contains(file.linkKind),
                      let generation = ContentSourceGeneration.parse(file.sourceGeneration),
                      generation.size == String(file.size) else { return false }
                if let expected = guarded[id] {
                    guard ContentSourceGeneration.parse(file.guardGeneration) == expected else { return false }
                } else if file.guardGeneration != nil { return false }
                physical.insert(generation.device + ":" + generation.inode)
            }
            guard physical.count == group.physicalFiles else { return false }
        }
        return Set(files.keys) == members && issues.allSatisfy { ($0.id == nil || ids.contains($0.id!)) && !$0.message.isEmpty }
    }
}

private func duplicatePipeChunk(_ handle: FileHandle) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 65536)
    while true {
        // read(upToCount:) wartet bei Pipes mitunter auf die gesamte Länge oder EOF.
        let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
        if count >= 0 { return Data(bytes.prefix(count)) }
        if errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

// Prozess/Abbruchzustand ist gesperrt; die Vorbereitung besitzt eine eigene Queue.
final class DuplicateJob: @unchecked Sendable {
    enum Failure: Error { case invalid(String), cancelled }
    private let lock = NSLock()
    private var stopped = false
    private var process: Process?
    private var directory: URL?
    private var leases: [MaterializationRequest] = []
    private var finished = false
    private let began = ProcessInfo.processInfo.systemUptime
    private let materializer: MaterializationManager
    init(materializer: MaterializationManager = .shared) { self.materializer = materializer }

    private func releaseLeases() {
        lock.lock(); let held = leases; leases = []; lock.unlock()
        for request in held { request.cancel(); request.release() }
    }
    var activePID: Int32? { lock.lock(); defer { lock.unlock() }; return process?.isRunning == true ? process?.processIdentifier : nil }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    func cancel(force: Bool = false) {
        lock.lock(); stopped = true
        let child = process, root = directory
        lock.unlock()
        releaseLeases()
        if let child, child.isRunning {
            if force { kill(child.processIdentifier, SIGKILL) } else { child.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func run(hits: [Hit], localOnly: Bool, progress: @escaping (DuplicateProgress) -> Void,
             completion: @escaping (Result<DuplicateResult, Error>) -> Void) {
        guard hits.count <= 50000, hits.allSatisfy({ $0.filesystemPath.hasPrefix("/") && !$0.filesystemPath.utf8.contains(0) && $0.filesystemPath.utf8.count <= 16384 }) else {
            DispatchQueue.main.async { completion(.failure(Failure.invalid("Ungültige oder zu große Dublettenmenge."))) }
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let expired = !self.stopped && !self.finished; self.lock.unlock()
            if expired {
                self.cancel()
                DispatchQueue.main.async { completion(.failure(Failure.invalid("Zeitgrenze einschließlich Archivvorbereitung erreicht."))) }
            }
        }
        Preparation(job: self, hits: hits, localOnly: localOnly, progress: progress, completion: completion).start()
    }

    // Alle veränderlichen Vorbereitungsdaten gehören ausschließlich queue.
    private final class Preparation: @unchecked Sendable {
        let job: DuplicateJob
        let hits: [Hit]
        let localOnly: Bool
        let progress: (DuplicateProgress) -> Void
        let completion: (Result<DuplicateResult, Error>) -> Void
        private let queue = DispatchQueue(label: "favenio.duplicate-preparation", qos: .userInitiated)
        private var records: [[String: Any]]
        private var guards: [String: ContentSourceGeneration] = [:]
        private let members: [Int]
        private var position = 0
        private var usedBytes: Int64 = 0

        init(job: DuplicateJob, hits: [Hit], localOnly: Bool, progress: @escaping (DuplicateProgress) -> Void,
             completion: @escaping (Result<DuplicateResult, Error>) -> Void) {
            self.job = job; self.hits = hits; self.localOnly = localOnly
            self.progress = progress; self.completion = completion
            records = hits.enumerated().map { ["id": String($0.offset), "filesystemPath": $0.element.filesystemPath] }
            members = hits.indices.filter { hits[$0].isMember }
        }
        func start() { queue.async { self.advance() } }
        private func unavailable(_ index: Int, _ reason: String, _ message: String) {
            records[index] = ["id": String(index), "filesystemPath": hits[index].filesystemPath,
                              "unavailable": ["reason": reason, "message": String(String.UnicodeScalarView(message.unicodeScalars.suffix(1024)))]]
        }
        private func continuePreparation() {
            position += 1
            queue.async { self.advance() }
        }
        private func advance() {
            guard !job.isStopped else { return }
            guard position < members.count else {
                job.execute(hits: hits, records: records, guarded: guards, localOnly: localOnly, progress: progress, completion: completion)
                return
            }
            let index = members[position], hit = hits[index]
            let budget = hit.contentPreview?.archiveLimits
            let reserve = Int64(budget?.memberBytes ?? 256 * 1024 * 1024)
            guard reserve > 0, reserve <= 256 * 1024 * 1024,
                  (budget?.totalBytes ?? 1024 * 1024 * 1024) <= 1024 * 1024 * 1024,
                  (budget?.ratio ?? 1000) <= 1000 else {
                unavailable(index, "archiveLimit", "Gespeicherte Archivgrenzen überschreiten 256 MiB je Mitglied, 1 GiB je Auftrag oder Ratio 1000.")
                continuePreparation(); return
            }
            guard reserve <= 1024 * 1024 * 1024 - usedBytes else {
                unavailable(index, "archiveLimit", "Keine ausreichende Reserve für das nächste Archivmitglied (höchstens 1 GiB befristete Dateien).")
                continuePreparation(); return
            }
            let event = DuplicateProgress(type: "duplicateProgress", schemaVersion: 2, phase: "materialize", done: position, total: members.count, readBytes: usedBytes, currentID: String(index))
            DispatchQueue.main.async { if !self.job.isStopped { self.progress(event) } }
            if localOnly, let message = job.validateLocalArchiveRoot(hit) {
                guard !job.isStopped else { return }
                unavailable(index, "archiveError", message)
                continuePreparation(); return
            }
            let request = job.materializer.request(hit, localOnly: localOnly, ephemeral: true) { outcome in
                self.queue.async(execute: DispatchWorkItem { self.receive(outcome, index: index, reserve: reserve) })
            }
            if let request {
                job.lock.lock(); let cancelled = job.stopped
                if !cancelled { job.leases.append(request) }
                job.lock.unlock()
                if cancelled { request.cancel(); request.release() }
            }
        }
        private func receive(_ outcome: MaterializationOutcome, index: Int, reserve: Int64) {
            guard !job.isStopped else { return }
            let hit = hits[index]
            switch outcome {
            case .ready(let url):
                if let proof = job.materializer.generationSnapshot(for: hit, url: url),
                   let size = Int64(proof.leaf.size), size >= 0, size <= reserve {
                    usedBytes += size; guards[String(index)] = proof.source
                    records[index] = ["id": String(index), "filesystemPath": url.path, "expectedGeneration": proof.leaf.json,
                                      "sourceGuard": ["filesystemPath": hit.filesystemPath, "generation": proof.source.json]]
                } else { unavailable(index, "archiveError", "Materialisierung ohne passenden Generationsbeleg oder zu groß.") }
            case .failed(let message): unavailable(index, "archiveError", message)
            case .cancelled: unavailable(index, "archiveError", "Materialisierung abgebrochen.")
            }
            continuePreparation()
        }
    }

    private func validateLocalArchiveRoot(_ hit: Hit) -> String? {
        guard !isStopped, let cli = findCLI(),
              let data = try? JSONSerialization.data(withJSONObject: ["filesystemPath": hit.filesystemPath, "archiveMembers": [String]()]),
              let text = String(data: data, encoding: .utf8) else { return "Archivwurzel nicht prüfbar." }
        let child = Process(), output = Pipe(), errors = Pipe(), diagnostics = SearchDiagnostics()
        child.executableURL = URL(fileURLWithPath: pythonPath)
        child.arguments = [cli, "--local-only", "--extract-json", text]
        child.standardInput = FileHandle.nullDevice; child.standardOutput = output; child.standardError = errors
        diagnostics.collect(from: errors)
        lock.lock()
        if stopped { lock.unlock(); diagnostics.finish(errors); return "Abgebrochen." }
        do { try child.run(); process = child; lock.unlock() }
        catch { lock.unlock(); diagnostics.finish(errors); return error.localizedDescription }
        let until = ProcessInfo.processInfo.systemUptime + 2
        while child.isRunning && !isStopped && ProcessInfo.processInfo.systemUptime < until { Thread.sleep(forTimeInterval: 0.01) }
        if child.isRunning {
            child.terminate(); Thread.sleep(forTimeInterval: 0.05)
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        child.waitUntilExit()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        diagnostics.finish(errors)
        lock.lock(); if process === child { process = nil }; lock.unlock()
        guard !isStopped, child.terminationStatus == 0, result.count > 1, result.count <= 16385 else {
            return diagnostics.errorMessage ?? "Archivwurzel nicht sicher lokal verfügbar oder Vortest abgebrochen."
        }
        return nil
    }

    private func execute(hits: [Hit], records: [[String: Any]], guarded: [String: ContentSourceGeneration], localOnly: Bool,
                         progress: @escaping (DuplicateProgress) -> Void,
                         completion: @escaping (Result<DuplicateResult, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { releaseLeases(); lock.lock(); finished = true; lock.unlock() }
            do {
                guard let cli = findCLI(), hits.count <= 50000 else { throw Failure.invalid("Kern fehlt oder mehr als 50000 Dateien.") }
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("favenio-duplicates-" + UUID().uuidString)
                lock.lock()
                if stopped { lock.unlock(); throw Failure.cancelled }
                do {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    directory = root
                    lock.unlock()
                } catch { lock.unlock(); throw error }
                defer { try? FileManager.default.removeItem(at: root) }
                let request = root.appendingPathComponent("request.json")
                guard FileManager.default.createFile(atPath: request.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw Failure.cancelled }
                let writer = try FileHandle(forWritingTo: request)
                defer { try? writer.close() }
                var bytes = 0
                func write(_ data: Data) throws {
                    if isStopped { throw Failure.cancelled }
                    bytes += data.count
                    guard bytes <= 32 * 1024 * 1024 else { throw Failure.invalid("Auftrag überschreitet 32 MiB.") }
                    try writer.write(contentsOf: data)
                }
                let remaining = 300 - (ProcessInfo.processInfo.systemUptime - began)
                guard remaining > 0 else { throw Failure.invalid("Zeitgrenze erreicht.") }
                try write(Data(("{\"schemaVersion\":2,\"limits\":{\"maxSeconds\":" + String(remaining) + "},\"items\":[").utf8))
                for (index, record) in records.enumerated() {
                    if index > 0 { try write(Data(",".utf8)) }
                    try write(JSONSerialization.data(withJSONObject: record))
                }
                try write(Data("]}".utf8)); try writer.close()
                let child = Process(), output = Pipe(), errors = Pipe()
                child.executableURL = URL(fileURLWithPath: pythonPath)
                child.arguments = [cli, "--duplicates-file", request.path] + (localOnly ? ["--local-only"] : [])
                child.standardInput = FileHandle.nullDevice
                child.standardOutput = output; child.standardError = errors
                lock.lock()
                if stopped { lock.unlock(); throw Failure.cancelled }
                do { try child.run(); process = child; lock.unlock() }
                catch { lock.unlock(); throw error }
                defer {
                    if child.isRunning { child.terminate(); if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
                    child.waitUntilExit()
                    try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
                }
                let errorGroup = DispatchGroup(), diagnostic = DuplicateDiagnostic()
                errorGroup.enter()
                DispatchQueue.global().async {
                    defer { errorGroup.leave() }
                    while let data = try? duplicatePipeChunk(errors.fileHandleForReading), !data.isEmpty { diagnostic.append(data) }
                }
                var buffer = Data(), result: DuplicateResult?
                let ids = Set(hits.indices.map(String.init))
                func line(_ data: Data) throws {
                    guard !data.isEmpty, result == nil else { throw Failure.invalid("Ungültiger Antwortstrom.") }
                    if let value = try? JSONDecoder().decode(DuplicateProgress.self, from: data) {
                        guard value.type == "duplicateProgress", [1, 2].contains(value.schemaVersion),
                              ["facts", "hash", "confirm", "validate"].contains(value.phase),
                              (0...hits.count).contains(value.total), (0...value.total).contains(value.done),
                              value.readBytes >= 0, value.currentID == nil || ids.contains(value.currentID!) else { throw Failure.invalid("Ungültiger Fortschritt.") }
                        DispatchQueue.main.async { if !self.isStopped { progress(value) } }
                    } else {
                        let value = try JSONDecoder().decode(DuplicateResult.self, from: data)
                        guard value.validate(ids: ids, guarded: guarded) else { throw Failure.invalid("Ungültiger Dublettenbeleg.") }
                        result = value
                    }
                }
                while true {
                    let data = try duplicatePipeChunk(output.fileHandleForReading)
                    if data.isEmpty { break }
                    if isStopped { throw Failure.cancelled }
                    buffer.append(data)
                    while let newline = buffer.firstIndex(of: 10) {
                        let frame = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                        guard frame.count <= 32 * 1024 * 1024 else { throw Failure.invalid("Antwort überschreitet 32 MiB.") }
                        try line(frame)
                    }
                    guard buffer.count <= 32 * 1024 * 1024 else { throw Failure.invalid("Antwort überschreitet 32 MiB.") }
                }
                if !buffer.isEmpty { try line(buffer) }
                child.waitUntilExit(); errorGroup.wait()
                guard !isStopped else { throw Failure.cancelled }
                guard child.terminationReason == .exit, let result,
                      child.terminationStatus == (result.complete ? (result.groups.isEmpty ? 1 : 0) : 2) else {
                    throw Failure.invalid(diagnostic.text.isEmpty ? "Kern ohne vollständigen Dublettenbeleg beendet." : diagnostic.text)
                }
                DispatchQueue.main.async { if !self.isStopped { completion(.success(result)) } }
            } catch {
                DispatchQueue.main.async { if !self.isStopped { completion(.failure(error)) } }
            }
        }
    }
}

private final class DuplicateDiagnostic {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); defer { lock.unlock() }; data.append(chunk.prefix(max(0, 65536 - data.count))) }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

final class DuplicateCheckController: NSObject, NSWindowDelegate {
    weak var owner: HitListController?
    let button = NSButton(title: "Dubletten prüfen…", target: nil, action: nil)
    let scope = NSPopUpButton()
    let local = NSButton(checkboxWithTitle: "Nur lokal vorhandene Inhalte lesen", target: nil, action: nil)
    let start = NSButton(title: "Prüfen", target: nil, action: nil)
    let stop = NSButton(title: "Abbrechen", target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "")
    let scopeNote = NSTextField(wrappingLabelWithString: "")
    let issueNote = NSTextField(wrappingLabelWithString: "")
    let progress = NSProgressIndicator()
    private(set) var results = DuplicateResultsController()
    private(set) var job: DuplicateJob?
    private var snapshot: [[Hit]] = []
    private var selected: [Hit] { snapshot.indices.contains(scope.indexOfSelectedItem) ? snapshot[scope.indexOfSelectedItem] : [] }

    init(owner: HitListController) {
        self.owner = owner; super.init()
        button.target = self; button.action = #selector(show)
        button.bezelStyle = .rounded; button.controlSize = .small; button.font = .systemFont(ofSize: 11)
        button.setAccessibilityIdentifier("duplicateCheckButton")
    }
    @objc func show() {
        guard let owner else { return }
        if results.window == nil { buildWindow(owner: owner) }
        if job == nil {
            prepareSnapshot()
        }
        results.window.makeKeyAndOrderFront(nil)
    }
    func prepareSnapshot() {
        guard let owner, job == nil else { return }
        owner.flushResultFilterPending()
        snapshot = [owner.selectedHitIndices.map { owner.hits[$0] }, owner.hits]
        scope.selectItem(at: fileObjects(snapshot[0]).count >= 2 ? 0 : 1)
        local.state = owner.localOnlyContent ? .on : .off
        changedScope()
    }
    private func fileObjects(_ hits: [Hit]) -> [Hit] {
        var seen = Set<HitIdentity>()
        return hits.filter { !$0.isDirectory && seen.insert($0.identity).inserted }
    }
    func buildWindow(owner: HitListController) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 840, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Dublettenprüfung – Favenio"; panel.minSize = NSSize(width: 720, height: 650)
        panel.isReleasedWhenClosed = false; panel.level = owner.window?.level ?? .normal; panel.appearance = owner.window?.appearance
        panel.delegate = self; results.window = panel
        scope.addItems(withTitles: ["Ausgewählte Treffer", "Alle gefilterten Treffer"])
        scope.target = self; scope.action = #selector(changedScope)
        scope.setAccessibilityIdentifier("duplicateScope")
        start.target = self; start.action = #selector(begin); start.keyEquivalent = "\r"
        start.setAccessibilityIdentifier("duplicateStart")
        stop.target = self; stop.action = #selector(cancel); stop.isEnabled = false
        stop.setAccessibilityIdentifier("duplicateCancel")
        status.font = .systemFont(ofSize: 13, weight: .semibold); status.setAccessibilityIdentifier("duplicateStatus")
        scopeNote.font = .systemFont(ofSize: 11); scopeNote.textColor = .secondaryLabelColor
        scopeNote.setAccessibilityIdentifier("duplicateScopeNote")
        issueNote.font = .systemFont(ofSize: 11); issueNote.textColor = .secondaryLabelColor
        issueNote.maximumNumberOfLines = 3; issueNote.setAccessibilityIdentifier("duplicateIssues")
        progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        let title = NSTextField(labelWithString: "Bytegleiche Dateien prüfen")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [scope, spacer, stop, start]); controls.spacing = 12
        let note = NSTextField(wrappingLabelWithString: "Größe → vollständiger SHA-256 → Bytevergleich. Ergebnis gilt für den Prüfzeitpunkt. Hardlinks können dasselbe Dateisystemobjekt benennen. Quelldateien und Archive bleiben unverändert; keine Speicherersparnis wird berechnet.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        let scroll = results.makeTable()
        let stack = NSStackView(views: [title, controls, scopeNote, local, progress, status, issueNote, scroll, note])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        let content = NSView(); panel.contentView = content
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)])
        for view in [controls, scopeNote, progress, status, issueNote, scroll, note] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        issueNote.isHidden = true
        panel.center()
    }
    @objc func changedScope() {
        guard job == nil else { return }
        let files = fileObjects(selected)
        scopeNote.stringValue = "Festgehaltene Menge: \(files.count) Objekte, davon \(files.filter { $0.isMember }.count) Archivmitglieder; \(selected.count - files.count) Ordner/doppelte Treffer ausgenommen. Containerdateien bleiben eigene Objekte."
        start.isEnabled = files.count >= 2 && files.count <= 50000
        issueNote.stringValue = ""; issueNote.isHidden = true; status.toolTip = nil
        results.clear(); status.stringValue = files.count > 50000 ? "Höchstens 50000 Dateien je Prüfung." : "Bereit. Höchstens 64 GiB Vergleichsbytes, 1 GiB befristete Archivdateien und 5 Minuten einschließlich Vorbereitung."
    }
    @objc func begin() {
        guard job == nil, start.isEnabled else { return }
        let files = fileObjects(selected), operation = DuplicateJob()
        issueNote.stringValue = ""; issueNote.isHidden = true; status.toolTip = nil
        results.clear(); job = operation; running(true); progress.doubleValue = 0
        status.stringValue = "Bereite \(files.count) Dateien vor…"
        operation.run(hits: files, localOnly: local.state == .on, progress: { [weak self, weak operation] value in
            guard let self, let operation, self.job === operation else { return }
            let phase = ["facts": "Dateifakten", "hash": "Vollständig lesen", "confirm": "Bytevergleich", "validate": "Quellen prüfen", "materialize": "Archive vorbereiten"][value.phase] ?? value.phase
            self.progress.doubleValue = value.total > 0 ? Double(value.done) / Double(value.total) : 0
            let name = value.currentID.flatMap(Int.init).flatMap { files.indices.contains($0) ? files[$0].displayName : nil } ?? ""
            let measure = value.phase == "materialize" ? "befristet" : "gelesen"
            self.status.stringValue = "\(phase): \(value.done)/\(value.total) · \(ByteCountFormatter.string(fromByteCount: value.readBytes, countStyle: .binary)) \(measure) · \(name)"
        }, completion: { [weak self, weak operation] outcome in
            guard let self, let operation, self.job === operation else { return }
            self.job = nil; self.running(false); self.progress.doubleValue = 1
            switch outcome {
            case .success(let result):
                self.results.accept(result, originals: files)
                let prefix = result.complete ? "Abgeschlossen" : result.state == "partial" ? "Teilprüfung – \(result.issueCount) unbekannte/ausgelassene Dateien" : "Unvollständig – Grenze oder Abbruch"
                self.status.stringValue = "\(prefix): \(result.groups.count) bytegeprüfte Gruppen · \(result.checkedAt)"
                self.issueNote.stringValue = result.issues.prefix(3).map { issue in
                    let name = issue.id.flatMap(Int.init).flatMap { files.indices.contains($0) ? files[$0].displayName : nil } ?? "Prüfung"
                    return name + ": " + issue.message
                }.joined(separator: "\n")
                self.issueNote.isHidden = result.issues.isEmpty
                self.status.toolTip = result.issues.map { "\($0.id.flatMap(Int.init).flatMap { files.indices.contains($0) ? files[$0].path : nil } ?? "Prüfung"): \($0.message)" }.joined(separator: "\n")
            case .failure(let error):
                self.results.clear(); self.status.stringValue = "Prüfung fehlgeschlagen; kein bestätigtes Ergebnis."
                self.status.toolTip = String(describing: error)
                self.issueNote.stringValue = String(describing: error); self.issueNote.isHidden = false
            }
        })
    }
    private func running(_ value: Bool) { scope.isEnabled = !value; local.isEnabled = !value; start.isEnabled = !value; stop.isEnabled = value }
    @objc func cancel() {
        job?.cancel(); job = nil
        guard results.window != nil else { return }
        running(false); results.clear(); progress.doubleValue = 0
        issueNote.stringValue = ""; issueNote.isHidden = true; status.toolTip = nil
        status.stringValue = "Abgebrochen. Kein bestätigtes Ergebnis."
    }
    func stopForTermination() { job?.cancel(force: true); job = nil }
    func windowWillClose(_ notification: Notification) { cancel() }
}

final class DuplicateResultsController: HitListController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private var rows: [Int?] = []
    private var headers: [Int: String] = [:]
    private var relations: [Int: String] = [:]
    override var resultTableRowCount: Int { rows.count }
    override func hitIndex(forTableRow row: Int) -> Int? { rows.indices.contains(row) ? rows[row] : nil }
    override func tableRow(forHitIndex index: Int) -> Int? { rows.firstIndex { $0 == index } }
    func makeTable() -> NSScrollView {
        let names = NSTableColumn(identifier: .init("file")); names.title = "Datei und vollständiger Pfad"; names.width = 570; names.minWidth = 300
        let relation = NSTableColumn(identifier: .init("relation")); relation.title = "Dateisystembezug"; relation.width = 190; relation.minWidth = 150
        tableView.addTableColumn(names); tableView.addTableColumn(relation)
        tableView.dataSource = self; tableView.delegate = self; tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.setAccessibilityIdentifier("duplicateGroups")
        let menu = NSMenu(); menu.delegate = self; tableView.menu = menu
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = tableView
        return scroll
    }
    func clear() { hits = []; rows = []; headers = [:]; relations = [:]; tableView.reloadData() }
    func accept(_ result: DuplicateResult, originals: [Hit]) {
        clear()
        for group in result.groups {
            headers[rows.count] = "Gruppe \(group.id) · \(ByteCountFormatter.string(fromByteCount: group.size, countStyle: .binary)) je Datei · \(group.memberIDs.count) Pfade · \(group.physicalFiles) Dateisystemobjekte"
            let archiveCount = group.memberIDs.compactMap(Int.init).filter { originals.indices.contains($0) && originals[$0].isMember }.count
            if archiveCount > 0 { headers[rows.count] = "Gruppe \(group.id) · \(ByteCountFormatter.string(fromByteCount: group.size, countStyle: .binary)) je Objekt · \(group.memberIDs.count) Objekte · \(archiveCount) Archivmitglieder" }
            rows.append(nil)
            for id in group.memberIDs {
                guard let index = Int(id), originals.indices.contains(index), let file = result.files[id] else { continue }
                let original = originals[index]
                var hit = Hit(path: original.path, kind: original.kind, line: nil, size: Int(file.size), filesystemPath: original.filesystemPath, archiveMembers: original.archiveMembers, isDirectory: false)
                hit.archiveMemberBytes = original.archiveMemberBytes; hit.searchRootBytes = original.searchRootBytes
                if original.isMember { hit.contentPreview = original.contentPreview; hit.contentEncoding = original.contentEncoding; hit.terms = original.terms }
                relations[hits.count] = original.isMember ? "Archivmitglied" : file.linkKind == "symbolic" ? "Symbolische Verknüpfung" : file.linkKind == "hardlink" ? "Hardlink · \(file.linkCount) Namen" : "Eigene Datei"
                rows.append(hits.count); hits.append(hit)
            }
        }
        tableView.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { hitIndex(forTableRow: row) != nil }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { headers[row] != nil }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { headers[row] == nil ? 44 : 30 }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let container = NSTableCellView(), label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false; label.lineBreakMode = .byTruncatingMiddle
        container.addSubview(label); container.textField = label
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: container.centerYAnchor)])
        if let header = headers[row] {
            // AppKit fordert die gesamte Gruppenzeile ohne Spaltenobjekt an.
            label.stringValue = column == nil || column?.identifier.rawValue == "file" ? header : ""
            label.font = .systemFont(ofSize: 12, weight: .semibold); label.toolTip = header
        } else if let index = hitIndex(forTableRow: row) {
            if column?.identifier.rawValue == "relation" { label.stringValue = relations[index] ?? ""; label.font = .systemFont(ofSize: 11) }
            else {
                let hit = hits[index]
                let text = NSMutableAttributedString(string: hit.displayName + "\n", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
                text.append(NSAttributedString(string: hit.path, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
                label.maximumNumberOfLines = 2; label.attributedStringValue = text; label.toolTip = hit.path
            }
        }
        return container
    }
    func menuWillOpen(_ menu: NSMenu) { _ = populateHitMenu(menu) }
}
